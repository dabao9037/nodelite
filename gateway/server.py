#!/usr/bin/env python3
"""Minimal random-path reverse proxy for NodeLite's HTTP control plane."""
from __future__ import annotations

import http.client
import os
import re
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ACCESS_PATH = os.environ.get("ACCESS_PATH", "").strip("/")
if not re.fullmatch(r"[A-Za-z0-9_-]{8,64}", ACCESS_PATH):
    raise SystemExit("invalid ACCESS_PATH")
PREFIX = f"/{ACCESS_PATH}"
UPSTREAM_HOST = os.environ.get("UPSTREAM_HOST", "panel")
UPSTREAM_PORT = int(os.environ.get("UPSTREAM_PORT", "8080"))
LISTEN_HOST = os.environ.get("LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8080"))
TLS_CERT = os.environ.get("TLS_CERT", "").strip()
TLS_KEY = os.environ.get("TLS_KEY", "").strip()
TLS_ACTIVE = False
HOP_HEADERS = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers", "transfer-encoding", "upgrade"}


def build_tls_context() -> ssl.SSLContext | None:
    """TLS 是纯开关：两个都配才启用，只配一个直接拒绝启动，绝不静默降级成明文。"""
    if not TLS_CERT and not TLS_KEY:
        return None
    if not (TLS_CERT and TLS_KEY):
        raise SystemExit("TLS_CERT 和 TLS_KEY 必须同时设置")
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(TLS_CERT, TLS_KEY)
    return context


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def end_headers(self):
        # 只在 TLS 模式下发 HSTS：明文模式发 HSTS 会把用户锁在错误的 scheme 上。
        if TLS_ACTIVE:
            self.send_header("Strict-Transport-Security", "max-age=31536000")
        super().end_headers()

    def log_message(self, format: str, *args):
        print(f'{self.client_address[0]} - {format % args}', flush=True)

    def send_empty(self, status: int, location: str | None = None):
        self.send_response(status)
        if location:
            self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def health(self):
        connection = http.client.HTTPConnection(UPSTREAM_HOST, UPSTREAM_PORT, timeout=3)
        try:
            connection.request("GET", "/healthz", headers={"Host": self.headers.get("Host", "")})
            response = connection.getresponse()
            payload = response.read()
            self.send_response(response.status)
            self.send_header("Content-Type", response.getheader("Content-Type", "application/json"))
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(payload)
        except Exception as exc:
            payload = f'{{"status":"degraded","gateway":"{type(exc).__name__}"}}'.encode()
            self.send_response(503)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(payload)
        finally:
            connection.close()

    def proxy(self):
        if self.path == "/healthz":
            self.health()
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
        headers["X-Forwarded-Proto"] = (
            "https" if TLS_ACTIVE else self.headers.get("X-Forwarded-Proto", "http")
        )
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


def main():
    global TLS_ACTIVE
    context = build_tls_context()
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    if context is not None:
        server.socket = context.wrap_socket(server.socket, server_side=True)
        TLS_ACTIVE = True
        print(f"gateway: TLS enabled (cert={TLS_CERT})", flush=True)
    else:
        print("gateway: TLS disabled (plain HTTP)", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
