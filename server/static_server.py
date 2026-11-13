#!/usr/bin/env python3
"""Servidor estàtic amb la política de memòria cau del dashboard.

- Tot es serveix amb Cache-Control no-cache: el navegador es pot quedar la còpia però la revalida
  cada cop (SimpleHTTPRequestHandler envia Last-Modified, així que normalment és un 304 barat).
  Una pàgina nova arriba sola i una pàgina trencada no es queda enganxada a la memòria cau.
- Sense llistat de directoris (404).
- data/data.json també porta la capçalera Date i site_version (un hash del contingut de la pàgina):
  si canvia, la pàgina oberta es recarrega sola.
"""
import argparse
import functools
import http.server


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    def list_directory(self, path):
        self.send_error(http.HTTPStatus.NOT_FOUND, "No trobat")
        return None


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
