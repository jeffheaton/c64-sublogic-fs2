#!/usr/bin/env python3
"""Serves the web build (build/web) on localhost with the headers a host like Netlify or a
web server would send: COOP and COEP (cross-origin isolation, for SharedArrayBuffer), and the
WebAssembly type. GitHub Pages cannot send them; there the page's service worker adds them.

    Scripts/serve-web.py [directory] [port] [--pages]    (defaults: build/web 8064)

--pages serves without the isolation headers, as GitHub Pages does, to try the service worker.
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

    isolation_headers = True

    def end_headers(self):
        if self.isolation_headers:
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()


def main():
    args = [a for a in sys.argv[1:] if a != "--pages"]
    Handler.isolation_headers = "--pages" not in sys.argv
    directory = args[0] if len(args) > 0 else "build/web"
    port = int(args[1]) if len(args) > 1 else 8064
    handler = functools.partial(Handler, directory=directory)
    with http.server.ThreadingHTTPServer(("127.0.0.1", port), handler) as server:
        mode = "" if Handler.isolation_headers else " without isolation headers (as GitHub Pages)"
        print(f"Serving {directory} at http://localhost:{port}/{mode}")
        server.serve_forever()


if __name__ == "__main__":
    main()
