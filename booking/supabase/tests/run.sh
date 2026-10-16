#!/usr/bin/env bash
# Ajaa migraatiot tyhjään testitietokantaan (mock-Supabase + mock-kb) ja kaikki SQL-testit (pgTAP) + kilpailutilannetestin.
# Käyttö:  PGHOST=127.0.0.1 PGPORT=54329 PGUSER=postgres ./run.sh
# Vaatii: PostgreSQL 15+ (suositus 17), postgresql-contrib (btree_gist) ja pgTAP.
set -euo pipefail
cd "$(dirname "$0")"
export PGHOST="${PGHOST:-127.0.0.1}" PGPORT="${PGPORT:-54329}" PGUSER="${PGUSER:-postgres}"
DB="${BOOKING_TEST_DB:-booking_test}"
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -d "$DB")

psql -X -q -d postgres -c "drop database if exists $DB with (force)" -c "create database $DB"
"${PSQL[@]}" -c "create schema if not exists extensions" -c "create extension if not exists pgtap with schema extensions" >/dev/null
"${PSQL[@]}" -f fixtures/00_mock_supabase.sql
"${PSQL[@]}" -f fixtures/kb_mock.sql
for f in ../migrations/*.sql; do
  echo "migraatio: $(basename "$f")"
  "${PSQL[@]}" -1 -f "$f"
done
"${PSQL[@]}" -f fixtures/10_test_helpers.sql

fail=0; total=0
for t in ./[0-9]*.test.sql; do
  echo "== $(basename "$t")"
  out=$(psql -X -A -t -d "$DB" -v ON_ERROR_STOP=0 -f "$t" 2>&1) || true
  echo "$out" | grep -E '^(ok|not ok|# |ERROR|psql:)' || true
  n=$(echo "$out" | grep -cE '^ok ' || true); total=$((total+n))
  if echo "$out" | grep -qE '^not ok|^ERROR|^psql:.*ERROR|Looks like you failed|Looks like you planned'; then fail=1; fi
done

echo "== kilpailutilannetesti (rinnakkaiset yhteydet)"
if ./race.sh; then echo "ok race"; else fail=1; fi

echo "Testejä läpi: $total (pgTAP) + kilpailutesti"
if [ "$fail" = 1 ]; then echo "TESTIT EPÄONNISTUIVAT"; exit 1; fi
echo "KAIKKI TESTIT OK"
