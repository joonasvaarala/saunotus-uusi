"""Pilkkoo Postgres-URI:n ympäristötiedostoksi. Ei tulosta salasanaa eikä koko osoitetta."""
from __future__ import annotations

import argparse
import os
import stat
import sys
from urllib.parse import parse_qs, unquote, urlparse

from common import PROJECT_REF, BackupError


def sh_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def parse_database_url(url: str, purpose: str) -> dict[str, str]:
    if not url or not url.strip():
        raise BackupError(f"{purpose}: tietokantaosoite puuttuu")
    if any(ch in url for ch in "\n\r\x00"):
        raise BackupError(f"{purpose}: osoitteessa on kielletty merkki")
    parsed = urlparse(url.strip())
    if parsed.scheme not in {"postgresql", "postgres"}:
        raise BackupError(f"{purpose}: skeeman on oltava postgresql://")
    host = parsed.hostname or ""
    if not host:
        raise BackupError(f"{purpose}: kone puuttuu")
    port = parsed.port or 5432
    user = unquote(parsed.username or "")
    password = unquote(parsed.password or "")
    database = unquote((parsed.path or "/postgres").lstrip("/")) or "postgres"
    if not user or not password or not database:
        raise BackupError(f"{purpose}: käyttäjä, salasana tai kanta puuttuu")
    query = parse_qs(parsed.query, keep_blank_values=False)
    sslmode = (query.get("sslmode") or [None])[0]
    local = host.lower() in {"localhost", "127.0.0.1", "::1"}
    if purpose == "backup":
        if port == 6543:
            raise BackupError(
                "portti 6543 on Supabasen transaktiopooleri. pg_dump tarvitsee session poolerin "
                "tai suoran yhteyden, molemmat portissa 5432."
            )
        if sslmode is None:
            sslmode = "disable" if local else "require"
    elif purpose == "restore":
        from common import check_restore_target

        check_restore_target(url.strip(), os.environ.get("SUPABASE_BACKUP_DB_URL"))
        if sslmode is None:
            sslmode = "disable"
    else:
        raise BackupError(f"tuntematon tarkoitus: {purpose}")
    if purpose == "backup" and PROJECT_REF not in url and not local:
        # Paikallinen testi ei käytä projektiviitettä. Tuotanto-osoitteessa sen kuuluu olla.
        pass
    values = {
        "PGHOST": host,
        "PGPORT": str(port),
        "PGUSER": user,
        "PGPASSWORD": password,
        "PGDATABASE": database,
        "PGSSLMODE": sslmode,
        "PGCONNECT_TIMEOUT": "30",
        "PGAPPNAME": "tapio-havuhattu-backup" if purpose == "backup" else "tapio-havuhattu-restore-test",
    }
    return values


def write_env_file(path: str, values: dict[str, str]) -> None:
    lines = [f"{key}={sh_quote(value)}" for key, value in values.items()]
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    fd = os.open(path, flags, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)


def main() -> None:
    parser = argparse.ArgumentParser(description="Kirjoita PG*-ympäristö osoitteesta")
    parser.add_argument("--url-env", required=True, help="Ympäristömuuttuja, jossa URI on")
    parser.add_argument("--purpose", choices=("backup", "restore"), required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    try:
        values = parse_database_url(os.environ.get(args.url_env, ""), args.purpose)
        write_env_file(args.out, values)
    except BackupError as exc:
        print(f"dburl: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
