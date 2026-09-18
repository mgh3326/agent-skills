#!/usr/bin/env python3
"""oc-union: localhost auth-injecting proxy for OpenRouter.

Why this exists: OpenCode tool children run as the same uid with the pane's
env and file reachability — any key material placed in a file (or env var)
visible to the agent is one `cat`/`env` away from the transcript, and the
provider may retain prompts/completions. So the key lives only in this
process's memory: it reads the key file itself at startup (it runs outside
the lane's sandbox), and OpenCode is configured with a localhost baseURL
plus a placeholder apiKey.

Lane isolation: localhost is not a trust boundary — other agent sessions on
this host could otherwise spend the operator's key through this port. Every
request except /healthz must present the per-lane bearer token that `wrk
spawn` generated for this lane: the lane's opencode sends it as
`Authorization: Bearer <token>` (its config apiKey is `{env:OC_UNION_PROXY_
TOKEN}`, substituted from the pane env — never written to disk), and this
process received the same value via the same env var at startup. The token
grants proxy use only — it is not the key — and dies with this process.
Requests without it get 401.

Serves on 127.0.0.1 only. Never logs or prints the key or the token: every
log line, error payload and relayed upstream body passes through a scrubber,
including error paths (the original incident was a tool printing the key
inside an error).
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import http.client
import json
import os
import re
import socketserver
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOP_BY_HOP = {"connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade"}
SECRETS = []  # values that must never reach logs, stderr or response bodies


def scrub_bytes(data: bytes) -> bytes:
    for secret in SECRETS:
        if secret:
            data = data.replace(secret.encode(), b"<redacted>")
    return data


def scrub(text: str) -> str:
    for secret in SECRETS:
        if secret:
            text = text.replace(secret, "<redacted>")
    return text


def extract_key(key_file: str) -> str:
    """Text-parse the OPENROUTER_API_KEY assignment — never source the file.

    Tolerates leading whitespace, an `export ` prefix, surrounding quotes,
    and inline `#` comments; takes the first token after `=`. Mirrors the
    extraction rule the fleet adopted after the 2026-09-07 incident.
    """

    pat = re.compile(r"^\s*(?:export\s+)?OPENROUTER_API_KEY\s*=")
    with open(key_file) as fh:
        for line in fh:
            if not pat.match(line):
                continue
            value = line.split("=", 1)[1].strip().split("#", 1)[0].strip().split()
            if not value:
                break
            token = value[0].strip("\"'")
            if token:
                return token
    raise SystemExit(f"OPENROUTER_API_KEY not found in {key_file}")


class _Server(ThreadingHTTPServer):
    """HTTPServer.server_bind does a reverse-DNS getfqdn on the bind address —
    that can stall for many seconds on hosts with no PTR answer (seen on CI
    runners, where the proxy looked alive but never published its port file).
    Loopback needs no name resolution."""

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = "localhost"
        self.server_port = port


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    key = ""  # set on the class before serve
    token = ""  # per-lane bearer required from clients
    upstream_host = "openrouter.ai"
    upstream_port = 443
    upstream_tls = True
    allowed_models = frozenset({"stealth/union-alpha"})
    last_activity = time.time()

    def log_message(self, fmt, *args):  # noqa: A003 - stdlib signature
        try:
            msg = fmt % args
        except Exception:
            msg = "log-format-error"
        sys.stderr.write("oc-union-proxy %s\n" % scrub(msg))

    def _send_json(self, status: int, obj) -> None:
        body = scrub_bytes(json.dumps(obj).encode())
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def _authorized(self) -> bool:
        presented = (self.headers.get("Authorization") or "").encode()
        expected = ("Bearer " + self.token).encode()
        return hmac.compare_digest(
            hashlib.sha256(presented).digest(), hashlib.sha256(expected).digest()
        )

    def _healthz(self):
        body = b"ok"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _forward(self):
        if not self._authorized():
            sys.stderr.write("oc-union-proxy rejected request without lane token\n")
            self._send_json(401, {"error": "unauthorized"})
            return
        Handler.last_activity = time.time()
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self._send_json(400, {"error": "bad content-length"})
            return
        body = self.rfile.read(length) if length else None
        # T-b ceiling: the key may only be spent on the union-alpha model. A
        # JSON request body naming any other model is refused here, at the
        # key holder — config-side model pinning alone is agent-editable.
        if body:
            try:
                model = json.loads(body).get("model")
            except (ValueError, AttributeError):
                model = None
            if isinstance(model, str) and model not in self.allowed_models:
                self._send_json(403, {"error": "model not allowed on this lane"})
                return
        conn_cls = http.client.HTTPSConnection if self.upstream_tls else http.client.HTTPConnection
        conn = conn_cls(self.upstream_host, self.upstream_port, timeout=300)
        headers = {
            k: v
            for k, v in self.headers.items()
            if k.lower() not in HOP_BY_HOP and k.lower() not in {"host", "authorization", "content-length"}
        }
        headers["Authorization"] = f"Bearer {self.key}"
        try:
            conn.request(self.command, self.path, body=body, headers=headers)
            resp = conn.getresponse()
        except OSError as exc:
            self._send_json(502, {"error": "upstream connect failed: %s" % exc})
            return
        except Exception as exc:  # never leak internals on odd upstream failures
            self._send_json(502, {"error": "upstream request failed: %s" % type(exc).__name__})
            return
        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() in HOP_BY_HOP or k.lower() == "content-length":
                continue
            self.send_header(k, v)
        self.send_header("Connection", "close")
        self.end_headers()
        # Upstream bodies are relayed through a scrubber — an error body that
        # echoes our Authorization header must not reach the lane. A sliding
        # tail alone is not enough: a secret split across the emit boundary
        # would leak its prefix. So the emit point retreats in front of any
        # secret occurrence that straddles it, and `pending` stays unscrubbed
        # until a whole secret can be matched against it.
        keep = max((len(s) for s in SECRETS if s), default=1) - 1
        pending = b""
        try:
            while True:
                chunk = resp.read(65536)
                if not chunk:
                    if pending:
                        self.wfile.write(scrub_bytes(pending))
                        self.wfile.flush()
                    break
                buf = pending + chunk
                emit_end = max(len(buf) - keep, 0)
                moved = True
                while moved:
                    moved = False
                    for secret in SECRETS:
                        if not secret:
                            continue
                        needle = secret.encode()
                        pos = buf.find(needle)
                        while pos != -1:
                            if pos < emit_end < pos + len(needle):
                                emit_end = pos
                                moved = True
                            pos = buf.find(needle, pos + 1)
                emit, pending = buf[:emit_end], buf[emit_end:]
                if emit:
                    self.wfile.write(scrub_bytes(emit))
                    self.wfile.flush()
        except OSError as exc:
            sys.stderr.write("oc-union-proxy stream error: %s\n" % scrub(str(exc)))
        self.close_connection = True
        conn.close()

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = lambda self: (
        self._healthz() if self.path == "/healthz" else self._forward()
    )


def watchdog(server, idle_timeout: float) -> None:
    """Fail-closed lifetime backstop: a lane that stops calling us is dead.

    The completion sentinel kills us on lane loss; this covers lanes that ran
    without a sentinel (unregistered jobs) and operator-killed panes.
    """
    while True:
        time.sleep(15)
        if idle_timeout and time.time() - Handler.last_activity > idle_timeout:
            sys.stderr.write("oc-union-proxy idle timeout — exiting\n")
            server.shutdown()
            return


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--key-file", required=True)
    ap.add_argument("--state-dir", required=True, help="portfile/pidfile live here")
    ap.add_argument("--token-env", default="OC_UNION_PROXY_TOKEN",
                    help="env var holding the per-lane bearer token")
    ap.add_argument("--idle-timeout", type=float, default=21600,
                    help="seconds without an authorized request before exit (0 disables)")
    ap.add_argument("--upstream", default="openrouter.ai", help="upstream host[:port]")
    ap.add_argument("--upstream-http", action="store_true",
                    help="plain-HTTP upstream (tests only; production stays TLS)")
    ap.add_argument("--allowed-models", default="stealth/union-alpha",
                    help="comma-separated model ids the key may be spent on")
    args = ap.parse_args()

    key = extract_key(os.path.expanduser(args.key_file))
    token = os.environ.get(args.token_env, "")
    if not token:
        raise SystemExit(f"{args.token_env} is not set — refusing to serve an unauthenticated proxy")
    SECRETS.extend([key, token])
    Handler.key = key
    Handler.token = token

    host, _, port = args.upstream.rpartition(":")
    if host and port.isdigit():
        Handler.upstream_host, Handler.upstream_port = host, int(port)
    else:
        Handler.upstream_host = args.upstream
    Handler.upstream_tls = not args.upstream_http
    Handler.allowed_models = frozenset(
        m.strip() for m in args.allowed_models.split(",") if m.strip()
    )

    state = Path(args.state_dir)
    state.mkdir(parents=True, exist_ok=True)
    server = _Server(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    (state / "proxy.port").write_text(f"{port} {os.getpid()}\n")
    (state / "proxy.pid").write_text(f"{os.getpid()}\n")
    sys.stderr.write(f"oc-union-proxy listening 127.0.0.1:{port}\n")
    threading.Thread(target=watchdog, args=(server, args.idle_timeout), daemon=True).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        for name in ("proxy.port", "proxy.pid"):
            try:
                (state / name).unlink()
            except OSError:
                pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
