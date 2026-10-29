"""Loopback TLS/range fixture; no YouTube requests or saved media."""
import http.server
import ssl
import sys
import time
import urllib.parse


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        scenario = query.get("scenario", ["ok"])[0]
        length = 4_000_000 if query.get("itag") == ["139"] else 12_000_000
        mime = "audio/mp4" if length == 4_000_000 else "video/mp4"
        start, end = map(int, self.headers["Range"].removeprefix("bytes=").split("-"))
        count = end - start + 1
        if scenario == "stall":
            time.sleep(20)
        self.send_response(200 if scenario == "ignore" else 206)
        self.send_header("Content-Type", "text/html" if scenario == "text" else mime)
        self.send_header("Content-Length", str(length if scenario == "ignore" else count))
        if scenario != "ignore":
            self.send_header("Content-Range", f"bytes {start}-{end}/{length}")
        self.end_headers()
        remaining = 4096 if scenario == "truncate" else count
        chunk = b"\x00\x00\x00\x18ftypmp42" + bytes(32756)
        try:
            while remaining:
                part = chunk[: min(remaining, len(chunk))]
                self.wfile.write(part)
                remaining -= len(part)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass
        self.close_connection = True


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[1], sys.argv[2])
server.socket = context.wrap_socket(server.socket, server_side=True)
with open(sys.argv[3], "w") as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
