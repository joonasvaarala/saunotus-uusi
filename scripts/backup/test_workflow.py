"""Työnkulku ja migraatio eivät vuoda salaisuuksia eivätkä käynnisty PR:ssä."""
from __future__ import annotations

import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "db-backup.yml"
MIGRATION = ROOT / "booking" / "supabase" / "migrations" / "20261019140000_ops_001_backup_reader.sql"
ROLLBACK = ROOT / "booking" / "supabase" / "rollbacks" / "20261019140000_ops_001_ROLLBACK.sql"
MIGRATION_STORAGE = ROOT / "booking" / "supabase" / "migrations" / "20261019140100_ops_002_backup_storage_read.sql"
ROLLBACK_STORAGE = ROOT / "booking" / "supabase" / "rollbacks" / "20261019140100_ops_002_ROLLBACK.sql"
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
            "RCLONE_DRIVE_TOKEN",
            "BACKUP_DRIVE_FOLDER_ID",
            "BACKUP_STORAGE_EMAIL",
            "BACKUP_STORAGE_PASSWORD",
        ):
            self.assertIn(secret, text)
        self.assertNotIn("SUPABASE_SERVICE_ROLE_KEY", text)
        self.assertIn("vars.SUPABASE_URL", text)
        self.assertIn("vars.SUPABASE_ANON_KEY", text)
        self.assertIn("id: gate", text)
        self.assertIn("steps.gate.outputs.ready", text)
        self.assertIn("::notice title=Varmuuskopio ohitettu::", text)
        self.assertIn("name: Varmuuskopio", text)
        self.assertNotIn("\n  deploy:", text)
        self.assertIn("postgres:17", text)
        self.assertIn("Europe/Helsinki", text)

    def test_pages_workflow_does_not_call_backup(self):
        text = PAGES.read_text(encoding="utf-8")
        self.assertNotIn("backup.sh", text)
        self.assertIn("scripts/backup -p 'test_*.py'", text)

    def test_shell_syntax(self):
        for name in ("backup.sh", "restore-test.sh", "hetzner_upload.sh"):
            path = Path(__file__).resolve().parent / name
            subprocess.check_call(["bash", "-n", str(path)])

    def test_hetzner_step_follows_drive_and_does_not_change_schedule(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("cron: '15 0 * * *'", text)
        self.assertIn("id: backup", text)
        self.assertIn("BACKUP_OUTPUT_DIR: ${{ runner.temp }}/tapio-age", text)
        self.assertIn("name: Lähetä Hetznerille", text)
        self.assertIn("if: steps.backup.outcome == 'success'", text)
        self.assertIn("bash scripts/backup/hetzner_upload.sh", text)
        self.assertLess(
            text.rfind("bash scripts/backup/backup.sh"),
            text.find("bash scripts/backup/hetzner_upload.sh"),
        )
        self.assertLess(
            text.find("name: Dumppi, salaus ja lähetys"),
            text.find("name: Lähetä Hetznerille"),
        )
        self.assertEqual(text.count("secrets.BACKUP_SSH_KEY"), 1)
        self.assertEqual(text.count("secrets.BACKUP_SSH_KNOWN_HOSTS"), 1)
        self.assertIn("vars.BACKUP_SSH_HOST", text)
        self.assertIn("vars.BACKUP_SSH_USER", text)
        self.assertNotIn("continue-on-error", text)
        self.assertNotIn("StrictHostKeyChecking=no", text)
        self.assertNotIn("scp ", text)
        self.assertNotIn("rsync", text)
        job_env = text.split("    steps:", 1)[0]
        self.assertNotIn("BACKUP_SSH_KEY", job_env)
        self.assertNotIn("BACKUP_SSH_KNOWN_HOSTS", job_env)

    def test_migration_has_no_password_and_stays_in_transaction(self):
        sql = MIGRATION.read_text(encoding="utf-8")
        rollback = ROLLBACK.read_text(encoding="utf-8")
        storage = MIGRATION_STORAGE.read_text(encoding="utf-8")
        storage_rollback = ROLLBACK_STORAGE.read_text(encoding="utf-8")
        sql_code = "\n".join(line for line in sql.splitlines() if not line.strip().startswith("--"))
        rollback_code = "\n".join(line for line in rollback.splitlines() if not line.strip().startswith("--"))
        storage_code = "\n".join(line for line in storage.splitlines() if not line.strip().startswith("--"))
        self.assertIn("ops_001_backup_reader", sql)
        self.assertIn("20261019140000", sql)
        self.assertNotRegex(sql, r"(?m)^commit;\s*$")
        self.assertNotRegex(rollback, r"(?m)^commit;\s*$")
        self.assertNotIn("vault", sql)
        self.assertIn("bypassrls", sql)
        self.assertIn("pg_read_all_data", sql)
        self.assertIn("default_transaction_read_only", sql)
        self.assertNotRegex(sql_code.lower(), r"password\s+'")
        self.assertNotRegex(sql_code.lower(), r"password\s+\"")
        self.assertNotIn("sb_secret", sql)
        self.assertIn("drop role backup_reader", rollback)
        self.assertNotRegex(rollback_code.lower(), r"password\s+'")
        grant_at = rollback_code.lower().find(
            "grant backup_reader to current_user with inherit true, set false;"
        )
        drop_owned_at = rollback_code.lower().find("drop owned by backup_reader;")
        self.assertGreater(grant_at, -1)
        self.assertLess(grant_at, drop_owned_at)
        self.assertIn("ops_002_backup_storage_read", storage)
        self.assertIn("20261019140100", storage)
        self.assertNotRegex(storage, r"(?m)^commit;\s*$")
        self.assertNotRegex(storage_rollback, r"(?m)^commit;\s*$")
        self.assertIn("backup_storage_reader_select", storage)
        self.assertIn("for select", storage)
        self.assertIn("app_metadata", storage)
        self.assertIn("backup_role", storage)
        self.assertIn("receipts", storage)
        self.assertIn("invoices", storage)
        self.assertNotIn("email", storage_code.lower())
        self.assertNotRegex(storage_code.lower(), r"\bfor\s+(insert|update|delete)\b")
        self.assertIn("drop policy if exists backup_storage_reader_select", storage_rollback)


if __name__ == "__main__":
    unittest.main()
