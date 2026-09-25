#!/usr/bin/env python3
"""Small developer-side HTTPS endpoint for adaptive router acceptance."""

import argparse
import os
import socket
import socketserver
import ssl
import struct
import sys


MAX_TLS_RECORD = 18432
MAX_HTTP_HEADERS = 16384
READ_TIMEOUT_SECONDS = 8


def recv_exact(conn, size):
    data = bytearray()
    while len(data) < size:
        chunk = conn.recv(size - len(data))
        if not chunk:
            return None
        data.extend(chunk)
    return bytes(data)


class ThreadingTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True
    request_queue_size = 32


class ThreadingTCP6Server(ThreadingTCPServer):
    address_family = socket.AF_INET6


class AdaptiveHandler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(READ_TIMEOUT_SECONDS)
        mode = self.server.mode
        if mode == "rst":
            self.handle_rst()
        else:
            self.handle_https()

    def handle_rst(self):
        try:
            header = recv_exact(self.request, 5)
            if header is None:
                self.log("closed before TLS record")
                return
            if header[0] != 22:
                self.log("non-handshake record; reset")
                return
            record_size = struct.unpack("!H", header[3:5])[0]
            if record_size == 0 or record_size > MAX_TLS_RECORD:
                self.log("invalid TLS record length; reset")
                return
            record = recv_exact(self.request, record_size)
            if record is None:
                self.log("incomplete TLS handshake record; reset")
                return
            self.log("received TLS handshake record; sending RST")
        except (OSError, TimeoutError) as exc:
            self.log("read failed: %s" % exc)
        finally:
            try:
                self.request.setsockopt(
                    socket.SOL_SOCKET,
                    socket.SO_LINGER,
                    struct.pack("HH" if os.name == "nt" else "ii", 1, 0),
                )
            except OSError:
                pass
            try:
                self.request.close()
            except OSError:
                pass

    def handle_https(self):
        tls_conn = None
        try:
            tls_conn = self.server.tls_context.wrap_socket(
                self.request, server_side=True
            )
            tls_conn.settimeout(READ_TIMEOUT_SECONDS)
            request = bytearray()
            while b"\r\n\r\n" not in request and len(request) < MAX_HTTP_HEADERS:
                chunk = tls_conn.recv(min(2048, MAX_HTTP_HEADERS - len(request)))
                if not chunk:
                    break
                request.extend(chunk)
            if b"\r\n\r\n" not in request:
                self.log("HTTP headers missing or exceed limit")
                return
            body = b"ok\n"
            response = (
                b"HTTP/1.1 200 OK\r\n"
                b"Content-Type: text/plain\r\n"
                b"Cache-Control: no-store\r\n"
                b"Connection: close\r\n"
                b"Content-Length: "
                + str(len(body)).encode("ascii")
                + b"\r\n\r\n"
                + body
            )
            tls_conn.sendall(response)
            self.log("served HTTPS 200")
        except (OSError, ssl.SSLError, TimeoutError) as exc:
            self.log("HTTPS failed: %s" % exc)
        finally:
            if tls_conn is not None:
                try:
                    tls_conn.close()
                except OSError:
                    pass

    def log(self, message):
        print("%s:%s %s" % (self.client_address[0], self.client_address[1], message),
              flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("rst", "https"), required=True)
    parser.add_argument("--bind", default="0.0.0.0", help="listen address")
    parser.add_argument("--port", type=int, default=443)
    parser.add_argument("--cert", help="PEM certificate chain for --mode https")
    parser.add_argument("--key", help="PEM private key for --mode https")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("--port must be in 1..65535")
    if args.mode == "https" and (not args.cert or not args.key):
        parser.error("--mode https requires --cert and --key")

    tls_context = None
    if args.mode == "https":
        tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls_context.minimum_version = ssl.TLSVersion.TLSv1_2
        tls_context.load_cert_chain(args.cert, args.key)

    server_class = ThreadingTCP6Server if ":" in args.bind else ThreadingTCPServer
    server = server_class((args.bind, args.port), AdaptiveHandler)
    server.mode = args.mode
    server.tls_context = tls_context
    print("adaptive test endpoint mode=%s bind=%s port=%d" %
          (args.mode, args.bind, args.port), flush=True)
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
