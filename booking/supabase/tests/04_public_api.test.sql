-- Julkinen rajapinta: validointi, hinnoittelu, rate limit, vuoto, token-haku
begin;
set local search_path = extensions, public;
select no_plan();

select test.next_dow(2) as tue, test.next_dow(3) as wed, test.next_dow(1) as mon,
       test.rule('Naisten sauna%') as r_tue, test.rule('Jälkilöylyt ma–to 19–21%') as r_after,
       test.rule('Miesten sauna%') as r_mon \gset

select p.price as p_tue, p.id as prod_tue from booking.schedule_rules r join kb.products p on p.id = r.product_id where r.id = :r_tue \gset
select test.anon('10.0.0.1');
-- validointi (jokaiselle kutsulle oma sähköposti, ettei sähköpostikohtainen rate limit laukea)
select is(booking.public_create_booking(:r_tue, :'tue', 2, '', 'v1@example.com', '0401234567') ->> 'code', 'invalid_name', 'tyhjä nimi hylätään');
select is(booking.public_create_booking(:r_tue, :'tue', 2, 'A B', 'ei-sahkoposti', '0401234567') ->> 'code', 'invalid_email', 'virheellinen sähköposti hylätään');
select is(booking.public_create_booking(:r_tue, :'tue', 2, 'A B', 'v3@example.com', 'abc') ->> 'code', 'invalid_phone', 'virheellinen puhelin hylätään');
select is(booking.public_create_booking(:r_tue, :'tue', -3, 'A B', 'v4@example.com', '0401234567') ->> 'code', 'invalid_persons', 'negatiivinen henkilömäärä hylätään');
select is(booking.public_create_booking(:r_tue, :'tue', 99, 'A B', 'v4b@example.com', '0401234567') ->> 'code', 'invalid_persons', 'yli 50 henkilöä hylätään');
select is(booking.public_create_booking(999999, :'tue', 2, 'A B', 'v5@example.com', '0401234567') ->> 'code', 'rule_not_found', 'tuntematon sääntö hylätään');
select is(booking.public_create_booking(:r_tue, :'mon', 2, 'A B', 'v6@example.com', '0401234567') ->> 'code', 'no_session', 'väärä viikonpäivä (ei vuoroa) hylätään');
select is(booking.public_create_booking(:r_tue, current_date - 3, 2, 'A B', 'v7@example.com', '0401234567') ->> 'code', 'invalid_date', 'menneisyyteen ei voi varata');
select is(booking.public_create_booking(:r_tue, current_date + 800, 2, 'A B', 'v8@example.com', '0401234567') ->> 'code', 'invalid_date', 'liian kauas tulevaisuuteen ei voi varata (horisontti)');
select is(booking.public_create_booking(:r_tue, :'tue', 2, repeat('x', 500), 'v9@example.com', '0401234567') ->> 'code', 'invalid_name', 'liian pitkä nimi hylätään');
select throws_ok($$select * from booking.public_availability(2, current_date, current_date + 400)$$, 'BK001', null, 'availability-haun enimmäisväli (92 pv)');
select test.logout();
select is((select count(*)::int from booking.customers where email like 'v%@example.com'), 0, 'epäonnistuneet validoinnit eivät luo asiakkaita');
select test.anon('10.0.0.1');

-- onnistunut varaus: hinta (per_person), tilaus, tokenilla haku
select booking.public_create_booking(:r_tue, :'tue', 3, 'Testi Asiakas', 'Testi.Asiakas@Example.com', '+358 40 123 4567', true, 'fi', 'allergia') as res \gset
select is((:'res'::jsonb ->> 'ok')::boolean, true, 'varaus onnistuu');
select is((:'res'::jsonb ->> 'total')::numeric, 3 * :p_tue::numeric, 'hinta = 3 x kb-hinta (per_person)');
select is((:'res'::jsonb ->> 'payment_mode'), 'pay_later', 'oletusmaksutila pay_later');
select is((:'res'::jsonb ->> 'status'), 'confirmed', 'pay_later => confirmed');
select (:'res'::jsonb ->> 'token') as tok \gset
select is(booking.public_get_booking(:'tok'::uuid) ->> 'first_name', 'Testi', 'token-haku palauttaa etunimen');
select ok(not (booking.public_get_booking(:'tok'::uuid)::text ~* 'example\.com|0401234567|allergia|Asiakas'), 'token-haku ei vuoda sähköpostia, puhelinta, sukunimeä tai muistiinpanoa');
select is(booking.public_get_booking(gen_random_uuid()) ->> 'code', 'not_found', 'tuntematon token => not_found');
select throws_ok('select * from booking.customers', '42501', null, 'anon ei näe asiakasta');
select test.logout();

