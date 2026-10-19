"""Tarkistaa kannan, dumpin ja rivimäärät. Yhteys tulee PG*-muuttujista, ei argumenteista."""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

from common import (
    KEY_TABLES,
    OPTIONAL_SCHEMAS,
    PRIVATE_STORAGE_BUCKETS,
    PUBLIC_STORAGE_BUCKETS,
    REQUIRED_SCHEMAS,
    BackupError,
    quote_ident,
    redact,
    schemas_in_toc,
    toc_entry_count,
)


def psql(sql: str) -> str:
    proc = subprocess.run(
        ["psql", "-X", "-v", "ON_ERROR_STOP=1", "-At", "-c", sql],
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise BackupError(redact(proc.stderr.strip() or proc.stdout.strip() or "psql epäonnistui"))
    return proc.stdout.strip()


def inspect_database() -> dict:
    user = psql("select current_user")
    version = psql("show server_version")
    visible = set(
        psql(
            "select n.nspname from pg_namespace n "
            "where n.nspname not like 'pg\\_%' and n.nspname <> 'information_schema' "
            "and has_schema_privilege(current_user, n.oid, 'USAGE') order by 1"
        ).splitlines()
    )
    visible.discard("")
    required_missing = [name for name in REQUIRED_SCHEMAS if name not in visible]
    optional_missing = [name for name in OPTIONAL_SCHEMAS if name not in visible]
    # Tyhjä public ei näy pg_dumpin TOC:issa. Muut tyhjät skeemat näkyvät SCHEMA-rivinä.
    public_has_objects = False
    if "public" in visible:
        public_has_objects = (
            psql(
                "select case when exists ("
                "select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace "
                "where n.nspname = 'public' and c.relkind in ('r','p','v','m','S','f')"
                ") or exists ("
                "select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace "
                "where n.nspname = 'public'"
                ") then 'yes' else 'no' end"
            )
            == "yes"
        )
    must_dump = [name for name in REQUIRED_SCHEMAS if name in visible and not (name == "public" and not public_has_objects)]
    must_dump += [name for name in OPTIONAL_SCHEMAS if name in visible]
    return {
        "current_user": user,
        "server_version": version,
        "visible_schemas": sorted(visible),
        "required_missing": required_missing,
        "optional_missing": optional_missing,
        "must_dump": must_dump,
        "using_postgres_role": user == "postgres" or user.startswith("postgres."),
    }


def relation_exists(schema: str, table: str) -> bool:
    sql = (
        "select to_regclass("
        + "'"
        + schema
        + "."
        + table
        + "'"
        + ") is not null"
    )
    # Tunnisteet on jo tarkistettu quote_ident-säännöllä ennen kutsua.
    quote_ident(schema)
    quote_ident(table)
    return psql(sql) == "t"


def count_rows(schema: str, table: str) -> int:
    qualified = f"{quote_ident(schema)}.{quote_ident(table)}"
    return int(psql(f"select count(*)::bigint from {qualified}"))


def row_counts() -> list[dict]:
    rows = []
    for schema, table, required in KEY_TABLES:
        present = relation_exists(schema, table)
        entry = {
            "schema": schema,
            "table": table,
            "required": required,
            "present": present,
            "rows": count_rows(schema, table) if present else None,
        }
        rows.append(entry)
        if required and not present:
            raise BackupError(f"pakollinen taulu puuttuu tai ei ole luettavissa: {schema}.{table}")
    return rows


def list_storage_objects() -> dict:
    """storage.objects backup_reader-yhteydellä. Epäonnistuminen ei kaada dumppia."""
    known = set(PUBLIC_STORAGE_BUCKETS) | set(PRIVATE_STORAGE_BUCKETS)
    private = set(PRIVATE_STORAGE_BUCKETS)
    empty = {"ok": False, "note": "", "objects": [], "other_buckets": []}
    try:
        exists = psql("select (to_regclass('storage.objects') is not null)::text")
    except BackupError as exc:
        empty["note"] = f"storage.objects-listaus epäonnistui: {exc}"
        return empty
    if exists != "true":
        empty["note"] = "storage.objects ei ole olemassa"
        return empty
    try:
        raw = psql(
            "select coalesce(json_agg(json_build_object('bucket', bucket_id, 'path', name) "
            "order by bucket_id, name), '[]'::json)::text "
            "from storage.objects "
            "where bucket_id is not null and name is not null "
            "and name <> '.emptyFolderPlaceholder'"
        )
    except BackupError as exc:
        empty["note"] = f"storage.objects-listaus epäonnistui: {exc}"
        return empty
    try:
        rows = json.loads(raw or "[]")
    except json.JSONDecodeError:
        empty["note"] = "storage.objects-listaus ei ollut jsonia"
        return empty
    objects = []
    other: set[str] = set()
    if not isinstance(rows, list):
        empty["note"] = "storage.objects-listaus ei ollut taulukko"
        return empty
    for row in rows:
        if not isinstance(row, dict):
            continue
        bucket = row.get("bucket")
        path = row.get("path")
        if not isinstance(bucket, str) or not isinstance(path, str):
            continue
        if bucket not in known:
            other.add(bucket)
            continue
        objects.append({"bucket": bucket, "path": path, "private": bucket in private})
    return {
        "ok": True,
        "note": "",
        "objects": objects,
        "other_buckets": sorted(other),
    }


def check_dump(path: str, min_bytes: int, required_schemas: list[str]) -> dict:
    if not os.path.isfile(path):
        raise BackupError(f"dumpia ei ole: {path}")
    size = os.path.getsize(path)
    if size < min_bytes:
        raise BackupError(f"dumpin koko {size} tavua on alle rajan {min_bytes}")
    proc = subprocess.run(
        ["pg_restore", "--list", path],
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise BackupError("pg_restore --list epäonnistui: " + redact(proc.stderr.strip()))
    schemas = schemas_in_toc(proc.stdout)
    missing = [name for name in required_schemas if name not in schemas]
    if missing:
        raise BackupError(
            "dumpista puuttuu skeema(t): "
            + ", ".join(missing)
            + ". Jos backup_reader ei näe auth- tai storage-skeemaa, "
            "SUPABASE_BACKUP_DB_URL voi väliaikaisesti käyttää postgres-roolin session pooleria. "
            "Katso docs/backup.md."
        )
    if "TABLE" not in proc.stdout and "TABLE DATA" not in proc.stdout:
        raise BackupError("pg_restore --list ei sisältänyt tauluja")
    return {
        "bytes": size,
        "schemas": sorted(schemas),
        "toc_entries": toc_entry_count(proc.stdout),
        "pg_restore_list_ok": True,
    }


def counts_for_manifest(manifest: dict) -> dict[str, int | None]:
    actual: dict[str, int | None] = {}
    for entry in manifest.get("row_counts", []):
        schema, table = entry["schema"], entry["table"]
        key = f"{schema}.{table}"
        if not entry.get("present"):
            actual[key] = None
            continue
        if not relation_exists(schema, table):
            actual[key] = None
            continue
        actual[key] = count_rows(schema, table)
    return actual


def compare(manifest: dict, actual: dict[str, int | None]) -> list[str]:
    errors = []
    for entry in manifest.get("row_counts", []):
        if not entry.get("present"):
            continue
        key = f"{entry['schema']}.{entry['table']}"
        expected = entry.get("rows")
        got = actual.get(key)
        if got is None:
            errors.append(f"{key} puuttuu palautetusta kannasta")
        elif int(got) != int(expected):
            errors.append(f"{key}: manifestissa {expected}, palautuksessa {got}")
    return errors


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("inspect", "counts", "check-dump", "collect", "compare", "storage-objects"))
    parser.add_argument("--out")
    parser.add_argument("--dump")
    parser.add_argument("--min-bytes", type=int, default=1)
    parser.add_argument("--required-schemas", default="")
    parser.add_argument("--manifest")
    parser.add_argument("--actual")
    args = parser.parse_args()
    try:
        if args.command == "inspect":
            payload = inspect_database()
            if payload["required_missing"]:
                raise BackupError(
                    "rooli ei näe skeemoja: "
                    + ", ".join(payload["required_missing"])
                    + ". Aja migraatio 20261019140000_ops_001_backup_reader ja aseta salasana, "
                    "tai aseta SUPABASE_BACKUP_DB_URL postgres-roolin session pooleriin. Katso docs/backup.md."
                )
        elif args.command == "counts":
            payload = row_counts()
        elif args.command == "check-dump":
            required = [part for part in args.required_schemas.split(",") if part]
            payload = check_dump(args.dump, args.min_bytes, required)
        elif args.command == "storage-objects":
            payload = list_storage_objects()
        elif args.command == "collect":
            manifest = json.loads(open(args.manifest, encoding="utf-8").read())
            payload = counts_for_manifest(manifest)
        else:
            manifest = json.loads(open(args.manifest, encoding="utf-8").read())
            actual = json.loads(open(args.actual, encoding="utf-8").read())
            errors = compare(manifest, actual)
            if errors:
                print("rivimäärät eivät täsmää:", file=sys.stderr)
                for item in errors:
                    print(f"- {item}", file=sys.stderr)
                sys.exit(1)
            print("rivimäärät täsmäävät manifestiin")
            return
        if not args.out:
            raise BackupError("--out puuttuu")
        with open(args.out, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
    except BackupError as exc:
        print(f"dbcheck: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
