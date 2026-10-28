-- t196: lahjakortin henkilömäärä ja saunarituaalipaketti (booking_196).
-- Ajetaan migraatioiden ja fixtures/10_test_helpers.sql:n jälkeen. TESTRESULT pass=N fail=M.
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t196_r(ok boolean, label text) on commit drop;
grant all on t196_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t196_r values (coalesce(p_ok, false), p_label) $$;
do $t$
declare
  v jsonb; g booking.gift_cards; v_before int;
begin
  perform pg_temp.ck((select price from kb.products where id = 7) = 49 and (select price from kb.products where id = 8) = 20, 'A1: rituaali+vuoro 49 €, erillinen Saunotusrituaali 20 €');
  perform pg_temp.ck((select price from kb.products where id = 1) = 29 and (select price_gross from booking.addons where code = 'turvenaamio_jalkakylpy') = 15, 'A2: yleinen vuoro 29 €, turve 15 €');
  perform pg_temp.ck(booking._gc_package_amount((select items from booking.gift_card_packages where code = 'entry_2'), 1) = 29
    and booking._gc_package_amount((select items from booking.gift_card_packages where code = 'entry_2'), 2) = 58
    and booking._gc_package_amount((select items from booking.gift_card_packages where code = 'entry_2'), 3) = 87, 'B1: savusaunavuoro 29 × n');
  perform pg_temp.ck(booking._gc_package_amount((select items from booking.gift_card_packages where code = 'peat_mask_2'), 1) = 44
    and booking._gc_package_amount((select items from booking.gift_card_packages where code = 'peat_mask_2'), 2) = 88, 'B2: turvepaketti 44 × n, kahdelle yhä 88');
  perform pg_temp.ck(booking._gc_package_amount((select items from booking.gift_card_packages where code = 'sauna_treatment_2'), 2) = 192
    and booking._gc_package_amount((select items from booking.gift_card_packages where code = 'sauna_treatment_2'), 1) = 128
    and booking._gc_package_amount((select items from booking.gift_card_packages where code = 'saunotus_2'), 2) = 328, 'B3: hoito ja saunotus kahdelle ennallaan');
  perform pg_temp.ck((select price from booking.gift_card_packages where code = 'saunarituaali_2') = 98
    and booking._gc_package_amount((select items from booking.gift_card_packages where code = 'saunarituaali_2'), 1) = 49
    and booking._gc_package_amount((select items from booking.gift_card_packages where code = 'saunarituaali_2'), 6) = 294
    and (select max_persons from booking.gift_card_packages where code = 'saunarituaali_2') = 6
    and (select max_persons from booking.gift_card_packages where code = 'entry_2') = 6
    and (select max_persons from booking.gift_card_packages where code = 'sauna_treatment_2') = 4
    and (select name from booking.gift_card_packages where code = 'saunarituaali_2') = 'Saunotusrituaali ja yleinen vuoro'
    and (select name from booking.gift_card_packages where code = 'entry_2') not like '%kahdelle%', 'C1: rituaalipaketti ja katot, ei kahdelle-nimeä');
  perform pg_temp.ck((booking._gc_quote((select p from booking.gift_card_packages p where code = 'entry_2'), '{"persons":3}'::jsonb) ->> 'amount')::numeric = 87, 'D1: tarjous 3 hengelle 87 €');
  perform pg_temp.ck((booking._gc_quote((select p from booking.gift_card_packages p where code = 'entry_2'), '{}'::jsonb) ->> 'amount')::numeric = 58, 'D2: ilman henkilömäärää vanha 2 hengen hinta');

  select count(*) into v_before from booking.gift_cards;
  v := booking._gc_sell('[{"package":"entry_2","persons":3,"quantity":1}]'::jsonb, null, 'web', 'fi', 'T196 Ostaja', 't196@example.test', 'confirmed');
  select * into g from booking.gift_cards where id = ((v -> 'cards' -> 0 ->> 'id')::bigint);
  perform pg_temp.ck(g.persons = 3 and g.initial_amount = 87 and g.balance = 0 and g.status = 'pending_payment', 'E1: uusi kortti 3 hlö / 87 €, saldo 0 kunnes maksettu');
  perform pg_temp.ck((select (price_breakdown ->> 'persons')::int from booking.order_items where id = g.purchase_order_item_id) = 3, 'E2: henkilömäärä tilausrivillä');
  perform pg_temp.ck((select count(*) from booking.gift_cards where id <> g.id and persons is not null) = 0 or v_before = 0, 'E3: vanhoille korteille ei kirjoitettu henkilömäärää');
  perform pg_temp.ck((select code from booking.gift_cards where code = 'HH3A7CEFHJKL') is null
    or (select persons is null and initial_amount is not null from booking.gift_cards where code = 'HH3A7CEFHJKL'), 'E4: siemenkortin saldo säilyy eikä persons täyty');

  update booking.gift_cards set pdf_deleted_at = now() where id = g.id;
  v := booking.svc_get_gift_card_pdf_data(g.public_token);
  perform pg_temp.ck(v ->> 'code' = 'not_found' and coalesce(v ->> 'ok', 'false') = 'false', 'F1: pdf_deleted_at → not_found (booking_160)');

  raise exception 'TESTRESULT pass=% fail=% :: %', (select count(*) from t196_r where ok), (select count(*) from t196_r where not ok),
    coalesce((select string_agg(label, ' | ') from t196_r where not ok), 'ALL OK');
end
$t$;
