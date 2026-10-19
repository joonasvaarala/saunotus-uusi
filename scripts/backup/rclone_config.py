"""Kirjoittaa rclone-konfiguraation vain annettuun polkuun. Ei tulosta tokenia."""
from __future__ import annotations

import json
import os
import stat
import sys

from common import FOLDER_ID_RE, BackupError


def build_config(token_raw: str, folder_id: str, scope: str) -> str:
    if scope not in {"drive", "drive.file"}:
        raise BackupError("RCLONE_DRIVE_SCOPE on drive tai drive.file")
    if not FOLDER_ID_RE.match(folder_id) or folder_id == "root":
        raise BackupError("BACKUP_DRIVE_FOLDER_ID puuttuu tai on virheellinen")
    try:
        token = json.loads(token_raw)
    except json.JSONDecodeError as exc:
        raise BackupError("RCLONE_DRIVE_TOKEN ei ole kelvollinen JSON") from exc
    if not isinstance(token, dict) or not (token.get("refresh_token") or token.get("access_token")):
        raise BackupError("RCLONE_DRIVE_TOKEN ei sisällä access_tokenia tai refresh_tokenia")
    compact = json.dumps(token, separators=(",", ":"))
    # Henkilökohtainen Gmail-tili. Shared Drivea ei ole, joten team_drive jätetään tyhjäksi.
    return (
        "[drive]\n"
        "type = drive\n"
        f"scope = {scope}\n"
        f"token = {compact}\n"
        f"root_folder_id = {folder_id}\n"
    )


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    try:
        text = build_config(
            os.environ.get("RCLONE_DRIVE_TOKEN", ""),
            os.environ.get("BACKUP_DRIVE_FOLDER_ID", ""),
            os.environ.get("RCLONE_DRIVE_SCOPE", "drive"),
        )
    except BackupError as exc:
        print(f"rclone: {exc}", file=sys.stderr)
        sys.exit(1)
    fd = os.open(args.out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.chmod(args.out, stat.S_IRUSR | stat.S_IWUSR)


if __name__ == "__main__":
    main()
