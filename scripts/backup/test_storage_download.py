"""Storage-lataus paikallista HTTP-palvelinta vasten. Ei service role -avainta."""
from __future__ import annotations

import hashlib
import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory

from common import BackupError
from storage_download import download


PUBLIC = b"hello"
PRIVATE = b"receipt-pdf"


class Handler(BaseHTTPRequestHandler):
    login_authorization = "unset"
    login_apikey = ""

    def log_message(self, fmt, *args):
        return

    def _json(self, payload, status=200):
        raw = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        if self.path != "/auth/v1/token?grant_type=password":
            self._json({"error": "path"}, 404)
            return
        if self.headers.get("Authorization"):
            self._json({"error": "login must not send Authorization"}, 401)
            return
        if self.headers.get("apikey") != "anon-key":
            self._json({"error": "apikey"}, 401)
            return
        Handler.login_authorization = self.headers.get("Authorization")
        Handler.login_apikey = self.headers.get("apikey")
        body = json.loads(raw.decode("utf-8") or "{}")
        if body.get("email") != "backup@saunotus.fi" or body.get("password") != "storage-test-only":
            self._json({"error": "login"}, 400)
            return
        self._json({"access_token": "user-token", "token_type": "bearer"})

    def do_GET(self):
        public = "/storage/v1/object/public/article-images/a.txt"
        nested = "/storage/v1/object/public/product-images/sub/b.txt"
        private = "/storage/v1/object/authenticated/receipts/r.pdf"
        if self.path == public:
            if self.headers.get("Authorization"):
                self._json({"error": "public does not need auth"}, 400)
                return
            self._bytes(PUBLIC)
            return
        if self.path == nested:
            self._bytes(b"world")
            return
        if self.path == private:
            if self.headers.get("Authorization") != "Bearer user-token" or self.headers.get("apikey") != "anon-key":
                self._json({"error": "no"}, 401)
                return
            self._bytes(PRIVATE)
            return
        self._json({"error": "missing"}, 404)

    def _bytes(self, blob: bytes):
        self.send_response(200)
        self.send_header("Content-Length", str(len(blob)))
        self.end_headers()
        self.wfile.write(blob)


class DenyPrivate(Handler):
    def do_GET(self):
        if self.path.startswith("/storage/v1/object/authenticated/"):
            self._json({"error": "no"}, 403)
            return
        super().do_GET()


def serve(handler):
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


class StorageDownloadTest(unittest.TestCase):
    def test_downloads_public_without_key_and_private_with_user(self):
        server = serve(Handler)
        try:
            with TemporaryDirectory() as tmp:
                summary = download(
                    f"http://127.0.0.1:{server.server_address[1]}",
                    [
                        {"bucket": "article-images", "path": "a.txt", "private": False},
                        {"bucket": "product-images", "path": "sub/b.txt", "private": False},
                        {"bucket": "receipts", "path": "r.pdf", "private": True},
                    ],
                    Path(tmp),
                    anon_key="anon-key",
                    email="backup@saunotus.fi",
                    password="storage-test-only",
                    other_buckets=["logos"],
                )
                self.assertEqual(summary["file_count"], 3)
                self.assertEqual(summary["bytes"], len(PUBLIC) + len(b"world") + len(PRIVATE))
                self.assertEqual((Path(tmp) / "files" / "article-images" / "a.txt").read_bytes(), PUBLIC)
                self.assertEqual((Path(tmp) / "files" / "product-images" / "sub" / "b.txt").read_bytes(), b"world")
                self.assertEqual((Path(tmp) / "files" / "receipts" / "r.pdf").read_bytes(), PRIVATE)
                by_path = {item["path"]: item["sha256"] for item in summary["files"]}
                self.assertEqual(by_path["a.txt"], hashlib.sha256(PUBLIC).hexdigest())
                self.assertEqual(summary["private_missing"], [])
                self.assertIsNone(Handler.login_authorization)
                self.assertEqual(Handler.login_apikey, "anon-key")
                self.assertIn("logos", summary["other_buckets"])
                self.assertTrue(any("logos" in note for note in summary["notes"]))
        finally:
            server.shutdown()
            server.server_close()

    def test_private_failure_does_not_drop_public_files(self):
        server = serve(DenyPrivate)
        try:
            with TemporaryDirectory() as tmp:
                summary = download(
                    f"http://127.0.0.1:{server.server_address[1]}",
                    [
                        {"bucket": "article-images", "path": "a.txt", "private": False},
                        {"bucket": "invoices", "path": "lasku.pdf", "private": True},
                    ],
                    Path(tmp),
                    anon_key="anon-key",
                    email="backup@saunotus.fi",
                    password="storage-test-only",
                )
                self.assertEqual(summary["file_count"], 1)
                self.assertEqual(summary["private_missing"], [{"bucket": "invoices", "path": "lasku.pdf"}])
                self.assertTrue(any("yksityisiä" in note for note in summary["notes"]))
                self.assertTrue((Path(tmp) / "files" / "article-images" / "a.txt").is_file())
        finally:
            server.shutdown()
            server.server_close()

    def test_missing_private_credentials_keep_public_files(self):
        server = serve(Handler)
        try:
            with TemporaryDirectory() as tmp:
                summary = download(
                    f"http://127.0.0.1:{server.server_address[1]}",
                    [
                        {"bucket": "article-images", "path": "a.txt", "private": False},
                        {"bucket": "receipts", "path": "r.pdf", "private": True},
                    ],
                    Path(tmp),
                )
                self.assertEqual(summary["file_count"], 1)
                self.assertEqual(len(summary["private_missing"]), 1)
                self.assertTrue(any("BACKUP_STORAGE_EMAIL" in note for note in summary["notes"]))
                self.assertTrue(any("SUPABASE_ANON_KEY" in note for note in summary["notes"]))
        finally:
            server.shutdown()
            server.server_close()

    def test_rejects_parent_segment(self):
        with TemporaryDirectory() as tmp:
            with self.assertRaises(BackupError):
                download(
                    "http://127.0.0.1:9",
                    [{"bucket": "article-images", "path": "../evil.txt", "private": False}],
                    Path(tmp),
                )


if __name__ == "__main__":
    unittest.main()
