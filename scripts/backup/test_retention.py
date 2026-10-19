"""Säilytyslogiikka ja kuivaharjoitus. Ei verkkoa."""
from __future__ import annotations

import os
import subprocess
import tempfile
import textwrap
import unittest
from datetime import date
from pathlib import Path

from common import BackupError, retention_plan
from retention import delete_local


TODAY = date(2026, 10, 19)


def name_for(day: str, hhmm: str = "0015") -> str:
    return f"tapio-havuhattu_{day}_{hhmm}.dump.tar.age"


class RetentionPlanTest(unittest.TestCase):
    def test_windows(self):
        names = [
            name_for("2026-10-19"),
            name_for("2026-10-01"),
            name_for("2026-09-20"),
            name_for("2026-09-18"),
            name_for("2026-09-01"),
            name_for("2025-11-01"),
            name_for("2025-10-01"),
            "muistiinpanot.txt",
            name_for("2026-13-40"),
            name_for("2026-12-01"),
        ]
        plan = retention_plan(names, TODAY)
        self.assertIn(name_for("2026-10-19"), plan["keep"])
        self.assertIn(name_for("2026-10-01"), plan["keep"])
        self.assertIn(name_for("2026-09-20"), plan["keep"])
        self.assertIn(name_for("2026-09-01"), plan["keep"])
        self.assertIn(name_for("2025-11-01"), plan["keep"])
        self.assertIn(name_for("2026-12-01"), plan["keep"])
        self.assertIn(name_for("2026-09-18"), plan["delete"])
        self.assertIn(name_for("2025-10-01"), plan["delete"])
        self.assertIn("muistiinpanot.txt", plan["ignore"])
        self.assertIn(name_for("2026-13-40"), plan["ignore"])
        self.assertNotIn(name_for("2026-13-40"), plan["delete"])

    def test_refuses_path(self):
        with self.assertRaises(BackupError):
            retention_plan(["../tapio-havuhattu_2020-01-01_0000.dump.tar.age"], TODAY)

    def test_refuses_to_drop_last_copy(self):
        with self.assertRaises(BackupError):
            retention_plan([name_for("2020-06-02")], TODAY, min_keep=1)

    def test_max_delete(self):
        names = [name_for(f"2020-06-{day:02d}") for day in range(2, 6)]
        with self.assertRaises(BackupError):
            retention_plan(names, TODAY, max_delete=2)

    def test_dry_run_and_apply_local(self):
        here = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            keep = name_for("2026-10-02")
            drop = name_for("2026-08-02")
            other = "lasku.pdf"
            for item in (keep, drop, other):
                (root / item).write_text("x", encoding="utf-8")
            dry = subprocess.run(
                ["python3", "retention.py", "--local-dir", tmp, "--today", "2026-10-19"],
                cwd=here,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(dry.returncode, 0, dry.stderr)
            self.assertTrue((root / drop).exists())
            self.assertIn("KUIVAHARJOITUS", dry.stdout)
            applied = subprocess.run(
                ["python3", "retention.py", "--local-dir", tmp, "--today", "2026-10-19", "--apply"],
                cwd=here,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(applied.returncode, 0, applied.stderr)
            self.assertFalse((root / drop).exists())
            self.assertTrue((root / keep).exists())
            self.assertTrue((root / other).exists())

    def test_rclone_deletefile_only(self):
        here = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            folder = "abcdefghijklmnop"
            drop = name_for("2024-03-02")
            keep = name_for("2026-10-02")
            (root / "files").mkdir()
            (root / "files" / drop).write_text("old", encoding="utf-8")
            (root / "files" / keep).write_text("new", encoding="utf-8")
            (root / "files" / "muu.txt").write_text("stay", encoding="utf-8")
            config = root / "rclone.conf"
            config.write_text(
                "[drive]\n"
                "type = drive\n"
                "scope = drive\n"
                'token = {"access_token":"x","refresh_token":"y"}\n'
                f"root_folder_id = {folder}\n",
                encoding="utf-8",
            )
            fake = root / "rclone"
            fake.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env python3
                    import os, sys
                    root = os.environ["FAKE_RCLONE_DIR"]
                    cmd = sys.argv[1]
                    if cmd == "lsf":
                        print("\\n".join(sorted(os.listdir(root))))
                        sys.exit(0)
                    if cmd == "deletefile":
                        target = sys.argv[2]
                        if ":" not in target or "/" in target.split(":", 1)[1]:
                            sys.exit(3)
                        name = target.split(":", 1)[1]
                        os.remove(os.path.join(root, name))
                        sys.exit(0)
                    if cmd in {"delete", "purge", "sync"}:
                        sys.exit(9)
                    sys.exit(8)
                    """
                ),
                encoding="utf-8",
            )
            fake.chmod(0o755)
            env = os.environ.copy()
            env["FAKE_RCLONE_DIR"] = str(root / "files")
            env["BACKUP_DRIVE_FOLDER_ID"] = folder
            proc = subprocess.run(
                [
                    "python3",
                    "retention.py",
                    "--config",
                    str(config),
                    "--remote",
                    "drive:",
                    "--rclone-bin",
                    str(fake),
                    "--today",
                    "2026-10-19",
                    "--apply",
                ],
                cwd=here,
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr + proc.stdout)
            self.assertFalse((root / "files" / drop).exists())
            self.assertTrue((root / "files" / keep).exists())
            self.assertTrue((root / "files" / "muu.txt").exists())

    def test_delete_local_rejects_foreign_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(BackupError):
                delete_local(tmp, "muistiinpanot.txt")


if __name__ == "__main__":
    unittest.main()
