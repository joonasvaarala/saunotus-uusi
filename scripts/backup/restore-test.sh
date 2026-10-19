#!/usr/bin/env bash
# Palauttaa dumpin PAIKALLISEEN kantaan backup_restore_test ja vertaa rivimääriä.
# Kieltäytyy Supabase- ja tuotanto-osoitteista. Ei käytä SUPABASE_BACKUP_DB_URL:ää kohteena.
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
if [[ -x /usr/lib/postgresql/17/bin/pg_restore ]]; then
  export PATH="/usr/lib/postgresql/17/bin:${PATH}"
fi

die() { echo "palautustesti: $*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "puuttuu komento: $1"; }
require_cmd python3
require_cmd pg_restore
require_cmd psql

DUMP=""
MANIFEST=""
ARCHIVE=""
IDENTITY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dump) DUMP="$2"; shift 2 ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    --archive) ARCHIVE="$2"; shift 2 ;;
    --identity) IDENTITY="$2"; shift 2 ;;
    *) die "tuntematon argumentti: $1" ;;
  esac
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/tapio-restore.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

if [[ -n "$ARCHIVE" ]]; then
  [[ -n "$IDENTITY" ]] || die "--archive vaatii --identity (age-yksityinen avain). Sitä ei ole GitHubissa."
  require_cmd age
  require_cmd tar
  age -d -i "$IDENTITY" -o "$WORKDIR/archive.tar" "$ARCHIVE"
  mkdir -p "$WORKDIR/unpacked"
  tar -xf "$WORKDIR/archive.tar" -C "$WORKDIR/unpacked"
  DUMP="$WORKDIR/unpacked/database.dump"
  if [[ -z "$MANIFEST" ]]; then
    MANIFEST="$WORKDIR/unpacked/manifest.json"
  fi
fi

[[ -n "$DUMP" && -f "$DUMP" ]] || die "dump puuttuu"
[[ -n "$MANIFEST" && -f "$MANIFEST" ]] || die "manifest puuttuu"
[[ -n "${RESTORE_TARGET_URL:-}" ]] || die "RESTORE_TARGET_URL puuttuu"

python3 dburl.py --url-env RESTORE_TARGET_URL --purpose restore --out "$WORKDIR/pgenv"
set -a
# shellcheck disable=SC1091
. "$WORKDIR/pgenv"
set +a
rm -f "$WORKDIR/pgenv"
unset RESTORE_TARGET_URL

CURRENT="$(psql -X -v ON_ERROR_STOP=1 -At -c 'select current_database()')"
[[ "$CURRENT" == "postgres" ]] || die "yhteys ei ole ylläpitokannassa postgres (on $CURRENT)"

psql -X -v ON_ERROR_STOP=1 -c "drop database if exists backup_restore_test with (force)"
psql -X -v ON_ERROR_STOP=1 -c "create database backup_restore_test"
# Laajennukset, joita Supabase-dumpin alku usein tarvitsee. Puute ei kaada testiä tässä.
psql -X -d backup_restore_test -v ON_ERROR_STOP=0 -c "create schema if not exists extensions" >/dev/null
psql -X -d backup_restore_test -v ON_ERROR_STOP=0 -c "create extension if not exists pgcrypto with schema extensions" >/dev/null || true
psql -X -d backup_restore_test -v ON_ERROR_STOP=0 -c "create extension if not exists btree_gist with schema extensions" >/dev/null || true

export PGDATABASE=backup_restore_test
set +e
pg_restore --no-owner --no-acl --exit-on-error --dbname=backup_restore_test "$DUMP" >"$WORKDIR/restore.err" 2>&1
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  echo "palautustesti: pg_restore --exit-on-error epäonnistui, yritetään ilman sitä (vanilla postgres:17 ei ole Supabase)" >&2
  psql -X -d postgres -v ON_ERROR_STOP=1 -c "drop database if exists backup_restore_test with (force)"
  psql -X -d postgres -v ON_ERROR_STOP=1 -c "create database backup_restore_test"
  set +e
  pg_restore --no-owner --no-acl --disable-triggers --dbname=backup_restore_test "$DUMP" >"$WORKDIR/restore.err" 2>&1
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "palautustesti: pg_restore palautti koodin $rc. Rivimääriä verrataan silti." >&2
  fi
fi

export PGDATABASE=backup_restore_test
python3 dbcheck.py collect --manifest "$MANIFEST" --out "$WORKDIR/actual.json"
python3 dbcheck.py compare --manifest "$MANIFEST" --actual "$WORKDIR/actual.json"
echo "palautustesti valmis tietokannassa backup_restore_test"
