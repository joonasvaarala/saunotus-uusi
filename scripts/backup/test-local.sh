#!/usr/bin/env bash
# Paikallinen koe: Postgres 17 -kontti, migraatio psql -1:llä, dumppi, age, palautustesti.
# Ei tuotantoa eikä verkkoa Supabaseen. Kontin salasana on vain tätä koetta varten.
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PORT="${BACKUP_TEST_PORT:-54329}"
NAME="tapio-backup-pg"
DOCKER=(docker)
if ! docker info >/dev/null 2>&1; then
  DOCKER=(sudo docker)
fi

cleanup() {
  "${DOCKER[@]}" rm -f "$NAME" >/dev/null 2>&1 || true
  if [[ -n "${MOCK_PID:-}" ]]; then
    kill "$MOCK_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "${WORKDIR:-}"
}
trap cleanup EXIT

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/tapio-backup-test.XXXXXX")"
"${DOCKER[@]}" rm -f "$NAME" >/dev/null 2>&1 || true
"${DOCKER[@]}" run -d --name "$NAME" \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_HOST_AUTH_METHOD=scram-sha-256 \
  -p "${PORT}:5432" postgres:17 >/dev/null

ready=0
for _ in $(seq 1 40); do
  if "${DOCKER[@]}" exec "$NAME" pg_isready -U postgres >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" == "1" ]]

export PGHOST=127.0.0.1 PGPORT="$PORT" PGUSER=postgres PGPASSWORD=postgres PGDATABASE=postgres PGSSLMODE=disable

echo "== skeemat ja RLS-taulu =="
psql -X -v ON_ERROR_STOP=1 <<'SQL'
create schema if not exists kb;
create schema if not exists booking;
create schema if not exists auth;
create schema if not exists storage;
create schema if not exists supabase_migrations;
create schema if not exists cron;
create or replace function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb)
$$;
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
end $$;
create table storage.buckets (id text primary key, name text, public boolean);
create table storage.objects (
  id int generated always as identity primary key,
  bucket_id text,
  name text
);
alter table storage.objects enable row level security;
grant usage on schema storage to authenticated;
grant select, insert, update, delete on storage.objects to authenticated;
insert into storage.buckets values
  ('article-images', 'article-images', true),
  ('receipts', 'receipts', false),
  ('invoices', 'invoices', false),
  ('logos', 'logos', false);
insert into storage.objects (bucket_id, name) values
  ('article-images', 'a.txt'),
  ('receipts', 'r.pdf'),
  ('logos', 'skip.txt');
create table booking.orders (id int primary key, note text);
alter table booking.orders enable row level security;
insert into booking.orders values (1, 'salaisuus');
create table booking.payments (id int);
insert into booking.payments values (1);
create table booking.gift_cards (id int);
insert into booking.gift_cards values (1), (2);
create table booking.reservations (id int);
insert into booking.reservations values (1);
create table kb.products (id int);
alter table kb.products enable row level security;
insert into kb.products values (1), (2), (3);
grant usage on schema booking, kb to authenticated;
grant select on booking.orders, kb.products to authenticated;
create table public.marker (id int);
insert into public.marker values (1);
SQL

echo "== migraatio psql -1 =="
psql -X -v ON_ERROR_STOP=1 -1 -f "$ROOT/booking/supabase/migrations/20261019140000_ops_001_backup_reader.sql"
STATE="$(psql -X -v ON_ERROR_STOP=1 -At -c "select rolcanlogin::text || ' ' || rolbypassrls::text || ' ' || rolsuper::text || ' ' || (rolpassword is null)::text from pg_authid where rolname = 'backup_reader'")"
# login, bypassrls, ei superuser, ei salasanaa (::text tulostaa true/false)
[[ "$STATE" == "true true false true" ]]

echo "== salasana vain tähän konttiin =="
psql -X -v ON_ERROR_STOP=1 -c "alter role backup_reader password 'backup_test_only'"
psql -X -v ON_ERROR_STOP=1 -c "create table booking.after_migration (id int); insert into booking.after_migration values (9);"

PGPASSWORD=backup_test_only psql -X -v ON_ERROR_STOP=1 -U backup_reader -At -c "select count(*) from booking.orders" | grep -qx 1
if PGPASSWORD=backup_test_only psql -X -v ON_ERROR_STOP=1 -U backup_reader -c "insert into booking.orders values (2, 'ei')" >/dev/null 2>&1; then
  echo "backup_reader pystyi kirjoittamaan" >&2
  exit 1
fi
PGPASSWORD=backup_test_only psql -X -v ON_ERROR_STOP=1 -U backup_reader -At -c "select count(*) from booking.after_migration" | grep -qx 1

