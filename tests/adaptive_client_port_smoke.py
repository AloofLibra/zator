#!/usr/bin/env python3
"""Verify curl can bind a reserved client port without leaving localhost."""
import http.server
import os
import shutil
import subprocess
import threading


class Handler(http.server.BaseHTTPRequestHandler):
    source_port = None

    def do_GET(self):
        type(self).source_port = self.client_address[1]
        self.send_response(204)
        self.end_headers()

    def log_message(self, format, *args):
        pass


curl = shutil.which("curl.exe" if os.name == "nt" else "curl")
if not curl:
    raise SystemExit("curl executable is required for the client port smoke test")

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    port = server.server_address[1]
    result = subprocess.run(
        [
            curl,
            "--silent",
            "--show-error",
            "--noproxy",
            "*",
            "--interface",
            "127.0.0.1",
            "--local-port",
            "62000-62999",
            "--http1.1",
            "--resolve",
            f"probe.invalid:{port}:127.0.0.1",
            "--max-time",
            "5",
            "--write-out",
            "%{http_code}",
            f"http://probe.invalid:{port}/",
        ],
        capture_output=True,
        text=True,
        timeout=7,
        check=False,
    )
finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=2)

if result.returncode != 0 or result.stdout != "204":
    raise SystemExit(
        f"curl probe failed: rc={result.returncode}, stdout={result.stdout!r}, stderr={result.stderr!r}"
    )
if Handler.source_port is None or not 62000 <= Handler.source_port <= 62999:
    raise SystemExit(f"source port was not bound in lease range: {Handler.source_port!r}")
print(f"adaptive client source-port smoke ok ({Handler.source_port})")
