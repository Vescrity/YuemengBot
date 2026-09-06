#!/usr/bin/env python3
"""极简 HTTP 服务端：收到请求后延迟 1 秒再回复。

用法:
    python3 http_server.py [port]

默认监听 127.0.0.1:8000。
"""
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class SlowHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/404":
            body = b"not found\n"
            self.send_response(404)
        else:
            time.sleep(1)
            body = f"ok after 1s, path={self.path}\n".encode("utf-8")
            self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        data = self.rfile.read(length) if length else b""
        body = f"post path={self.path} body={data.decode('utf-8', 'replace')}\n".encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write("[http] %s\n" % (fmt % args))


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
    server = ThreadingHTTPServer(("127.0.0.1", port), SlowHandler)
    print(f"[http] 监听 127.0.0.1:{port}，每个请求延迟 1 秒")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
