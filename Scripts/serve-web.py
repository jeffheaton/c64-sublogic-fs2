#!/usr/bin/env python3
"""Serves the web build (build/web) on localhost with the headers a host like Netlify or a
web server would send: COOP and COEP (cross-origin isolation, for SharedArrayBuffer), and the
WebAssembly type. GitHub Pages cannot send them; there the page's service worker adds them.

    Scripts/serve-web.py [directory] [port]      (defaults: build/web 8064)
"""
import functools
import http.server
import sys


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
        ".js": "text/javascript",
        ".d64": "application/octet-stream",
    }

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()


def main():
    directory = sys.argv[1] if len(sys.argv) > 1 else "build/web"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 8064
    handler = functools.partial(Handler, directory=directory)
    with http.server.ThreadingHTTPServer(("127.0.0.1", port), handler) as server:
        print(f"Serving {directory} at http://localhost:{port}/")
        server.serve_forever()


if __name__ == "__main__":
    main()
