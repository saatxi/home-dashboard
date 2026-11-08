#!/usr/bin/env python3
"""Servidor estàtic amb la política de memòria cau del dashboard.

- index.html i data/: Cache-Control no-cache (es revaliden sempre, així els canvis arriben).
- css/ i js/: un dia de memòria cau; es refresquen pujant el ?v= a index.html.
"""
import argparse
import functools
import http.server


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        path = self.path.split("?", 1)[0]
        if path == "/" or path.endswith(".html") or path.startswith("/data/"):
            self.send_header("Cache-Control", "no-cache")
        else:
            self.send_header("Cache-Control", "max-age=86400")
        super().end_headers()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--directory", required=True)
    args = parser.parse_args()
    handler = functools.partial(Handler, directory=args.directory)
    http.server.ThreadingHTTPServer((args.bind, args.port), handler).serve_forever()


if __name__ == "__main__":
    main()
