"""
Minimal HTTP service used as the payload for the supply-chain demo.

Deliberately boring: the point of this repo is the chain around the image,
not the app inside it.
"""

import json
import os
import socket
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(os.getenv("PORT", "8080"))
VERSION = os.getenv("APP_VERSION", "dev")


class Handler(BaseHTTPRequestHandler):
    def _json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self._json(200, {"status": "ok"})
        elif self.path == "/":
            self._json(
                200,
                {
                    "service": "supply-chain-demo",
                    "version": VERSION,
                    "pod": socket.gethostname(),
                },
            )
        else:
            self._json(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)


if __name__ == "__main__":
    print(f"listening on :{PORT} (version={VERSION})", flush=True)
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
