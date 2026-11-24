"""Stub GitHub token endpoint, theme API and S3 upload for the contract tests.

Serves HTTPS on one port. curl reaches it for every host through `connect-to` in the test `.curlrc`.
Usage: stub.py <port> <certificate> <key> <scenario> <request log>
"""
import base64
import hashlib
import json
import ssl
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

PORT, CERT, KEY, SCENARIO, LOG = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
SITE = "wordpress-test.123456789012.app.dataside.cloud"
REQUEST_TOKEN = "fake-request-token"
UPLOAD_URL = "https://theme-bucket.s3.example/themes/p-1.tar.gz?X-Amz-Signature=fake-presigned-signature"
PUBLISH_ID = "p-1"
calls = {}
published = {}
publish_tokens = set()


def error(status, code):
    return status, {"error": code, "message": f"stub refusal {code}"}


def theme_api(route, body, count, token):
    """Returns the status and body that the theme API sends for this scenario."""
    if route == "POST /bind":
        if "code" not in body:
            return 202, {"status": "binding-requested"}
        if SCENARIO == "rerun-with-code":
            return error(400, "no-pending-binding")
        if SCENARIO == "wrong-code":
            return error(400, "wrong-code")
        return 200, {"status": "bound"}
    if route == "POST /publish":
        # Like the theme API, records the token before any later step can fail.
        if token in publish_tokens:
            return error(409, "token-reused")
        publish_tokens.add(token)
        if SCENARIO == "publish-5xx" and count == 1:
            return error(500, "internal")
        if SCENARIO == "not-bound":
            return error(403, "not-bound")
        if SCENARIO == "trial-in-progress" and count == 1:
            return error(409, "trial-in-progress")
        published.update(body)
        checksum = base64.b64encode(bytes.fromhex(body["sha256"])).decode()
        return 200, {"publish_id": PUBLISH_ID, "upload_url": UPLOAD_URL,
                     "upload_headers": {"x-amz-checksum-sha256": checksum, "content-length": str(body["size"])}}
    if route == "POST /commit":
        if body != {"publish_id": PUBLISH_ID, "sha256": published.get("sha256"), "theme": "acme"}:
            return error(400, "bad-request")
        return 202, {"status": "trial"}
    if route == "GET /result":
        if count == 1:
            return 200, {"status": "pending"}
        if SCENARIO == "rejected":
            return 200, {"status": "rejected", "reason": "php-lint", "file": "inc/blocks.php", "line": 42}
        return 200, {"status": "good"}
    return error(404, "not-found")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body, content_type="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def record(self, entry):
        with open(LOG, "a") as log:
            log.write(json.dumps(entry) + "\n")

    def handle_request(self):
        url = urlsplit(self.path)
        host = self.headers["Host"].split(":")[0]
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        auth = self.headers.get("Authorization")
        if url.path == "/token":
            audience = parse_qs(url.query).get("audience", [""])[0]
            ok = auth == f"Bearer {REQUEST_TOKEN}" and audience == SITE
            calls["token"] = calls.get("token", 0) + 1
            return self.reply(200, {"value": f"fake-oidc-token-{calls['token']}"}) if ok else self.reply(403, {})
        if host == "theme-bucket.s3.example":
            # S3 accepts the upload only with the signed checksum and size, and no Authorization header.
            checksum = base64.b64encode(hashlib.sha256(raw).digest()).decode()
            ok = (self.command == "PUT" and auth is None
                  and self.headers.get("x-amz-checksum-sha256") == checksum
                  and len(raw) == published.get("size"))
            self.record({"route": "PUT upload", "ok": ok})
            if ok and SCENARIO != "s3-refuses":
                return self.reply(200, b"", "application/xml")
            return self.reply(400, b"<Error><Code>BadDigest</Code></Error>", "application/xml")
        if host != SITE or not url.path.startswith("/dataside-theme-api/"):
            return self.reply(404, {"error": "not-found", "message": "wrong host or path"})
        route = f"{self.command} {url.path.removeprefix('/dataside-theme-api')}"
        calls[route] = calls.get(route, 0) + 1
        body = json.loads(raw) if raw else {}
        token_ok = bool(auth) and auth.startswith("Bearer fake-oidc-token-")
        status, answer = theme_api(route, body, calls[route], auth) if token_ok else error(401, "invalid-token")
        self.record({"route": route, "body": body, "status": status})
        self.reply(status, answer)

    do_GET = do_POST = do_PUT = handle_request


server = ThreadingHTTPServer(("127.0.0.1", int(PORT)), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(CERT, KEY)
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
