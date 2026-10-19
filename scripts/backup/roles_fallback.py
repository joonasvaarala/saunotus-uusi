"""Kirjaa roolien nimet ja attribuutit ilman salasanoja.

pg_dumpall --roles-only vaatii Supabasessa superuserin (pg_authid). postgres-rooli ei ole
superuser, joten komento epäonnistuu. Tämä tiedosto on luettelo, ei palautettava skripti.
"""
from __future__ import annotations

import argparse
import subprocess
import sys

from common import BackupError, redact


def psql_tuples(sql: str) -> list[list[str]]:
    proc = subprocess.run(
        ["psql", "-X", "-v", "ON_ERROR_STOP=1", "-At", "-F", "\t", "-c", sql],
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise BackupError(redact(proc.stderr.strip() or "psql epäonnistui"))
    rows = []
    for line in proc.stdout.splitlines():
        if line:
            rows.append(line.split("\t"))
    return rows


def flag(value: str, on: str, off: str) -> str:
    return on if value == "t" else off


def build_sql() -> str:
    roles = psql_tuples(
        """
        select rolname, rolcanlogin, rolsuper, rolinherit, rolcreaterole, rolcreatedb,
               rolreplication, rolbypassrls, rolconnlimit::text
          from pg_roles
         where rolname not like 'pg\\_%'
         order by rolname
        """
    )
    members = psql_tuples(
        """
        select member.rolname, granted.rolname
          from pg_auth_members m
          join pg_roles granted on granted.oid = m.roleid
          join pg_roles member on member.oid = m.member
         order by 1, 2
        """
    )
    lines = [
        "-- Rooliluettelo ilman salasanoja.",
        "-- pg_dumpall --roles-only ei onnistu Supabasessa ilman superuseria.",
        "-- ÄLÄ aja tätä tiedostoa sellaisenaan. Se ei palauta salasanoja eikä oikeuksia objekteihin.",
        "-- Oikeudet objekteihin ovat database.dump-tiedostossa.",
        "",
    ]
    for rolname, login, superuser, inherit, createrole, createdb, replication, bypass, limit in roles:
        parts = [
            flag(login, "LOGIN", "NOLOGIN"),
            flag(superuser, "SUPERUSER", "NOSUPERUSER"),
            flag(inherit, "INHERIT", "NOINHERIT"),
            flag(createrole, "CREATEROLE", "NOCREATEROLE"),
            flag(createdb, "CREATEDB", "NOCREATEDB"),
            flag(replication, "REPLICATION", "NOREPLICATION"),
            flag(bypass, "BYPASSRLS", "NOBYPASSRLS"),
            f"CONNECTION LIMIT {int(limit)}",
        ]
        lines.append(f"-- {rolname}: {' '.join(parts)}")
    lines.append("")
    lines.append("-- Jäsenyydet (jäsen -> rooli), ilman grant-optiota:")
    for member, granted in members:
        lines.append(f"-- GRANT {granted} TO {member};")
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    try:
        sql = build_sql()
    except BackupError as exc:
        print(f"roles_fallback: {exc}", file=sys.stderr)
        sys.exit(1)
    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write(sql)


if __name__ == "__main__":
    main()
