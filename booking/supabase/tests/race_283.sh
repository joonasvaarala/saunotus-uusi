#!/usr/bin/env bash
# Kilpailutilannetesti (booking_282–284): kaksi rinnakkaista yhteyttä hyvittää samaa ylisuoritusta / muuttaa samaa varausta / peruu samaa tilausta.
# Käyttö (kertakäyttöinen kanta, jossa migraatiot + fixtures/10_test_helpers.sql on ajettu, myös 282–284):
#   PGHOST=127.0.0.1 PGPORT=54329 PGUSER=postgres BOOKING_TEST_DB=booking_test ./race_283.sh
# Invariantit: (1) tilauksen ylisuoritus hyvitetään kerran (hyvitykset yhteensä = ylisuoritus), toinen yhteys saa virheen (nothing_to_refund / amount_exceeds_refundable);
# (2) koko tilauksen peruutus (admin_cancel_order) onnistuu vain kerran; (3) asiakkaan kaksoispyyntö (public_change_booking) luo vain yhden hyvityksen.
# Testi kirjoittaa pysyviä rivejä (ei rollback): aja vain kertakäyttöisessä testikannassa.
set -uo pipefail
cd "$(dirname "$0")"
export PGHOST="${PGHOST:-127.0.0.1}" PGPORT="${PGPORT:-54329}" PGUSER="${PGUSER:-postgres}"
DB="${BOOKING_TEST_DB:-booking_test}"
P() { psql -X -q -A -t -d "$DB" "$@"; }
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   race283: $1 (= $3)"; else echo "FAIL race283: $1 (odotettu $2, saatu $3)"; fail=1; fi; }
P -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
update booking.settings set value = '400' where key = 'booking_horizon_days';
update booking.settings set value = '1000' where key in ('rl_change_per_10min', 'rl_ip_per_10min', 'rl_email_per_10min');
update booking.settings set value = 'true'::jsonb where key in ('partial_refunds_enabled', 'customer_auto_partial_refund_enabled');
update booking.integration_config set mode = 'test', settings = settings || '{"approved_by":"race"}'::jsonb where key = 'montonio';
SQL
ADM=$(P -c "select test.mk_staff('race283-adm@example.com', 'admin')")
RULE=$(P -c "select test.rule('Miesten sauna%')")
setup_order() {
  local weeks=$1
  P -v ON_ERROR_STOP=1 <<SQL | tail -1
begin;
select test.reset_rl();
select test.pub_book($RULE, test.next_dow(1, 20) + 7 * $weeks, 3, 'race283-$weeks@example.com') as b \gset
select (test.ord((:'b'::jsonb ->> 'token')::uuid)).id as oid, (:'b'::jsonb ->> 'token') as tok \gset
select test.login('$ADM'::uuid);
select booking.admin_record_payment(:oid, 'card_terminal', 87, null, null);
select test.logout();
update booking.payments set provider = 'montonio', method = 'montonio', raw = '{"order_uuid":"x","env":"test"}'::jsonb where order_id = :oid and method = 'card_terminal';
update booking.product_config set cancellation_tier = 'general' where product_id = (select product_id from booking.reservations where order_id = :oid);
commit;
select :oid || ' ' || :'tok';
SQL
}
# yhteys: begin; login; kutsu; (viive); commit
sess() {   # $1 = viive ennen commitia (s), $2 = SQL-kutsu
  P <<SQL 2>&1 | tr '\n' ' '
begin;
select test.login('$ADM'::uuid);
select coalesce((select 'ok' from (select $2) q), 'ok');
select pg_sleep($1);
commit;
SQL
}
# --- (1) ylisuoritus hyvitetään kerran ---
read OID TOK < <(setup_order 0)
RES=$(P -c "select id from booking.reservations where order_id = $OID")
P -c "begin; select test.login('$ADM'::uuid); select booking.admin_change_booking($RES, null, null, 2); commit;" >/dev/null 2>&1
(sess 2 "booking.admin_refund_overpayment($OID, 29, null, 'race a', false)" > /tmp/race283_a.txt) &
sleep 0.7
(sess 0 "booking.admin_refund_overpayment($OID, 29, null, 'race b', false)" > /tmp/race283_b.txt) &
wait
check "ylisuoritus hyvitetty kerran (rivejä)" 1 "$(P -c "select count(*) from booking.refunds where order_id = $OID")"
check "ylisuoritus hyvitetty kerran (summa)" 29.00 "$(P -c "select coalesce(sum(amount), 0) from booking.refunds where order_id = $OID")"
if grep -qE "nothing_to_refund|amount_exceeds_refundable|ei ole hyvitett|ylit" /tmp/race283_a.txt /tmp/race283_b.txt; then echo "ok   race283: toinen yhteys sai virheen"; else echo "FAIL race283: kumpikaan ei saanut virhettä: $(cat /tmp/race283_a.txt /tmp/race283_b.txt)"; fail=1; fi
# --- (2) koko tilauksen peruutus kerran ---
read OID TOK < <(setup_order 1)
(sess 2 "booking.admin_cancel_order($OID, 'race', null, false, null)" > /tmp/race283_a.txt) &
sleep 0.7
(sess 0 "booking.admin_cancel_order($OID, 'race', null, false, null)" > /tmp/race283_b.txt) &
wait
check "admin_cancel_order audit-rivejä" 1 "$(P -c "select count(*) from booking.audit_log where action = 'ADMIN_CANCEL_ORDER' and row_pk = '$OID'")"
check "tilaus peruttu" cancelled "$(P -c "select status from booking.orders where id = $OID")"
# --- (3) asiakkaan kaksoispyyntö: yksi hyvitys ---
read OID TOK < <(setup_order 2)
anon_call() { P <<SQL 2>&1 | tr '\n' ' '
begin;
select test.anon('10.9.$((RANDOM % 250)).$((RANDOM % 250 + 1))');
select booking.public_change_booking('$TOK'::uuid, null, null, 2, 29)::text;
select pg_sleep($1);
commit;
SQL
}
(anon_call 2 > /tmp/race283_a.txt) &
sleep 0.7
(anon_call 0 > /tmp/race283_b.txt) &
wait
check "asiakkaan hyvitys kerran (rivejä)" 1 "$(P -c "select count(*) from booking.refunds where order_id = $OID and reason = 'customer_reduce'")"
check "asiakkaan hyvitys kerran (summa)" 29.00 "$(P -c "select coalesce(sum(amount), 0) from booking.refunds where order_id = $OID")"
if [ "$fail" = 1 ]; then echo "RACE283 EPÄONNISTUI"; exit 1; fi
echo "RACE283 OK"
