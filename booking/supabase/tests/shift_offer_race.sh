#!/usr/bin/env bash
# Kaksi vastaanottajaa hyväksyy saman tarjouksen yhtä aikaa.
# Portti on advisory lock: molemmat transaktiot odottavat ja lähtevät samalla hetkellä.
# Invariantti: tasan yksi accepted, toinen already_taken, ja avoimille (häviäjä + kolmas) jonottuu "Vuoro on täytetty".
set -uo pipefail
cd "$(dirname "$0")"
export PGHOST="${PGHOST:-127.0.0.1}" PGPORT="${PGPORT:-54329}" PGUSER="${PGUSER:-postgres}"
DB="${BOOKING_TEST_DB:-booking_test}"
P() { psql -X -q -A -t -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
fail=0
check() {
  if [ "$2" = "$3" ]; then echo "ok   shift-offer race: $1 (= $3)"; else echo "FAIL shift-offer race: $1 (odotettu $2, saatu $3)"; fail=1; fi
}

OFFER=bbbbbbbb-0000-4000-8000-00000000e001
SHIFT=bbbbbbbb-0000-4000-8000-00000000e021
S1=bbbbbbbb-0000-4000-8000-00000000e011
S2=bbbbbbbb-0000-4000-8000-00000000e012
S3=bbbbbbbb-0000-4000-8000-00000000e013

cleanup() {
  P <<SQL >/dev/null 2>&1 || true
delete from public.shift_offer_messages where offer_id = '${OFFER}';
delete from public.shift_offers where id = '${OFFER}';
delete from public.work_shifts where id = '${SHIFT}';
delete from public.staff where id in ('${S1}','${S2}','${S3}');
delete from public.shift_offer_response_tiers where note = 'race-shift-offer';
delete from public.shift_offer_settings where role_type = 'heater' and updated_by = 'race-shift-offer';
SQL
}
trap cleanup EXIT
cleanup

P <<SQL >/dev/null
insert into public.shift_offer_settings (role_type, enabled, updated_by)
values ('heater', true, 'race-shift-offer');
insert into public.shift_offer_response_tiers (role_type, min_lead, wait, direct_to_all, note)
values (null, interval '0', null, true, 'race-shift-offer');
insert into public.staff (id, name, email, active) values
  ('${S1}', 'Race Aino', 'race.aino@example.com', true),
  ('${S2}', 'Race Bertta', 'race.bertta@example.com', true),
  ('${S3}', 'Race Dora', 'race.dora@example.com', true);
insert into public.work_shifts (id, starts_at, ends_at, role_type, status, staffing_status)
values ('${SHIFT}', now() + interval '40 days', now() + interval '40 days 8 hours', 'heater', 'active', 'open');
insert into public.shift_offers (id, shift_id, role_type, scenario, status, current_round_no, created_by)
values ('${OFFER}', '${SHIFT}', 'heater', 'vacant_shift', 'active', 1, 'race-shift-offer');
insert into public.shift_offer_recipients (offer_id, staff_id, round_no, round_kind, status, sent_at)
values
  ('${OFFER}', '${S1}', 1, 'named', 'pending', now()),
  ('${OFFER}', '${S2}', 1, 'named', 'pending', now()),
  ('${OFFER}', '${S3}', 1, 'named', 'pending', now());
SQL

worker() {
  local staff=$1
  P <<SQL 2>&1 | grep -E '^(accepted|already_taken|already_filled|not_recipient|offer_closed|invalid_state|bad_token)$' | tail -1
begin;
select pg_advisory_lock_shared(7770002);
select pg_advisory_unlock_shared(7770002);
select public.shift_offer_engine_respond('${OFFER}'::uuid, '${staff}'::uuid, 'accept', null, null) ->> 'result';
commit;
SQL
}

tmp=$(mktemp -d)
( P -c "select pg_advisory_lock(7770002); select pg_sleep(1.2);" >/dev/null 2>&1 ) &
sleep 0.4
( worker "$S1" > "$tmp/1" ) &
( worker "$S2" > "$tmp/2" ) &
wait
results=$(cat "$tmp"/1 "$tmp"/2 | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//')
rm -rf "$tmp"
echo "     tulokset: [$results]"
check "tasan yksi voittaja ja yksi already_taken" "accepted already_taken" "$results"

winners=$(P -c "select count(*) from public.shift_offer_recipients where offer_id = '${OFFER}' and status = 'accepted'")
taken=$(P -c "select count(*) from public.shift_offers where id = '${OFFER}' and status = 'filled'")
filled=$(P -c "select count(*) from public.shift_offer_messages where offer_id = '${OFFER}' and kind = 'filled' and body like '%Vuoro on täytetty%' and body like '%–Tapio%'")
winner_mail=$(P -c "select count(*) from public.shift_offer_messages m join public.shift_offers o on o.id = m.offer_id and o.accepted_staff_id = m.staff_id where m.offer_id = '${OFFER}' and m.kind = 'filled'")
quiet=$(P -c "select count(*) from public.shift_offer_messages where offer_id = '${OFFER}' and staff_id = '${S3}' and kind = 'filled'")
check "yksi accepted-rivi" "1" "$winners"
check "tarjous filled" "1" "$taken"
check "vuoro täytetty -ilmoitus häviäjälle ja kolmannelle" "2" "$filled"
check "voittajalle ei täytetty-ilmoitusta" "0" "$winner_mail"
check "kolmas vastaanottaja saa ilmoituksen" "1" "$quiet"

exit "$fail"
