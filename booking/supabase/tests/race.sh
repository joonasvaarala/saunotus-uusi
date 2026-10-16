#!/usr/bin/env bash
# Kilpailutilannetesti: rinnakkaiset tietokantayhteydet (anon-rooli) yrittävät varata samaa aikaa yhtä aikaa.
# Portti: kontrolloija pitää advisory lockin; työntekijät odottavat sitä ja vapautuvat samalla hetkellä.
# Invariantit jokaisen kierroksen jälkeen:
#   (1) yksityisvuoro ja yleinen vuoro eivät ole koskaan samaan aikaan aktiivisina
#   (2) kapasiteettia ei ylitetä (ma–ke/to 16; viikonloppu 6 / alkamisaika, 1 h vuoro 10; poolit ovat toisistaan riippumattomia)
#   (3) vuosikortilla vain yksi tuleva varaus; asiakkaan varauksen muutokset (public_change_booking) noudattavat samoja lukkoja
set -uo pipefail
cd "$(dirname "$0")"
export PGHOST="${PGHOST:-127.0.0.1}" PGPORT="${PGPORT:-54329}" PGUSER="${PGUSER:-postgres}"
DB="${BOOKING_TEST_DB:-booking_test}"
P() { psql -X -q -A -t -d "$DB" "$@"; }
fail=0
check() { # nimi odotettu saatu
  if [ "$2" = "$3" ]; then echo "ok   race: $1 (= $3)"; else echo "FAIL race: $1 (odotettu $2, saatu $3)"; fail=1; fi
}
SEQ=0
# testikanta on kertakäyttöinen: pidennetään varausikkunaa, jotta kaukaiset päivät voi varata
P -c "update booking.settings set value = '400' where key = 'booking_horizon_days'" >/dev/null
# worker <portti-lock> <rule_id> <date> <persons> -> tulostaa koodin (ok / virhekoodi)
worker() {
  local rule=$1 date=$2 persons=$3 id; id="$RANDOM$RANDOM$RANDOM"
  (
    P -v ON_ERROR_STOP=1 <<SQL
begin;
select pg_advisory_lock_shared(7770001);   -- portti
select pg_advisory_unlock_shared(7770001);
select test.anon('10.$((RANDOM % 250 + 1)).$((RANDOM % 250 + 1)).$((RANDOM % 250 + 1))');
select coalesce(booking.public_create_booking($rule, '$date', $persons, 'Kilpa Testi', 'race$$-$id@example.com', '0401234567') ->> 'code', 'ok');
commit;
SQL
  ) 2>&1 | grep -E '^(ok|[a-z_]+)$' | tail -1
}
# round <rule_id,date,persons> ... : käynnistää kaikki yhtä aikaa
round() {
  local tmp; tmp=$(mktemp -d)
  ( P -c "select pg_advisory_lock(7770001); select pg_sleep(1.2);" >/dev/null 2>&1 ) &
  local ctl=$!
  sleep 0.4
  local i=0 spec
  for spec in "$@"; do
    IFS=, read -r rule date persons <<<"$spec"
    ( worker "$rule" "$date" "$persons" > "$tmp/$i" ) &
    i=$((i+1))
  done
  wait
  cat "$tmp"/* 2>/dev/null | sort | uniq -c | tr '\n' ' '
  rm -rf "$tmp"
}
rule_id() { P -c "select test.rule('$1')"; }
next_dow() { P -c "select test.next_dow($1, ${2:-3})"; }

R_PRIV=$(rule_id 'Oma savusaunavuoro ma–pe 16–19%')
R_MON=$(rule_id 'Miesten sauna%')
R_THU=$(rule_id 'Yleinen vuoro to 17–19')
R_PRIV_THU=$R_PRIV
R_SAT14=$(rule_id 'Yleinen vuoro la–su 14:00%')
R_SAT_PRIV=$(rule_id 'Oma savusaunavuoro la–su 13–15%')
R_SAT1430=$(rule_id 'Yleinen vuoro la–su 14:30%')
R_H14=$(rule_id 'Tunnin saunavuoro la–su 14:00%')
MON=$(next_dow 1)

# --- 1) yksityinen vs. yleiset samanaikaisesti: 8 kierrosta, eri päivä joka kierroksella
bad=0; privwins=0; pubwins=0
for k in 0 1 2 3 4 5 6 7; do
  d=$(P -c "select ('$MON'::date + 7 * $k)")
  out=$(round "$R_PRIV,$d,4" "$R_MON,$d,2" "$R_MON,$d,3" "$R_MON,$d,1" "$R_PRIV,$d,5")
  conflicts=$(P -c "select count(*) from booking.reservations a join booking.reservations b on a.id < b.id and a.space_id = b.space_id
                      and tstzrange(a.starts_at, a.ends_at) && tstzrange(b.starts_at, b.ends_at)
                      and a.mode <> b.mode and a.status in ('confirmed') and b.status in ('confirmed')
                    where a.starts_at::date = '$d'")
  excl=$(P -c "select count(*) from booking.reservations where mode = 'exclusive' and status = 'confirmed' and starts_at::date = '$d'")
  shared=$(P -c "select count(*) from booking.reservations where mode = 'shared' and status = 'confirmed' and starts_at::date = '$d'")
  [ "$excl" -gt 1 ] && bad=$((bad+1))
  [ "$conflicts" != 0 ] && bad=$((bad+1))
  [ "$excl" = 1 ] && privwins=$((privwins+1))
  [ "$shared" -gt 0 ] && pubwins=$((pubwins+1))
  echo "     kierros $k ($d): yksityisiä=$excl yleisiä=$shared ristiriitoja=$conflicts  [$out]"
done
check "yksityisvuoro ja yleinen vuoro eivät koskaan päällekkäin (8 kierrosta)" 0 "$bad"
echo "     (yksityinen voitti $privwins kierrosta, yleiset $pubwins; molempia tulisi esiintyä kun kilpailu on aitoa)"

# --- 2) kapasiteetti: ma 16 hlöä, 10 x 4 henkilöä yhtä aikaa => täsmälleen 4 onnistuu
d=$(P -c "select ('$MON'::date + 70)")
specs=(); for i in $(seq 1 10); do specs+=("$R_MON,$d,4"); done
out=$(round "${specs[@]}")
sum=$(P -c "select coalesce(sum(persons),0) from booking.reservations where status='confirmed' and starts_at::date='$d'")
check "ma kapasiteetti 16: yhteensä enintään 16 henkilöä (10 x 4 rinnakkain)" 16 "$sum"
echo "     [$out]"

# --- 3) torstai: yleinen 17–19 (16) rinnakkain, 20 x 1 henkilö => 16
THU=$(next_dow 4)
d=$(P -c "select ('$THU'::date + 35)")
specs=(); for i in $(seq 1 20); do specs+=("$R_THU,$d,1"); done
out=$(round "${specs[@]}")
sum=$(P -c "select coalesce(sum(persons),0) from booking.reservations where status='confirmed' and starts_at::date='$d'")
check "to kapasiteetti 16: 20 x 1 rinnakkain => 16" 16 "$sum"
echo "     [$out]"

# --- 4) viikonloppu: kapasiteetti 6 PER ALKAMISAIKA, 8 x 2 henkilöä la 14:00 => 3 onnistuu (6 henkilöä)
SAT=$(next_dow 6)
d=$(P -c "select ('$SAT'::date + 49)")
specs=(); for i in $(seq 1 8); do specs+=("$R_SAT14,$d,2"); done
out=$(round "${specs[@]}")
sum=$(P -c "select coalesce(sum(persons),0) from booking.reservations where status='confirmed' and rule_id=$R_SAT14 and starts_at::date='$d'")
check "la 14:00 kapasiteetti 6: 8 x 2 rinnakkain => 6 henkilöä" 6 "$sum"
echo "     [$out]"

# --- 5) viikonloppu: limittäiset alkamisajat (14:00 + 14:30) ovat TOISISTAAN RIIPPUMATTOMIA: kummallakin täsmälleen 6
d=$(P -c "select ('$SAT'::date + 56)")
specs=(); for i in 1 2 3 4; do specs+=("$R_SAT14,$d,2" "$R_SAT1430,$d,2"); done
out=$(round "${specs[@]}")
s14=$(P -c "select coalesce(sum(persons),0) from booking.reservations where status='confirmed' and rule_id=$R_SAT14 and starts_at::date='$d'")
s1430=$(P -c "select coalesce(sum(persons),0) from booking.reservations where status='confirmed' and rule_id=$R_SAT1430 and starts_at::date='$d'")
check "la 14:00 ja 14:30 rinnakkain: 14:00 täsmälleen 6" 6 "$s14"
check "la 14:00 ja 14:30 rinnakkain: 14:30 täsmälleen 6 (oma pooli)" 6 "$s1430"
echo "     [$out]"

# --- 6) la yksityisvuoro 13–15 vs yleinen 14:00 / 14:30 / 1 h 14:00 rinnakkain: ei koskaan molempia
bad=0
for k in 0 1 2 3; do
  d=$(P -c "select ('$SAT'::date + 63 + 7 * $k)")
  out=$(round "$R_SAT_PRIV,$d,4" "$R_SAT14,$d,2" "$R_SAT1430,$d,1" "$R_SAT_PRIV,$d,3" "$R_H14,$d,2")
  c=$(P -c "select (count(*) filter (where mode='exclusive' and status='confirmed') > 0 and count(*) filter (where mode='shared' and status='confirmed' and starts_at < (('$d'::date + time '15:00') at time zone 'Europe/Helsinki')) > 0)::int from booking.reservations where starts_at::date='$d'")
  [ "$c" = 1 ] && bad=$((bad+1))
done
check "la yksityinen 13–15 vs yleiset 14:00/14:30 ja 1 h 14:00 rinnakkain: ei koskaan molempia" 0 "$bad"

# --- 7) 1 h vuoro 14:00: oma kapasiteetti 10, 14 x 1 henkilöä => 10; rinnakkain 2 h 14:00 (6) ei jaa kapasiteettia
d=$(P -c "select ('$SAT'::date + 98)")
specs=(); for i in $(seq 1 14); do specs+=("$R_H14,$d,1"); done
for i in $(seq 1 8); do specs+=("$R_SAT14,$d,1"); done
out=$(round "${specs[@]}")
sh=$(P -c "select coalesce(sum(persons),0) from booking.reservations where status='confirmed' and rule_id=$R_H14 and starts_at::date='$d'")
s2=$(P -c "select coalesce(sum(persons),0) from booking.reservations where status='confirmed' and rule_id=$R_SAT14 and starts_at::date='$d'")
check "1 h vuoro 14:00: kapasiteetti 10 (14 x 1 rinnakkain)" 10 "$sh"
check "1 h ja 2 h vuoro samaan aikaan: 2 h vuoro 6 (ei jaa kapasiteettia)" 6 "$s2"
echo "     [$out]"

# --- 8) vuosikortti: 6 rinnakkaista vuosikorttivarausta eri päiville => täsmälleen YKSI onnistuu
CSTAFF=$(P -c "select test.mk_staff('race-staff@example.com', 'staff')")
CARDCUST=$(P -c "insert into booking.customers(name, email, phone) values ('Race Kortti', 'race-kortti@example.com', '0401234567') returning id")
P -c "insert into booking.annual_cards(customer_id, valid_from, valid_to) values ($CARDCUST, current_date - 1, current_date + 365)" >/dev/null
cardworker() { # rule date
  local rule=$1 date=$2
  (
    P -v ON_ERROR_STOP=1 <<SQL
begin;
select pg_advisory_lock_shared(7770001);
select pg_advisory_unlock_shared(7770001);
select test.login('$CSTAFF');
select test.code(\$q\$select booking.admin_create_annual_card_booking($CARDCUST, $rule, '$date')\$q\$);
commit;
SQL
  ) 2>&1 | grep -E '^(ok|[a-z_]+)$' | tail -1
}
tmp=$(mktemp -d)
( P -c "select pg_advisory_lock(7770001); select pg_sleep(1.2);" >/dev/null 2>&1 ) &
sleep 0.4
for k in 0 1 2 3 4 5; do
  d=$(P -c "select ('$MON'::date + 210 + 7 * $k)")
  ( cardworker "$R_MON" "$d" > "$tmp/$k" ) &
done
wait
out=$(cat "$tmp"/* | sort | uniq -c | tr '\n' ' '); rm -rf "$tmp"
n=$(P -c "select count(*) from booking.reservations r where r.annual_card_id in (select id from booking.annual_cards where customer_id = $CARDCUST) and r.status='confirmed'")
check "vuosikortti: 6 rinnakkaista varausta => 1 tuleva varaus" 1 "$n"
echo "     [$out]"

# --- 9) asiakkaan muutos (public_change_booking) rinnakkain: 5 siirtäjää x 2 hlö vuoroon, jossa 6 vapaata paikkaa => 3 onnistuu
mkbook() { # rule date persons -> token
  P -c "select booking.public_create_booking($1, '$2', $3, 'Muutos Race', 'race-muutos' || nextval('test.seq') || '@example.com', '0401234567') ->> 'token'"
}
dt=$(P -c "select ('$MON'::date + 140)")     # kohdepäivä
ds=$(P -c "select ('$MON'::date + 147)")     # lähtöpäivä
mkbook "$R_MON" "$dt" 10 >/dev/null          # kohdepäivä: 10/16 täynnä, 6 vapaata
tokens=(); for i in 1 2 3 4 5; do tokens+=("$(mkbook "$R_MON" "$ds" 2)"); done
changeworker() { # token rule date
  (
    P -v ON_ERROR_STOP=1 <<SQL
begin;
select pg_advisory_lock_shared(7770001);
select pg_advisory_unlock_shared(7770001);
select test.anon('10.$((RANDOM % 250 + 1)).$((RANDOM % 250 + 1)).$((RANDOM % 250 + 1))');
select coalesce(booking.public_change_booking('$1'::uuid, $2, '$3'::date, null) ->> 'code', 'ok');
commit;
SQL
  ) 2>&1 | grep -E '^(ok|[a-z_]+)$' | tail -1
}
tmp=$(mktemp -d)
( P -c "select pg_advisory_lock(7770001); select pg_sleep(1.2);" >/dev/null 2>&1 ) &
sleep 0.4
i=0; for t in "${tokens[@]}"; do ( changeworker "$t" "$R_MON" "$dt" > "$tmp/$i" ) & i=$((i+1)); done
wait
out=$(cat "$tmp"/* | sort | uniq -c | tr '\n' ' '); rm -rf "$tmp"
sum=$(P -c "select coalesce(sum(persons),0) from booking.reservations where status='confirmed' and rule_id=$R_MON and starts_at::date='$dt'")
moved=$(P -c "select count(*) from booking.reservations where status='confirmed' and rule_id=$R_MON and starts_at::date='$ds'")
check "muutos: kohdevuoro ei ylity (10 + 3 x 2 = 16 henkilöä)" 16 "$sum"
check "muutos: 2 siirtäjää jäi alkuperäiselle päivälle" 2 "$moved"
echo "     [$out]"

# --- 10) muutos vs. uusi yksityisvuoro samaan aikaan: ei päällekkäisyyttä
bad=0
for k in 0 1 2 3; do
  dt=$(P -c "select ('$MON'::date + 154 + 7 * $k)")
  ds=$(P -c "select ('$MON'::date + 182 + 7 * $k)")
  tokens=(); for i in 1 2 3; do tokens+=("$(mkbook "$R_MON" "$ds" 1)"); done
  tmp=$(mktemp -d)
  ( P -c "select pg_advisory_lock(7770001); select pg_sleep(1.2);" >/dev/null 2>&1 ) &
  sleep 0.4
  i=0; for t in "${tokens[@]}"; do ( changeworker "$t" "$R_MON" "$dt" > "$tmp/c$i" ) & i=$((i+1)); done
  ( worker "$R_PRIV" "$dt" 4 > "$tmp/p1" ) &
  ( worker "$R_PRIV" "$dt" 5 > "$tmp/p2" ) &
  wait
  rm -rf "$tmp"
  c=$(P -c "select count(*) from booking.reservations a join booking.reservations b on a.id < b.id and a.space_id = b.space_id
              and tstzrange(a.starts_at, a.ends_at) && tstzrange(b.starts_at, b.ends_at)
              and a.mode <> b.mode and a.status = 'confirmed' and b.status = 'confirmed'
            where a.starts_at::date = '$dt'")
  excl=$(P -c "select count(*) from booking.reservations where mode='exclusive' and status='confirmed' and starts_at::date='$dt'")
  [ "$c" != 0 ] && bad=$((bad+1))
  [ "$excl" -gt 1 ] && bad=$((bad+1))
done
check "muutos vs. yksityisvuoro rinnakkain: ei päällekkäisyyttä (4 kierrosta)" 0 "$bad"

# siivous: poista kilpatestin data (testikanta on kertakäyttöinen, mutta pidetään se siistinä)
P -c "delete from booking.reservations where order_id in (select o.id from booking.orders o join booking.customers c on c.id=o.customer_id where c.email like 'race%@example.com')" >/dev/null 2>&1 || true

[ "$fail" = 0 ]