echo "== ops_002 storage-politiikka =="
psql -X -v ON_ERROR_STOP=1 -1 -f "$ROOT/booking/supabase/migrations/20261019140100_ops_002_backup_storage_read.sql"
SEEN="$(psql -X -v ON_ERROR_STOP=1 -At <<'SQL' | tail -n 1
begin;
do $$ begin perform set_config('request.jwt.claims', '{"app_metadata":{"backup_role":"storage_reader"}}', true); end $$;
set role authenticated;
select string_agg(bucket_id || '/' || name, ',' order by bucket_id, name) from storage.objects;
SQL
)"
[[ "$SEEN" == "receipts/r.pdf" ]] || { echo "storage-luku näytti: [$SEEN]" >&2; exit 1; }
NONE="$(psql -X -v ON_ERROR_STOP=1 -At <<'SQL' | tail -n 1
begin;
do $$ begin perform set_config('request.jwt.claims', '{"app_metadata":{}}', true); end $$;
set role authenticated;
select count(*) from storage.objects;
SQL
)"
[[ "$NONE" == "0" ]] || { echo "ilman roolia näkyi: [$NONE]" >&2; exit 1; }
ORDERS="$(psql -X -v ON_ERROR_STOP=1 -At <<'SQL' | tail -n 1
begin;
do $$ begin perform set_config('request.jwt.claims', '{"app_metadata":{"backup_role":"storage_reader"}}', true); end $$;
set role authenticated;
select count(*) from booking.orders;
SQL
)"
[[ "$ORDERS" == "0" ]] || { echo "tilauksia näkyi: [$ORDERS]" >&2; exit 1; }
if psql -X -v ON_ERROR_STOP=1 <<'SQL'
begin;
do $$ begin perform set_config('request.jwt.claims', '{"app_metadata":{"backup_role":"storage_reader"}}', true); end $$;
set role authenticated;
insert into storage.objects (bucket_id, name) values ('receipts', 'ei.pdf');
rollback;
SQL
then
  echo "storage-lukija pystyi kirjoittamaan" >&2
  exit 1
fi

echo "== vale-storage =="
cat > "$WORKDIR/mock.py" <<'PY'
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return
    def _json(self, payload):
        raw = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
    def do_GET(self):
        if self.path == "/storage/v1/object/authenticated/receipts/r.pdf":
            if self.headers.get("Authorization") != "Bearer user-token" or self.headers.get("apikey") != "test-anon":
                self.send_response(401); self.end_headers(); return
            blob = b"hello-receipt"
            self.send_response(200)
            self.send_header("Content-Length", str(len(blob)))
            self.end_headers()
            self.wfile.write(blob)
            return
        if self.headers.get("Authorization"):
            self.send_response(400); self.end_headers(); return
        if self.path == "/storage/v1/object/public/article-images/a.txt":
            blob = b"hello-storage"
            self.send_response(200)
            self.send_header("Content-Length", str(len(blob)))
            self.end_headers()
            self.wfile.write(blob)
            return
        self.send_response(404); self.end_headers()
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n).decode() or "{}")
        if self.path != "/auth/v1/token?grant_type=password":
            self.send_response(404); self.end_headers(); return
        if self.headers.get("Authorization"):
            self.send_response(401); self.end_headers(); return
        if body.get("email") == "backup@saunotus.fi" and body.get("password") == "storage-test-only" and self.headers.get("apikey") == "test-anon":
            self._json({"access_token": "user-token"})
            return
        self.send_response(400); self.end_headers()
ThreadingHTTPServer(("127.0.0.1", 8765), H).serve_forever()
PY
python3 "$WORKDIR/mock.py" &
MOCK_PID=$!
sleep 0.3

echo "== age-avain vain testiin =="
age-keygen -o "$WORKDIR/identity.txt" >/dev/null
PUB="$(awk '/public key:/ {print $NF}' "$WORKDIR/identity.txt")"
[[ "$PUB" == age1* ]]

echo "== varmuuskopio =="
OUT="$WORKDIR/out"
mkdir -p "$OUT"
(
  cd "$HERE"
  SUPABASE_BACKUP_DB_URL="postgresql://backup_reader:backup_test_only@127.0.0.1:${PORT}/postgres?sslmode=disable" \
  BACKUP_AGE_PUBLIC_KEY="$PUB" \
  SUPABASE_URL="http://127.0.0.1:8765" \
  SUPABASE_ANON_KEY="test-anon" \
  BACKUP_STORAGE_EMAIL="backup@saunotus.fi" \
  BACKUP_STORAGE_PASSWORD="storage-test-only" \
  BACKUP_MIN_DUMP_BYTES=100 \
  BACKUP_SKIP_UPLOAD=1 \
  BACKUP_OUTPUT_DIR="$OUT" \
  RUN_RESTORE_TEST=1 \
  RESTORE_TARGET_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres?sslmode=disable" \
  bash ./backup.sh
)

