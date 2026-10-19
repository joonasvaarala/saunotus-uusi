"""Säilytys vain backup-kansion kuvion mukaisille tiedostoille.

Oletus on kuivaharjoitus. Poisto tapahtuu vain --apply-lipulla, yksi tiedosto kerrallaan,
komennolla rclone deletefile. rclone delete- tai purge-komentoja ei käytetä.
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from datetime import datetime

from common import FOLDER_ID_RE, BackupError, filename_date, retention_plan, utc_today


def read_folder_id(config_path: str) -> str:
    folder = ""
    with open(config_path, encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("root_folder_id"):
                _, value = line.split("=", 1)
                folder = value.strip()
            if line.lower().startswith("token"):
                # Tokenia ei lueta muistiin pidempään kuin tarkistukseen, eikä sitä tulosteta.
                if not value_present(line):
                    raise BackupError("rclone-konfiguraatiosta puuttuu token")
    if not FOLDER_ID_RE.match(folder) or folder == "root":
        raise BackupError("rclone-konfiguraation root_folder_id puuttuu tai on virheellinen")
    expected = os.environ.get("BACKUP_DRIVE_FOLDER_ID", "")
    if expected and folder != expected:
        raise BackupError("root_folder_id ei täsmää BACKUP_DRIVE_FOLDER_ID-arvoon")
    return folder


def value_present(line: str) -> bool:
    _, value = line.split("=", 1)
    return bool(value.strip())


def list_local(directory: str) -> list[str]:
    return sorted(os.listdir(directory))


def list_rclone(config: str, remote: str, rclone_bin: str) -> list[str]:
    read_folder_id(config)
    # drive: on backup-kansio, kun konfiguraatiossa on root_folder_id (tarkistetaan yllä).
    if remote.strip() in {"", "/"} or ".." in remote or remote.strip().endswith("/"):
        raise BackupError("rclone-kohde on tyhjä, juuri tai alikansio")
    proc = subprocess.run(
        [rclone_bin, "lsf", remote, "--files-only", "--max-depth", "1", "--config", config],
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        print("rclone lsf epäonnistui. Mitään ei poistettu.", file=sys.stderr)
        sys.exit(1)
    names = []
    for line in proc.stdout.splitlines():
        if line:
            names.append(line)
    return names


def delete_local(directory: str, name: str) -> None:
    if filename_date(name) is None:
        raise BackupError(f"paikallinen poisto estetty: {name}")
    root = os.path.realpath(directory)
    path = os.path.realpath(os.path.join(root, name))
    if os.path.dirname(path) != root:
        raise BackupError("paikallinen poisto karkasi kansiosta")
    if not os.path.isfile(path):
        raise BackupError(f"poistettava ei ole tiedosto: {name}")
    os.remove(path)


def delete_rclone(config: str, remote: str, name: str, rclone_bin: str) -> None:
    if filename_date(name) is None:
        raise BackupError(f"rclone-poisto estetty: {name}")
    read_folder_id(config)
    target = remote + name if remote.endswith(":") else remote.rstrip("/") + "/" + name
    proc = subprocess.run(
        [rclone_bin, "deletefile", target, "--config", config],
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        print(f"rclone deletefile epäonnistui tiedostolle {name}", file=sys.stderr)
        sys.exit(1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--local-dir")
    parser.add_argument("--config")
    parser.add_argument("--remote", default="drive:")
    parser.add_argument("--rclone-bin", default=os.environ.get("RCLONE_BIN", "rclone"))
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--today", help="YYYY-MM-DD, oletus UTC-tänään")
    parser.add_argument("--daily-days", type=int, default=int(os.environ.get("BACKUP_RETAIN_DAYS", "30")))
    parser.add_argument("--monthly-months", type=int, default=int(os.environ.get("BACKUP_RETAIN_MONTHS", "12")))
    parser.add_argument("--min-keep", type=int, default=int(os.environ.get("BACKUP_RETAIN_MIN_KEEP", "1")))
    parser.add_argument("--max-delete", type=int, default=int(os.environ.get("BACKUP_RETENTION_MAX_DELETE", "400")))
    args = parser.parse_args()
    if bool(args.local_dir) == bool(args.config):
        print("anna joko --local-dir tai --config", file=sys.stderr)
        sys.exit(1)
    today = utc_today() if not args.today else datetime.strptime(args.today, "%Y-%m-%d").date()
    try:
        names = list_local(args.local_dir) if args.local_dir else list_rclone(args.config, args.remote, args.rclone_bin)
        plan = retention_plan(
            names,
            today,
            daily_days=args.daily_days,
            monthly_months=args.monthly_months,
            min_keep=args.min_keep,
            max_delete=args.max_delete,
        )
    except BackupError as exc:
        print(f"säilytys: {exc}", file=sys.stderr)
        sys.exit(1)
    mode = "POISTO" if args.apply else "KUIVAHARJOITUS"
    print(f"säilytys {mode} päivältä {today.isoformat()}")
    for name in plan["keep"]:
        print(f"  PIDÄ    {name}")
    for name in plan["ignore"]:
        print(f"  OHITA   {name}")
    for name in plan["delete"]:
        print(f"  POISTA  {name}")
    if not args.apply:
        print("kuivaharjoitus: tiedostoja ei poistettu")
        return
    for name in plan["delete"]:
        try:
            if args.local_dir:
                delete_local(args.local_dir, name)
            else:
                delete_rclone(args.config, args.remote, name, args.rclone_bin)
        except BackupError as exc:
            print(f"säilytys keskeytettiin: {exc}", file=sys.stderr)
            sys.exit(1)
        print(f"poistettu {name}")
    print(f"poistettu {len(plan['delete'])} tiedostoa, jätetty {len(plan['keep'])}")


if __name__ == "__main__":
    main()
