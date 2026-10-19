"""Osoitteiden tarkistus. Ei avaa yhteyttä."""
from __future__ import annotations

import os
import subprocess
import tempfile
import unittest

from common import BackupError
from dburl import parse_database_url, write_env_file


class DbUrlTest(unittest.TestCase):
    def test_roundtrip_password(self):
        url = "postgresql://backup_reader.sxbofnuisemspgquoxyv:p%40ss%20'word@aws-0-eu-west-3.pooler.supabase.com:5432/postgres"
        values = parse_database_url(url, "backup")
        self.assertEqual(values["PGUSER"], "backup_reader.sxbofnuisemspgquoxyv")
        self.assertEqual(values["PGPASSWORD"], "p@ss 'word")
        self.assertEqual(values["PGPORT"], "5432")
        self.assertEqual(values["PGSSLMODE"], "require")
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "env")
            write_env_file(path, values)
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
            quoted = subprocess.check_output(
                ["bash", "-c", 'set -a; . "$1"; set +a; printf %s "$PGPASSWORD"', "bash", path],
                text=True,
            )
            self.assertEqual(quoted, "p@ss 'word")

    def test_rejects_transaction_pooler(self):
        url = "postgresql://backup_reader.sxbofnuisemspgquoxyv:secret@aws-0-eu-west-3.pooler.supabase.com:6543/postgres"
        with self.assertRaises(BackupError) as caught:
            parse_database_url(url, "backup")
        self.assertNotIn("secret", str(caught.exception))

    def test_local_backup_disables_ssl(self):
        values = parse_database_url("postgresql://postgres:postgres@127.0.0.1:54329/postgres", "backup")
        self.assertEqual(values["PGSSLMODE"], "disable")

    def test_restore_allows_only_local(self):
        ok = parse_database_url("postgresql://postgres:restore-test-only@127.0.0.1:5432/postgres", "restore")
        self.assertEqual(ok["PGHOST"], "127.0.0.1")
        with self.assertRaises(BackupError):
            parse_database_url(
                "postgresql://postgres:secret@db.sxbofnuisemspgquoxyv.supabase.co:5432/postgres",
                "restore",
            )
        with self.assertRaises(BackupError):
            parse_database_url("postgresql://postgres:secret@127.0.0.1:5432/backup_restore_test", "restore")


if __name__ == "__main__":
    unittest.main()
