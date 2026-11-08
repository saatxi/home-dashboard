#!/usr/bin/env python3
"""Servidor estàtic amb la política de memòria cau del dashboard.

- data/: Cache-Control no-cache (sempre fresc; també porta la capçalera Date i site_version).
- La resta: un dia de memòria cau. Així el marc pot arrencar amb la pàgina guardada si el servidor
  encara no respon (les entrades amb no-cache no es serveixen sense xarxa). Les pàgines antigues
  s'actualitzen soles: data.json publica site_version i la pàgina navega a ?v=<versió>.
"""
import argparse
import functools
import http.server


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        path = self.path.split("?", 1)[0]
        if path.startswith("/data/"):
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