-- asiakas upsert: sähköposti normalisoituu, marketing consent tallentuu aikaleimalla ja lähteellä
select is((select count(*)::int from booking.customers where email = 'testi.asiakas@example.com'), 1, 'sähköposti normalisoitu pieniksi kirjaimiksi');
select is((select marketing_consent from booking.customers where email = 'testi.asiakas@example.com'), true, 'markkinointisuostumus tallennettu');
select ok((select marketing_consent_at is not null and marketing_consent_source is not null from booking.customers where email = 'testi.asiakas@example.com'), 'suostumuksella aikaleima ja lähde');
select is((select count(*)::int from booking.marketing_consent_events e join booking.customers c on c.id = e.customer_id where c.email = 'testi.asiakas@example.com'), 1, 'suostumustapahtuma kirjattu (lokiin)');
select test.anon('10.0.0.1');
select booking.public_create_booking(:r_tue, (:'tue'::date + 7), 1, 'Testi Asiakas', 'testi.asiakas@example.com', '0401234567', false, 'fi', null);
select test.logout();
select is((select count(*)::int from booking.customers where email = 'testi.asiakas@example.com'), 1, 'sama sähköposti => sama asiakas (ei duplikaattia)');
select is((select marketing_consent from booking.customers where email = 'testi.asiakas@example.com'), true, 'myöhempi varaus ilman ruksia ei peru aiempaa suostumusta');

-- hinnoittelu: fixed_plus_extra
select test.anon('10.0.0.2');
select booking.public_create_booking(:r_after, :'wed', 5, 'Fixed Test', 'fixed@example.com', '0401234567') ->> 'total' as t5 \gset
select booking.public_create_booking(:r_after, (:'wed'::date + 7), 11, 'Fixed Test', 'fixed@example.com', '0401234567') ->> 'total' as t11 \gset
select test.logout();
select is(:t5::numeric, (select price from kb.product_price_variants v join booking.schedule_rules r on r.price_variant_id = v.id where r.id = :r_after), 'jälkilöylyt 5 hlö = perushinta (sisältää enintään 8)');
select ok(:t11::numeric > :t5::numeric, 'jälkilöylyt 11 hlö > perushinta (lisähenkilömaksu)');

-- tilausrivin ALV ja kanava
select is((select vat_rate from booking.order_items oi join booking.orders o on o.id = oi.order_id where o.public_token = :'tok'::uuid), 25.5, 'tilausrivillä ALV 25,5 %');
select is((select source_channel from booking.orders where public_token = :'tok'::uuid), 'web', 'lähdekanava web');

-- hinnan muutos ei muuta vanhaa tilausta (snapshot)
select test.mk_staff('adm@example.com', 'admin') as aid \gset
select test.login(:'aid');
select booking.admin_update_product(:prod_tue, '{"price": 99}');
select test.logout();
select is((select total_gross from booking.orders where public_token = :'tok'::uuid), (:'res'::jsonb ->> 'total')::numeric, 'vanhan tilauksen summa ei muutu hinnanmuutoksessa');

-- peruutus tokenilla: vahvistettua (pay_later) ei voi peruuttaa itse, maksamaton pito voi
select test.anon('10.0.0.4');
select is(booking.public_cancel_booking(:'tok'::uuid) ->> 'code', 'not_cancellable', 'vahvistettua varausta ei voi peruuttaa tokenilla (ohjataan yhteydenottoon)');
select test.logout();
update booking.settings set value = '"hold_until_paid"' where key = 'public_payment_mode';
select test.anon('10.0.0.5');
select (booking.public_create_booking(:r_tue, (:'tue'::date + 14), 1, 'Pito Asiakas', 'pito@example.com', '0401234567') ->> 'token') as tok2 \gset
select is((booking.public_cancel_booking(:'tok2'::uuid) ->> 'ok')::boolean, true, 'maksamattoman pidon voi peruuttaa tokenilla');
select test.logout();
update booking.settings set value = '"pay_later"' where key = 'public_payment_mode';
select is((select status from booking.orders where public_token = :'tok2'::uuid), 'cancelled', 'tilaus peruttu');
select is((select count(*)::int from booking.reservations r join booking.orders o on o.id = r.order_id where o.public_token = :'tok2'::uuid and r.status = 'cancelled'), 1, 'varaus peruttu');

-- rate limit: sama IP, monta yritystä
select test.anon('10.9.9.9');
select ok((select count(*) from generate_series(1, 30) g, lateral (select booking.public_create_booking(:r_mon, :'mon', 1, 'R L', 'rl' || g || '@example.com', '0401234567') ->> 'code' as c) x where x.c = 'rate_limited') > 0, 'rate limit laukeaa yhdeltä IP:ltä');
select test.logout();
select test.anon('10.8.8.8');
select is((booking.public_create_booking(:r_mon, :'mon', 1, 'Toinen Ip', 'toinen@example.com', '0401234567') ->> 'ok')::boolean, true, 'toinen IP ei ole rate limitattu');
select test.logout();
select test.anon('10.7.7.7');
select ok((select count(*) from generate_series(1, 8) g, lateral (select booking.public_create_booking(:r_mon, :'mon', 1, 'R L', 'sama@example.com', '0401234567', false, 'fi', g::text) ->> 'code' as c) x where x.c = 'rate_limited') > 0, 'sähköpostikohtainen rate limit laukeaa (5 / 10 min)');
select test.logout();

select * from finish();
rollback;
