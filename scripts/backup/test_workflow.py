"""Työnkulku ja migraatio eivät vuoda salaisuuksia eivätkä käynnisty PR:ssä."""
from __future__ import annotations

import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "db-backup.yml"
MIGRATION = ROOT / "booking" / "supabase" / "migrations" / "20261019140000_ops_001_backup_reader.sql"
ROLLBACK = ROOT / "booking" / "supabase" / "rollbacks" / "20261019140000_ops_001_ROLLBACK.sql"
PAGES = ROOT / ".github" / "workflows" / "pages.yml"


class WorkflowAndSqlTest(unittest.TestCase):
    def test_workflow_is_schedule_only(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("cron: '15 0 * * *'", text)
        self.assertIn("workflow_dispatch:", text)
        self.assertNotIn("pull_request", text)
        self.assertNotIn("deploy-pages", text)
        self.assertNotIn("push:", text)
        self.assertIn("group: tapio-havuhattu-db-backup", text)
        self.assertIn("cancel-in-progress: false", text)
        self.assertIn("contents: read", text)
        self.assertNotIn("pages: write", text)
        self.assertNotIn("id-token:", text)
        for secret in (
            "SUPABASE_BACKUP_DB_URL",
            "BACKUP_AGE_PUBLIC_KEY",
            "SUPABASE_SERVICE_ROLE_KEY",
            "RCLONE_DRIVE_TOKEN",
            "BACKUP_DRIVE_FOLDER_ID",
        ):
            self.assertIn(secret, text)
        self.assertIn("name: Varmuuskopio", text)
        self.assertNotIn("\n  deploy:", text)
        self.assertIn("postgres:17", text)
        self.assertIn("Europe/Helsinki", text)

    def test_pages_workflow_does_not_call_backup(self):
        text = PAGES.read_text(encoding="utf-8")
        self.assertNotIn("backup.sh", text)
        self.assertIn("scripts/backup -p 'test_*.py'", text)

    def test_shell_syntax(self):
        for name in ("backup.sh", "restore-test.sh"):
            path = Path(__file__).resolve().parent / name
            subprocess.check_call(["bash", "-n", str(path)])

    def test_migration_has_no_password_and_escapes_transaction(self):
        sql = MIGRATION.read_text(encoding="utf-8")
        rollback = ROLLBACK.read_text(encoding="utf-8")
        sql_code = "\n".join(line for line in sql.splitlines() if not line.strip().startswith("--"))
        rollback_code = "\n".join(line for line in rollback.splitlines() if not line.strip().startswith("--"))
        self.assertIn("ops_001_backup_reader", sql)
        self.assertIn("20261019140000", sql)
        self.assertRegex(sql, r"(?m)^commit;\s*$")
        self.assertIn("bypassrls", sql)
        self.assertIn("pg_read_all_data", sql)
        self.assertIn("default_transaction_read_only", sql)
        self.assertNotRegex(sql_code.lower(), r"password\s+'")
        self.assertNotRegex(sql_code.lower(), r"password\s+\"")
        self.assertNotIn("sb_secret", sql)
        self.assertRegex(rollback, r"(?m)^commit;\s*$")
        self.assertIn("drop role backup_reader", rollback)
        self.assertNotRegex(rollback_code.lower(), r"password\s+'")


if __name__ == "__main__":
    unittest.main()
