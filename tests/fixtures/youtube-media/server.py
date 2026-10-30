"""Loopback TLS/range fixture; no YouTube requests or saved media."""
import http.server
import ssl
import sys
import time
import urllib.parse


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def write_body(self, remaining, chunked=False):
        chunk = b"\x00\x00\x00\x18ftypmp42" + bytes(32756)
        try:
            while remaining:
                part = chunk[: min(remaining, len(chunk))]
                if chunked:
                    self.wfile.write(f"{len(part):x}\r\n".encode())
                self.wfile.write(part)
                if chunked:
                    self.wfile.write(b"\r\n")
                remaining -= len(part)
            if chunked:
                self.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass
        self.close_connection = True

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        scenario = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).get("scenario", [""])[0]
        self.send_response(204 if scenario == "empty" else 200)
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        self.write_body(0 if scenario == "empty" else 1_000_000, True)

    def do_GET(self):
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        scenario = query.get("scenario", ["ok"])[0]
        redirects = {
            "redirect": "ok",
            "redirect_twice": "redirect",
            "redirect_loop": "redirect_loop",
            "redirect_stall": "stall",
        }
        if scenario in redirects:
            query["scenario"] = [redirects[scenario]]
            location = "https://rr1---sn-example.googlevideo.com/videoplayback?" + urllib.parse.urlencode(query, doseq=True)
            self.send_response(302)
            self.send_header("Location", location)
            self.send_header("Content-Length", "0")
            self.end_headers()
            self.close_connection = True
            return
        length = 4_000_000 if query.get("itag") == ["139"] else 12_000_000
        mime = "audio/mp4" if length == 4_000_000 else "video/mp4"
        start, end = map(int, self.headers["Range"].removeprefix("bytes=").split("-"))
        count = end - start + 1
        if scenario == "stall":
            time.sleep(20)
        self.send_response(200 if scenario == "ignore" else 206)
        self.send_header("Content-Type", "text/html" if scenario == "text" else mime)
        chunked = scenario.startswith("chunked")
        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
        else:
            self.send_header("Content-Length", str(length if scenario == "ignore" else count))
        if scenario != "ignore":
            self.send_header("Content-Range", f"bytes {start}-{end}/{length}")
        self.end_headers()
        remaining = 4096 if scenario == "truncate" else count
        if scenario == "chunked_oversize":
            remaining = 20_000_000
        self.write_body(remaining, chunked)


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[1], sys.argv[2])
server.socket = context.wrap_socket(server.socket, server_side=True)
with open(sys.argv[3], "w") as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
