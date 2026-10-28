-- t211: saunotus_2-lahjakorttipaketti enintään 2 hengelle (booking_211).
-- Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n jälkeen. TESTRESULT pass=N fail=M.
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t211_r(ok boolean, label text) on commit drop;
grant all on t211_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t211_r values (coalesce(p_ok, false), p_label) $$;
do $t$
declare
  pkg booking.gift_card_packages; v_ok boolean; v_code text;
begin
  select * into pkg from booking.gift_card_packages where code = 'saunotus_2';
  perform pg_temp.ck(pkg.min_persons = 1 and pkg.max_persons = 2 and pkg.price = 328.00 and pkg.persons = 2, 'A1: saunotus_2 1–2 hlö, 328 € kahdelle');
  perform pg_temp.ck((select max_persons from booking.gift_card_packages where code = 'sauna_treatment_2') = 4
    and (select max_persons from booking.gift_card_packages where code = 'entry_2') = 6, 'A2: muiden pakettien rajat ennallaan');
  perform pg_temp.ck((select (e ->> 'max_persons')::int from jsonb_array_elements(booking.public_gift_card_packages() -> 'packages') e where e ->> 'code' = 'saunotus_2') = 2, 'B1: julkinen pakettilista max 2');
  perform pg_temp.ck((booking._gc_quote(pkg, '{"persons":2}'::jsonb) ->> 'amount')::numeric = 328, 'C1: 2 hlö = 328 €');
  perform pg_temp.ck((booking._gc_quote(pkg, '{"persons":1}'::jsonb) ->> 'amount')::numeric = 239, 'C2: 1 hlö = 239 €');
  v_ok := false;
  begin
    perform booking._gc_quote(pkg, '{"persons":3}'::jsonb);
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_code = pg_exception_detail; v_ok := v_code = 'invalid_persons';
  end;
  perform pg_temp.ck(v_ok, 'C3: 3 hlö hylätään (invalid_persons)');
  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t211_r where ok), (select count(*) from t211_r where not ok),
    coalesce((select string_agg(label, ' | ') from t211_r where not ok), 'ALL OK');
end
$t$;
