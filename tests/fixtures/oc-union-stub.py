#!/usr/bin/env python3
"""oc-union proxy test stub: records inbound auth headers, replies 200 JSON.

Usage: python3 oc-union-stub.py STATE_DIR — writes STATE_DIR/stub.port and
appends one JSON line per request to STATE_DIR/seen.jsonl.
Not executable on purpose: CI shellcheck scans only executable fixtures.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

state = sys.argv[1]


class H(BaseHTTPRequestHandler):
    def _h(self):
        n = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(n)
        auth = self.headers.get("Authorization")
        with open(os.path.join(state, "seen.jsonl"), "a") as f:
            f.write(json.dumps({
                "path": self.path,
                "authorization": auth,
            }) + "\n")
        # Echo the received credential in the body — proves the proxy's
        # response-side scrubber redacts a reflected secret end-to-end.
        body = json.dumps({"ok": True, "auth_seen": auth}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST = _h

    def log_message(self, *a):
        pass


srv = HTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(state, "stub.port"), "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
