#!/usr/bin/env python3
"""Fake authenticated handoffkeep API server for wrk telemetry tests.

Serves the exact surface wrk's telemetry path is allowed to touch:
  GET  /v1/tasks/{id}            task validation (telemetry_bind)
  POST /v1/tasks/{id}/transition typed refs.job_id link (telemetry_task_link)
  PUT  /v1/bench/reps            terminal segment export (telemetry_drain)
  GET  /v1/bench/reps            non-empty readback for the integration test

bench_scores and bench_grades exist only so a test can assert wrk never
calls them: every request is logged as "METHOD path" (never headers or
bodies, so no bearer token or payload can leak into the log) and the
fixture answers 405.

Environment:
  HK_FIXTURE_TASKS     JSON file: {"445": {task}, ...} served by GET
  HK_FIXTURE_LOG       request log, appended one "METHOD path" per line
  HK_FIXTURE_STATE     durable JSON {"reps": [...], "transitions": [...]}
  HK_FIXTURE_PORT_FILE the bound port is written here once listening
  HK_FIXTURE_TOKEN     required bearer token (default "fixture-token")
"""

import json
import os
import sys
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlsplit

TASKS_FILE = os.environ.get("HK_FIXTURE_TASKS", "")
LOG_FILE = os.environ.get("HK_FIXTURE_LOG", "")
STATE_FILE = os.environ.get("HK_FIXTURE_STATE", "")
PORT_FILE = os.environ.get("HK_FIXTURE_PORT_FILE", "")
TOKEN = os.environ.get("HK_FIXTURE_TOKEN", "fixture-token")
CLIENT = "fixture-client"
LOCK = threading.Lock()


def load_redirect_map():
    # {"GET /v1/tasks/446": "http://localhost:P2/v1/tasks/446"} — the key is
    # matched on the exact "METHOD path" pair after auth, and the request is
    # answered 302 with the given Location. Used to prove wrk refuses to
    # follow redirects instead of forwarding the bearer to a second hop.
    try:
        with open(os.environ.get("HK_FIXTURE_REDIRECT_MAP", ""),
                  encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


REDIRECT_MAP = load_redirect_map()


def load_tasks():
    try:
        with open(TASKS_FILE, encoding="utf-8") as handle:
            return {int(k): v for k, v in json.load(handle).items()}
    except (OSError, ValueError):
        return {}


def load_state():
    try:
        with open(STATE_FILE, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {"reps": [], "transitions": []}


def save_state(state):
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(state, handle, sort_keys=True)
    os.replace(tmp, STATE_FILE)


def log_request(method, path, authorized):
    if not LOG_FILE:
        return
    # auth=present/absent records header presence only — the token value is
    # never logged, so a credential cannot leak through the fixture log.
    with open(LOG_FILE, "a", encoding="utf-8") as handle:
        handle.write("%s %s auth=%s\n"
                     % (method, path, "present" if authorized else "absent"))


TASKS = load_tasks()
STATE = load_state()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        return

    def _send(self, status, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        return self.headers.get("Authorization") == "Bearer " + TOKEN

    def _task_id(self):
        parts = urlsplit(self.path).path.strip("/").split("/")
        if len(parts) >= 3 and parts[0] == "v1" and parts[1] == "tasks":
            try:
                return int(parts[2])
            except ValueError:
                return None
        return None

    def _reps_put(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            self._send(400, {"error": "bad_json"})
            return
        reps = body.get("reps")
        if not isinstance(reps, list) or not reps:
            self._send(400, {"error": "invalid bench reps"})
            return
        with LOCK:
            by_origin = {r["origin_id"]: r for r in STATE["reps"]}
            for rep in reps:
                rep = dict(rep)
                rep["created_by"] = CLIENT
                by_origin[rep["origin_id"]] = rep
            STATE["reps"] = [by_origin[k] for k in sorted(by_origin)]
            save_state(STATE)
        self._send(200, {"upserted": len(reps)})

    def _transition(self, task_id):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            self._send(400, {"error": "bad_json"})
            return
        task = TASKS.get(task_id)
        if task is None:
            self._send(404, {"error": "task_not_found"})
            return
        to = body.get("to") or ""
        allowed = {"in_progress": {"join", "verifying", "blocked", "claimed"},
                   "verifying": {"join", "in_progress", "blocked"},
                   "claimed": {"in_progress", "blocked", "backlog"},
                   "blocked": {"in_progress", "claimed"},
                   "join": set()}
        if to not in allowed.get(task.get("state"), set()):
            self._send(409, {"error": "task_conflict"})
            return
        refs = body.get("refs") or {}
        with LOCK:
            event = {"from": task.get("state"), "to": to,
                     "by": CLIENT, "note": body.get("note") or "",
                     "at": datetime.now(timezone.utc).isoformat()}
            task.setdefault("events", []).append(event)
            task["state"] = to
            for key in ("job_id", "pr", "head_sha", "report_path"):
                if refs.get(key):
                    task.setdefault("refs", {})[key] = refs[key]
            STATE["transitions"].append(
                {"task_id": task_id, "to": to, "refs": refs})
            save_state(STATE)
        self._send(200, task)

    def _dispatch(self, method):
        path = urlsplit(self.path).path
        authorized = self._authorized()
        log_request(method, path, authorized)
        if not authorized:
            self._send(401, {"error": "unauthorized"})
            return
        redirect = REDIRECT_MAP.get("%s %s" % (method, path))
        if redirect:
            self.send_response(302)
            self.send_header("Location", redirect)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path in ("/v1/bench/scores", "/v1/bench/grades"):
            self._send(405, {"error": "method_not_allowed"})
            return
        if path == "/v1/bench/reps":
            if method == "PUT":
                self._reps_put()
            elif method == "GET":
                self._send(200, {"reps": STATE["reps"]})
            else:
                self._send(405, {"error": "method_not_allowed"})
            return
        task_id = self._task_id()
        if task_id is not None and path == "/v1/tasks/%d" % task_id \
                and method == "GET":
            task = TASKS.get(task_id)
            if task is None:
                self._send(404, {"error": "task_not_found"})
            else:
                self._send(200, task)
            return
        if task_id is not None \
                and path == "/v1/tasks/%d/transition" % task_id \
                and method == "POST":
            self._transition(task_id)
            return
        self._send(404, {"error": "not_found"})

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    def do_PUT(self):
        self._dispatch("PUT")


def main():
    server = HTTPServer(("127.0.0.1", 0), Handler)
    if PORT_FILE:
        with open(PORT_FILE, "w", encoding="utf-8") as handle:
            handle.write(str(server.server_address[1]))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
