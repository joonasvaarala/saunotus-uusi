"""Storage API -lataus paikallista HTTP-palvelinta vasten."""
from __future__ import annotations

import hashlib
import json
import threading
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory

from common import BackupError
from storage_download import download


FILES = {
    "a.txt": b"hello",
    "sub/b.txt": b"world",
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _json(self, payload, status=200):
        raw = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _auth_ok(self):
        return self.headers.get("Authorization") == "Bearer test-key" and self.headers.get("apikey") == "test-key"

    def do_GET(self):
        if not self._auth_ok():
            self._json({"error": "no"}, 401)
            return
        if self.path == "/storage/v1/bucket":
            self._json([{"id": "photos", "name": "photos", "public": False}, {"id": "logos", "name": "logos", "public": True}])
            return
        prefix = "/storage/v1/object/photos/"
        if self.path.startswith(prefix):
            rel = urllib.parse.unquote(self.path[len(prefix):])
            if rel in FILES:
                blob = FILES[rel]
                self.send_response(200)
                self.send_header("Content-Length", str(len(blob)))
                self.end_headers()
                self.wfile.write(blob)
                return
        self._json({"error": "missing"}, 404)

    def do_POST(self):
        if not self._auth_ok():
            self._json({"error": "no"}, 401)
            return
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length).decode("utf-8") or "{}")
        if self.path == "/storage/v1/object/list/logos":
            self._json([])
            return
        if self.path != "/storage/v1/object/list/photos":
            self._json({"error": "bucket"}, 404)
            return
        prefix = body.get("prefix") or ""
        if prefix == "":
            self._json([
                {"name": "a.txt", "id": "file-a", "metadata": {"size": 5}},
                {"name": "sub", "id": None},
            ])
            return
        if prefix == "sub/":
            self._json([{"name": "b.txt", "id": "file-b", "metadata": {"size": 5}}])
            return
        self._json([])


class StorageDownloadTest(unittest.TestCase):
    def test_downloads_nested_files_and_hashes(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        port = server.server_address[1]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with TemporaryDirectory() as tmp:
                summary = download(f"http://127.0.0.1:{port}", "test-key", Path(tmp), 100, 1000000)
                self.assertEqual(summary["file_count"], 2)
                self.assertEqual(summary["bytes"], 10)
                text = (Path(tmp) / "files" / "photos" / "a.txt").read_bytes()
                nested = (Path(tmp) / "files" / "photos" / "sub" / "b.txt").read_bytes()
                self.assertEqual(text, b"hello")
                self.assertEqual(nested, b"world")
                by_path = {item["path"]: item["sha256"] for item in summary["files"]}
                self.assertEqual(by_path["a.txt"], hashlib.sha256(b"hello").hexdigest())
                self.assertEqual(by_path["sub/b.txt"], hashlib.sha256(b"world").hexdigest())
        finally:
            server.shutdown()
            server.server_close()

    def test_rejects_parent_segment(self):
        class Evil(Handler):
            def do_POST(self):
                length = int(self.headers.get("Content-Length") or 0)
                self.rfile.read(length)
                self._json([{"name": "../evil.txt", "id": "x", "metadata": {}}])

        server = ThreadingHTTPServer(("127.0.0.1", 0), Evil)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with TemporaryDirectory() as tmp:
                with self.assertRaises(BackupError):
                    download(f"http://127.0.0.1:{port_of(server)}", "test-key", Path(tmp), 100, 1000000)
        finally:
            server.shutdown()
            server.server_close()


def port_of(server: ThreadingHTTPServer) -> int:
    return server.server_address[1]


if __name__ == "__main__":
    unittest.main()
