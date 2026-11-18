#!/usr/bin/env python3
"""Loopback stand-in for Google's quota service, for ai-quotas-antigravity.test.sh.

Usage: antigravity-backend-stub.py <dir>
<dir>/mode holds ok | 401 | shape | notjson (read on every request); the served port is
written to <dir>/port. For each request one line goes to <dir>/seen: the path, whether the
bearer token equalled the contents of <dir>/token, and the request body's project field.
The token itself is never written anywhere.
"""
import http.server
import json
import os
import sys

D = sys.argv[1]
GOOD = open(os.path.join(D, "good.json"), "rb").read()
BAD = open(os.path.join(D, "bad.json"), "rb").read()
TOKEN = open(os.path.join(D, "token")).read().strip()


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0") or 0))
        mode = open(os.path.join(D, "mode")).read().strip()
        ok = self.headers.get("Authorization") == "Bearer " + TOKEN
        try:
            project = json.loads(body).get("project", "")
        except ValueError:
            project = ""
        with open(os.path.join(D, "seen"), "a") as f:
            f.write("%s token_ok=%s project=%s\n" % (self.path, ok, project))
        if mode == "redirect":
            self.send_response(302)
            self.send_header("Location", "http://127.0.0.1:9/elsewhere")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif mode == "401" or not ok:
            self.send(401, b'{"error":{"code":401}}')
        elif self.path.endswith(":loadCodeAssist"):
            self.send(200, b'{"cloudaicompanionProject":"aicode-consumers"}')
        elif mode == "notjson":
            self.send(200, b"<html>")
        else:
            self.send(200, BAD if mode == "shape" else GOOD)

    def send(self, code, data):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(D, "port"), "w").write(str(srv.server_address[1]))
srv.serve_forever()
