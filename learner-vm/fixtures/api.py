"""Deterministic, dependency-free replacement for the labs' public image API."""

from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
import re
import struct
from urllib.parse import urlsplit
import zlib


def fixture_png():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    rows = []
    for vertical in range(64):
        row = bytearray(b"\0")
        for horizontal in range(64):
            shape = (14 <= horizontal <= 49 and 17 <= vertical <= 47) or (9 <= horizontal <= 20 and 9 <= vertical <= 34) or (43 <= horizontal <= 54 and 9 <= vertical <= 34)
            eyes = (23 <= horizontal <= 26 or 37 <= horizontal <= 40) and 26 <= vertical <= 29
            nose = 28 <= horizontal <= 35 and 36 <= vertical <= 40
            row.extend((28, 28, 28) if eyes or nose else (181, 150, 111) if shape else (235, 239, 233))
        rows.append(bytes(row))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 64, 64, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b"")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlsplit(self.path).path
        match = re.fullmatch(r"/api/breed/([a-z-]+)/images/random", path)
        if path == "/healthz":
            data = b"ok\n"
            media = "text/plain"
        elif path == "/api/breeds/image/random" or match:
            breed = match.group(1) if match else "husky"
            origin = os.environ.get("FIXTURE_PUBLIC_URL", "http://" + self.headers.get("Host", "127.0.0.1:18187")).rstrip("/")
            data = json.dumps({"status": "success", "message": origin + "/dog.ceo/breeds/" + breed + "/fixture.png"}).encode("utf-8")
            media = "application/json"
        elif re.fullmatch(r"/dog\.ceo/breeds/[a-z-]+/fixture\.png", path):
            data = fixture_png()
            media = "image/png"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", media)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    HTTPServer((os.environ.get("FIXTURE_BIND", "0.0.0.0"), int(os.environ.get("FIXTURE_PORT", "18187"))), Handler).serve_forever()