AGE_FILE="$(find "$OUT" -name 'tapio-havuhattu_*.dump.tar.age' -print -quit)"
[[ -n "$AGE_FILE" ]]
age -d -i "$WORKDIR/identity.txt" -o "$WORKDIR/archive.tar" "$AGE_FILE"
mkdir -p "$WORKDIR/unpacked"
tar -xf "$WORKDIR/archive.tar" -C "$WORKDIR/unpacked"
python3 - <<PY
import json
m = json.load(open("$WORKDIR/unpacked/manifest.json", encoding="utf-8"))
counts = {(r["schema"], r["table"]): r for r in m["row_counts"]}
assert counts[("booking", "orders")]["rows"] == 1
assert counts[("booking", "payments")]["rows"] == 1
assert counts[("booking", "gift_cards")]["rows"] == 2
assert counts[("booking", "reservations")]["rows"] == 1
assert counts[("kb", "products")]["rows"] == 3
assert counts[("booking", "bookings")]["present"] is False
assert m["roles"]["method"] in ("catalog-query", "pg_dumpall")
assert m["roles"]["ok"] is (m["roles"]["method"] == "pg_dumpall")
assert m["storage"]["file_count"] == 2
assert m["storage"]["private_missing"] == []
assert "logos" in m["storage"]["other_buckets"]
assert m["dump"]["pg_restore_list_ok"] is True
for schema in ("public", "kb", "booking", "auth", "storage", "supabase_migrations", "cron"):
    assert schema in m["dump"]["schemas"], schema
PY
grep -q "hello-storage" "$WORKDIR/unpacked/storage/files/article-images/a.txt"
grep -q "hello-receipt" "$WORKDIR/unpacked/storage/files/receipts/r.pdf"
if [[ -e "$WORKDIR/unpacked/storage/files/logos/skip.txt" ]]; then
  echo "vieras bucket päätyi arkistoon" >&2
  exit 1
fi
# roles.sql ei sisällä testin salasanaa. pg_dumpall tai varaluettelo kelpaa.
grep -q -e "pg_dumpall" -e "database cluster dump" "$WORKDIR/unpacked/roles.sql"
if grep -q -e "backup_test_only" -e "storage-test-only" -e "test-anon" "$WORKDIR/unpacked/roles.sql" "$WORKDIR/unpacked/manifest.json"; then
  echo "salasana vuoti arkistoon" >&2
  exit 1
fi

echo "== purku arkistosta =="
RESTORE_TARGET_URL="postgresql://postgres:postgres@127.0.0.1:${PORT}/postgres?sslmode=disable" \
  bash "$HERE/restore-test.sh" --archive "$AGE_FILE" --identity "$WORKDIR/identity.txt"

echo "== tuotanto-osoite kielletään =="
if RESTORE_TARGET_URL="postgresql://postgres:secret@db.sxbofnuisemspgquoxyv.supabase.co:5432/postgres" \
  bash "$HERE/restore-test.sh" --dump "$WORKDIR/unpacked/database.dump" --manifest "$WORKDIR/unpacked/manifest.json"; then
  echo "tuotanto-osoite meni läpi" >&2
  exit 1
fi

echo "== liian pieni dumppi kaataa ajon =="
if SUPABASE_BACKUP_DB_URL="postgresql://backup_reader:backup_test_only@127.0.0.1:${PORT}/postgres?sslmode=disable" \
  BACKUP_AGE_PUBLIC_KEY="$PUB" \
  BACKUP_MIN_DUMP_BYTES=999999999 \
  BACKUP_SKIP_UPLOAD=1 \
  BACKUP_SKIP_STORAGE=1 \
  bash "$HERE/backup.sh"; then
  echo "minimikoko ei kaatanut" >&2
  exit 1
fi

echo "== transaktiopooleri kielletään =="
if SUPABASE_BACKUP_DB_URL="postgresql://backup_reader:secret@127.0.0.1:6543/postgres" \
  BACKUP_AGE_PUBLIC_KEY="$PUB" \
  BACKUP_SKIP_UPLOAD=1 \
  BACKUP_SKIP_STORAGE=1 \
  bash "$HERE/backup.sh"; then
  echo "portti 6543 meni läpi" >&2
  exit 1
fi

echo "== rollback psql -1 =="
psql -X -v ON_ERROR_STOP=1 -1 -f "$ROOT/booking/supabase/rollbacks/20261019140100_ops_002_ROLLBACK.sql"
psql -X -v ON_ERROR_STOP=1 -1 -f "$ROOT/booking/supabase/rollbacks/20261019140000_ops_001_ROLLBACK.sql"
POL="$(psql -X -v ON_ERROR_STOP=1 -At -c "select count(*) from pg_policy where polname = 'backup_storage_reader_select'")"
[[ "$POL" == "0" ]]
COUNT="$(psql -X -v ON_ERROR_STOP=1 -At -c "select count(*) from pg_roles where rolname = 'backup_reader'")"
[[ "$COUNT" == "0" ]]

echo "PAIKALLINEN KOE OK"
