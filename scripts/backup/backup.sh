#!/usr/bin/env bash
# Tapio-havuhattu: pg_dump + storage + age (+ rclone). Ei tulosta salaisuuksia.
# Katso docs/backup.md.
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

if [[ -x /usr/lib/postgresql/17/bin/pg_dump ]]; then
  export PATH="/usr/lib/postgresql/17/bin:${PATH}"
fi

die() { echo "varmuuskopio: $*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "puuttuu komento: $1"; }

MODE="backup"
if [[ "${1:-}" == "--retention-dry-run" ]]; then
  MODE="retention-dry-run"
elif [[ -n "${1:-}" ]]; then
  die "tuntematon argumentti: $1"
fi

require_cmd python3
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/tapio-backup.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

if [[ "$MODE" == "retention-dry-run" ]]; then
  require_cmd rclone
  python3 rclone_config.py --out "$WORKDIR/rclone.conf"
  python3 retention.py --config "$WORKDIR/rclone.conf" --remote "drive:"
  exit 0
fi

require_cmd pg_dump
require_cmd pg_restore
require_cmd psql
require_cmd age
require_cmd tar
MAJOR="$(pg_dump --version | awk '{print $3}' | cut -d. -f1)"
[[ "$MAJOR" == "17" ]] || die "pg_dumpin pääversion on oltava 17, nyt: $(pg_dump --version)"

[[ -n "${SUPABASE_BACKUP_DB_URL:-}" ]] || die "SUPABASE_BACKUP_DB_URL puuttuu"
[[ -n "${BACKUP_AGE_PUBLIC_KEY:-}" ]] || die "BACKUP_AGE_PUBLIC_KEY puuttuu"
python3 -c 'import os,sys; from common import AGE_PUBLIC_RE; key=os.environ["BACKUP_AGE_PUBLIC_KEY"].strip(); sys.exit(0 if AGE_PUBLIC_RE.match(key) else 1)' \
  || die "BACKUP_AGE_PUBLIC_KEY ei ole age-julkinen avain (age1...)"

MIN_BYTES="${BACKUP_MIN_DUMP_BYTES:-1048576}"
SKIP_UPLOAD="${BACKUP_SKIP_UPLOAD:-0}"
SKIP_STORAGE="${BACKUP_SKIP_STORAGE:-0}"
STAMP="$(date -u +%Y-%m-%d_%H%M)"
BASENAME="tapio-havuhattu_${STAMP}.dump.tar.age"

python3 dburl.py --url-env SUPABASE_BACKUP_DB_URL --purpose backup --out "$WORKDIR/pgenv"
set -a
# shellcheck disable=SC1091
. "$WORKDIR/pgenv"
set +a
rm -f "$WORKDIR/pgenv"
unset SUPABASE_BACKUP_DB_URL

PAYLOAD="$WORKDIR/payload"
mkdir -p "$PAYLOAD/storage"

python3 dbcheck.py inspect --out "$WORKDIR/inspect.json"
python3 dbcheck.py counts --out "$WORKDIR/counts.json"

EXCLUDE=()
if [[ -n "${BACKUP_EXCLUDE_SCHEMAS:-}" ]]; then
  python3 - <<'PY' || die "BACKUP_EXCLUDE_SCHEMAS sisältää pakollisen skeeman"
import os, sys
from common import REQUIRED_SCHEMAS
banned = set(REQUIRED_SCHEMAS)
for name in os.environ["BACKUP_EXCLUDE_SCHEMAS"].split(","):
    name = name.strip()
    if not name:
        continue
    if name in banned:
        print(f"skeemaa {name} ei saa jättää pois", file=sys.stderr)
        sys.exit(1)
PY
  IFS=',' read -r -a _schemas <<< "${BACKUP_EXCLUDE_SCHEMAS}"
  for schema in "${_schemas[@]}"; do
    schema="$(echo "$schema" | tr -d '[:space:]')"
    [[ -n "$schema" ]] && EXCLUDE+=(--exclude-schema="$schema")
  done
fi

DUMP="$PAYLOAD/database.dump"
set +e
pg_dump --format=custom --no-password --quote-all-identifiers --verbose \
  --file="$DUMP" "${EXCLUDE[@]}" >"$WORKDIR/dump.err" 2>&1
rc=$?
set -e
LO_EXCLUDED=false
if [[ $rc -ne 0 ]]; then
  if grep -q -i "large object" "$WORKDIR/dump.err"; then
    echo "varmuuskopio: large object -oikeus puuttuu, yritetään ilman niitä" >&2
    set +e
    pg_dump --format=custom --no-password --quote-all-identifiers --no-large-objects --verbose \
      --file="$DUMP" "${EXCLUDE[@]}" >"$WORKDIR/dump.err" 2>&1
    rc=$?
    set -e
    LO_EXCLUDED=true
  fi
fi
if [[ $rc -ne 0 ]]; then
  python3 -c 'import pathlib,sys; from common import redact; print(redact(pathlib.Path(sys.argv[1]).read_text(errors="replace")[-4000:]))' "$WORKDIR/dump.err" >&2
  die "pg_dump epäonnistui"
fi
python3 -c 'import pathlib,sys; from common import redact; pathlib.Path(sys.argv[2]).write_text(redact(pathlib.Path(sys.argv[1]).read_text(errors="replace")))' \
  "$WORKDIR/dump.err" "$PAYLOAD/dump.log"

REQ="$(python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1], encoding="utf-8"))["must_dump"]))' "$WORKDIR/inspect.json")"
python3 dbcheck.py check-dump --dump "$DUMP" --min-bytes "$MIN_BYTES" --required-schemas "$REQ" --out "$WORKDIR/dump-info.json"
python3 - <<PY
import json
info = json.load(open("$WORKDIR/dump-info.json", encoding="utf-8"))
info["large_objects"] = "excluded" if "$LO_EXCLUDED" == "true" else "included"
json.dump(info, open("$WORKDIR/dump-info.json", "w", encoding="utf-8"), indent=2)
open("$WORKDIR/dump-info.json", "a", encoding="utf-8").write("\n")
PY

ROLES_OK=false
set +e
pg_dumpall --roles-only --no-role-passwords --no-password --file="$PAYLOAD/roles.sql" >"$WORKDIR/roles.err" 2>&1
roles_rc=$?
set -e
if [[ $roles_rc -eq 0 ]]; then
  ROLES_OK=true
  ROLES_METHOD="pg_dumpall"
  ROLES_NOTE="pg_dumpall --roles-only --no-role-passwords onnistui. Salasanoja ei ole mukana."
else
  python3 roles_fallback.py --out "$PAYLOAD/roles.sql"
  ROLES_METHOD="catalog-query"
  ROLES_NOTE="pg_dumpall --roles-only epäonnistui (Supabasessa postgres ei ole superuser eikä voi lukea pg_authid). roles.sql on luettelo ilman salasanoja, ei ajettava skripti."
fi
python3 -c 'import pathlib,sys; from common import redact; print(redact(pathlib.Path(sys.argv[1]).read_text(errors="replace")[-2000:]))' "$WORKDIR/roles.err" >"$WORKDIR/roles.redacted" || true
python3 - <<PY
import json
json.dump({
  "ok": "$ROLES_OK" == "true",
  "method": "$ROLES_METHOD",
  "note": "$ROLES_NOTE",
}, open("$WORKDIR/roles.json", "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY

if [[ "$SKIP_STORAGE" == "1" ]]; then
  python3 - <<PY
import json
json.dump({"method": "skipped", "file_count": 0, "bytes": 0, "buckets": [], "files": [], "private_missing": [], "notes": []}, open("$PAYLOAD/storage/manifest.json", "w"))
PY
else
  python3 dbcheck.py storage-objects --out "$WORKDIR/storage-objects.json"
fi
unset PGPASSWORD PGHOST PGPORT PGUSER PGDATABASE PGSSLMODE || true
if [[ "$SKIP_STORAGE" != "1" ]]; then
  python3 storage_download.py --dest "$PAYLOAD/storage" --objects "$WORKDIR/storage-objects.json"
fi

python3 build_manifest.py \
  --inspect "$WORKDIR/inspect.json" \
  --counts "$WORKDIR/counts.json" \
  --dump-info "$WORKDIR/dump-info.json" \
  --roles "$WORKDIR/roles.json" \
  --storage "$PAYLOAD/storage/manifest.json" \
  --filename "$BASENAME" \
  --out "$PAYLOAD/manifest.json"

TAR="$WORKDIR/archive.tar"
tar -C "$PAYLOAD" -cf "$TAR" .
printf '%s\n' "$BACKUP_AGE_PUBLIC_KEY" > "$WORKDIR/recipients.txt"
AGE_FILE="$WORKDIR/$BASENAME"
age -R "$WORKDIR/recipients.txt" -o "$AGE_FILE" "$TAR"
rm -f "$TAR" "$WORKDIR/recipients.txt"
# age-tiedoston otsikko, ei avainta.
header="$(head -c 20 "$AGE_FILE" || true)"
[[ "$header" == age-encryption.org* ]] || die "age-salaus ei tuottanut age-tiedostoa"

if [[ -n "${BACKUP_OUTPUT_DIR:-}" ]]; then
  mkdir -p "$BACKUP_OUTPUT_DIR"
  cp -p "$AGE_FILE" "$BACKUP_OUTPUT_DIR/$BASENAME"
fi

if [[ "$SKIP_UPLOAD" != "1" ]]; then
  require_cmd rclone
  python3 rclone_config.py --out "$WORKDIR/rclone.conf"
  rclone lsf "drive:" --files-only --max-depth 1 --config "$WORKDIR/rclone.conf" >"$WORKDIR/remote-before.txt"
  if grep -Fxq "$BASENAME" "$WORKDIR/remote-before.txt"; then
    die "kohteessa on jo $BASENAME. Uutta ajoa ei ylikirjoiteta."
  fi
  rclone copyto "$AGE_FILE" "drive:$BASENAME" --config "$WORKDIR/rclone.conf" --retries 5 --low-level-retries 10
  rclone lsf "drive:" --files-only --max-depth 1 --config "$WORKDIR/rclone.conf" >"$WORKDIR/remote-after.txt"
  grep -Fxq "$BASENAME" "$WORKDIR/remote-after.txt" || die "lähetys ei näy Drive-kansiossa"
  python3 retention.py --config "$WORKDIR/rclone.conf" --remote "drive:" --apply
fi

if [[ "${RUN_RESTORE_TEST:-0}" == "1" ]]; then
  [[ -n "${RESTORE_TARGET_URL:-}" ]] || die "RUN_RESTORE_TEST=1 mutta RESTORE_TARGET_URL puuttuu"
  ./restore-test.sh --dump "$DUMP" --manifest "$PAYLOAD/manifest.json"
fi

echo "varmuuskopio valmis: $BASENAME"
