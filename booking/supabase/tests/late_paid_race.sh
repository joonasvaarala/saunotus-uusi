#!/usr/bin/env bash
# LOCAL ONLY – EI DEV/PROD. Peruutus vs. myöhäinen maksu oikeilla rinnakkaisilla yhteyksillä (molemmat järjestykset).
# Luo kertakäyttöisen kannan pohjakannasta (migraatiot ajettu), asentaa numeroimattoman luonnoksen, ajaa ja poistaa kannan.
# Käyttö: PGHOST=127.0.0.1 PGPORT=54329 PGUSER=postgres BASE_DB=lp_base ./late_paid_race.sh
set -euo pipefail
cd "$(dirname "$0")"
export PGHOST="${PGHOST:-127.0.0.1}" PGPORT="${PGPORT:-54329}" PGUSER="${PGUSER:-postgres}"
BASE="${BASE_DB:-booking_test}"; DB="lp_race_$$"
psql -X -q -d postgres -c "create database $DB template $BASE"
trap 'psql -X -q -d postgres -c "drop database if exists '"$DB"' with (force)"' EXIT
P=(psql -X -q -At -v ON_ERROR_STOP=1 -d "$DB")
"${P[@]}" -f ../unnumbered/late_paid_cancelled_order.sql >/dev/null
SVC="set role service_role; select set_config('request.jwt.claims','{\"role\":\"service_role\"}',false);"
setup() { # $1 = slot index → "order_id order_no order_number amount"
  "${P[@]}" <<SQL | tail -1
update booking.settings set value = '"hold_until_paid"'::jsonb where key = 'public_payment_mode';
insert into booking.integration_config(key, mode, settings) values ('montonio','test','{"approved_by":"race"}')
  on conflict (key) do update set mode='test', settings = coalesce(booking.integration_config.settings,'{}'::jsonb) || '{"approved_by":"race"}';
select booking.public_create_treatment_booking(11, (select q.starts_at from booking.public_treatment_availability(11, current_date + 3 + $1 * 3, current_date + 5 + $1 * 3, 2) q
  where q.status = 'available' order by 1 limit 1), 2, 'Race', 'race$1@example.test', '+358401234567', false, 'fi', null, 'private', null, null) ->> 'token' as tok \\gset
select booking.montonio_payment_prepare(:'tok'::uuid, null, 'paymentInitiation') as m \\gset
select o.id || ' ' || o.order_no || ' ' || (:'m'::jsonb ->> 'order_number') || ' ' || (:'m'::jsonb ->> 'amount') from booking.orders o where o.public_token = :'tok'::uuid;
SQL
}
check() { "${P[@]}" -c "select o.status || ' ' || o.payment_status || ' res=' || (select string_agg(distinct status, ',') from booking.reservations where order_id = o.id)
  || ' paid=' || (select count(*) from booking.payments where order_id = o.id and status = 'paid') || ' receipts=' || (select count(*) from booking.receipts where order_id = o.id)
  || ' late_audit=' || (select count(*) from booking.audit_log a join booking.payments p on a.row_pk = p.id::text where p.order_id = o.id and a.action = 'LATE_PAID_CANCELLED_ORDER')
  from booking.orders o where o.id = $1"; }
fail=0
# R1: peruutus ensin (pitää lukot 2 s), maksu-callback odottaa → peruttu säilyy
read -r O1 N1 A1 M1 < <(setup 1)
( "${P[@]}" -c "begin; $SVC select booking.svc_cancel_reservation($N1, 'race r1'); select pg_sleep(2); commit;" >/dev/null ) &
sleep 0.5
T0=$(date +%s%N); R1=$("${P[@]}" -c "$SVC select booking.montonio_payment_apply('$A1', 'paid', $M1, '{}'::jsonb)" | tail -1); wait
S1=$(check "$O1"); W1=$(( ($(date +%s%N) - T0) / 1000000 )); echo "R1 cancel→paid: $S1 | waited_ms=$W1 | $R1"
[[ "$W1" -ge 1000 && "$S1" == "cancelled paid res=cancelled paid=1 receipts=1 late_audit=1" && "$R1" == *'"order_cancelled": true'* ]] || { echo "FAIL R1"; fail=1; }
# R2: maksu ensin (pitää lukot 2 s), peruutus odottaa → maksettu vahvistettu tilaus perutaan normaalisti, ei tarkistusmerkintää
read -r O2 N2 A2 M2 < <(setup 2)
( "${P[@]}" -c "begin; $SVC select booking.montonio_payment_apply('$A2', 'paid', $M2, '{}'::jsonb); select pg_sleep(2); commit;" >/dev/null ) &
sleep 0.5
"${P[@]}" -c "$SVC select booking.svc_cancel_reservation($N2, 'race r2')" >/dev/null; wait
S2=$(check "$O2"); echo "R2 paid→cancel: $S2"
[[ "$S2" == "cancelled paid res=cancelled paid=1 receipts=1 late_audit=0" ]] || { echo "FAIL R2"; fail=1; }
[ "$fail" = 0 ] && echo "RACE OK" || { echo "RACE FAIL"; exit 1; }
