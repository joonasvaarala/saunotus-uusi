#!/usr/bin/env bash
# Luo paikallisen demotietokannan: mock-Supabase (roolit, auth) + kb (oikea kb-data ilman asiakkaita) + migraatiot + demo-siemen.
# Vaatii paikallisen PostgreSQL 15+ (btree_gist) ja pgTAP-vapaan ympäristön (pgTAP ei tarvita demoon).
set -euo pipefail
cd "$(dirname "$0")/.."
export PGHOST="${PGHOST:-127.0.0.1}" PGPORT="${PGPORT:-54329}" PGUSER="${PGUSER:-postgres}"
DB="${DEMO_DB:-booking_demo}"
P=(psql -X -q -v ON_ERROR_STOP=1 -d "$DB")
psql -X -q -d postgres -c "drop database if exists $DB with (force)" -c "create database $DB"
"${P[@]}" -f supabase/tests/fixtures/00_mock_supabase.sql
"${P[@]}" -f supabase/tests/fixtures/kb_mock.sql
"${P[@]}" -f supabase/tests/fixtures/public_mock.sql
for f in supabase/migrations/*.sql; do "${P[@]}" -1 -f "$f" >/dev/null; done
"${P[@]}" -f dev/seed_demo.sql
echo "demotietokanta $DB valmis"
