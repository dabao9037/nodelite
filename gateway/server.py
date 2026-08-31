#!/usr/bin/env python3
"""Minimal random-path reverse proxy for NodeLite's HTTP control plane."""
from __future__ import annotations

import http.client
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ACCESS_PATH = os.environ.get("ACCESS_PATH", "").strip("/")
if not re.fullmatch(r"[A-Za-z0-9_-]{8,64}", ACCESS_PATH):
    raise SystemExit("invalid ACCESS_PATH")
PREFIX = f"/{ACCESS_PATH}"
UPSTREAM_HOST = "panel"
UPSTREAM_PORT = 8080
HOP_HEADERS = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers", "transfer-encoding", "upgrade"}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args):
        print(f'{self.client_address[0]} - {format % args}', flush=True)

    def send_empty(self, status: int, location: str | None = None):
        self.send_response(status)
        if location:
            self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def proxy(self):
        if self.path == "/healthz":
            body = b"ok"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == PREFIX:
            self.send_empty(308, PREFIX + "/")
            return
        if not self.path.startswith(PREFIX + "/"):
            self.send_empty(404)
            return

        upstream_path = self.path[len(PREFIX):] or "/"
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length else None
        headers = {
            key: value for key, value in self.headers.items()
            if key.lower() not in HOP_HEADERS and key.lower() not in {"host", "content-length"}
        }
        headers["Host"] = self.headers.get("Host", "")
        headers["X-Real-IP"] = self.client_address[0]
        forwarded = self.headers.get("X-Forwarded-For")
        headers["X-Forwarded-For"] = f"{forwarded}, {self.client_address[0]}" if forwarded else self.client_address[0]
        headers["X-Forwarded-Proto"] = self.headers.get("X-Forwarded-Proto", "http")
        headers["X-Forwarded-Prefix"] = PREFIX
        if body is not None:
            headers["Content-Length"] = str(len(body))

        connection = http.client.HTTPConnection(UPSTREAM_HOST, UPSTREAM_PORT, timeout=30)
        try:
            connection.request(self.command, upstream_path, body=body, headers=headers)
            response = connection.getresponse()
            payload = response.read()
            self.send_response(response.status, response.reason)
            for key, value in response.getheaders():
                if key.lower() not in HOP_HEADERS and key.lower() != "content-length":
                    self.send_header(key, value)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(payload)
        except Exception as exc:
            message = f"upstream unavailable: {exc}".encode()
            self.send_response(502)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(message)))
            self.end_headers()
            self.wfile.write(message)
        finally:
            connection.close()

    do_GET = proxy
    do_HEAD = proxy
    do_POST = proxy
    do_PUT = proxy
    do_DELETE = proxy
    do_PATCH = proxy


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
