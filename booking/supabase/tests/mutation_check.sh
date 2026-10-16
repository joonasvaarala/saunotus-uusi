#!/usr/bin/env bash
# Todistaa että kilpailutesti on herkkä: poistaa advisory lockin triggeristä TESTIKANNASSA ja odottaa race.sh:n epäonnistuvan.
# Aja run.sh:n jälkeen. Palauttaa 0, jos testi (oikein) epäonnistuu ilman lukkoa.
set -uo pipefail
cd "$(dirname "$0")"
export PGHOST="${PGHOST:-127.0.0.1}" PGPORT="${PGPORT:-54329}" PGUSER="${PGUSER:-postgres}"
DB="${BOOKING_TEST_DB:-booking_test}"
psql -X -At -d "$DB" -c "select pg_get_functiondef('booking.reservations_validate'::regproc)" \
 | sed 's/perform pg_advisory_xact_lock([^;]*;/null;/I' | psql -X -q -d "$DB" -f -
if ./race.sh >/dev/null 2>&1; then echo "VIRHE: race.sh meni läpi ilman lukkoa – testi ei ole herkkä"; exit 1; fi
echo "ok: race.sh epäonnistuu ilman advisory lockia (testi todella havaitsee kilpailun)"
