"""Test double for R2 and Telegram. Checks AWS Signature V4 with its own
implementation, so a wrong secret or a changed body is refused like the real thing.
Usage: fake-r2.py <port> <key> <secret> <root>
<root>/mode may hold "truncate": the object is stored one byte short.
"""
import hashlib
import hmac
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

PORT, KEY, SECRET, ROOT = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def sign(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def signature_ok(h, body):
    auth = h.headers.get("Authorization", "")
    m = re.match(r"AWS4-HMAC-SHA256 Credential=([^/]+)/(\d+)/([^/]+)/([^/]+)/aws4_request, "
                 r"SignedHeaders=([^,]+), Signature=([0-9a-f]+)", auth)
    if not m:
        return False
    key, date, region, service, signed, got = m.groups()
    if key != KEY or region != "auto" or service != "s3":
        return False
    payload = h.headers.get("x-amz-content-sha256") or sha(body)
    if h.command == "PUT" and payload != sha(body):
        return False
    headers = "".join(f"{n}:{' '.join(h.headers.get(n, '').split())}\n" for n in signed.split(";"))
    canonical = "\n".join([h.command, h.path, "", headers, signed, payload])
    amz = h.headers.get("x-amz-date", "")
    scope = f"{date}/{region}/{service}/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz, scope, sha(canonical.encode())])
    k = sign(("AWS4" + SECRET).encode(), date)
    for part in (region, service, "aws4_request"):
        k = sign(k, part)
    return hmac.compare_digest(sign(k, to_sign).hex(), got)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def body(self):
        return self.rfile.read(int(self.headers.get("Content-Length", 0)))

    def reply(self, code, length=0):
        self.send_response(code)
        self.send_header("Content-Length", str(length))
        self.end_headers()

    def obj(self):
        return os.path.join(ROOT, os.path.basename(unquote(self.path)))

    def do_POST(self):
        data = self.body().decode()
        with open(os.path.join(ROOT, "telegram.log"), "a", encoding="utf-8") as f:
            f.write(f"{self.path} {unquote(data.replace('+', ' '))}\n")
        self.reply(200)

    def do_PUT(self):
        data = self.body()
        if not signature_ok(self, data):
            return self.reply(403)
        mode = os.path.join(ROOT, "mode")
        if os.path.exists(mode) and open(mode).read().strip() == "truncate":
            data = data[:-1]
        with open(self.obj(), "wb") as f:
            f.write(data)
        self.reply(200)

    def do_HEAD(self):
        if not signature_ok(self, b""):
            return self.reply(403)
        if not os.path.exists(self.obj()):
            return self.reply(404)
        self.reply(200, os.path.getsize(self.obj()))


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
