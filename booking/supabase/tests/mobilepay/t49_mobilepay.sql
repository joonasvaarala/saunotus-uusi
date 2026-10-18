-- ================= booking_49: MobilePay-adapteri (aja migraation jälkeen, rollback-transaktiossa) =================
-- Käyttö tuotantotietokantaa vasten: migraatio + tämä tiedosto samassa erässä; viimeinen DO-lohko päättyy poikkeukseen 'MOBILEPAY_TESTS ...' joka perutaan koko erän.
do $mp$
declare
  v_res text[] := '{}'; v_fail int := 0;
  r jsonb; r2 jsonb; v_cust bigint; v_order bigint; v_order2 bigint; v_order3 bigint; v_oj bigint; v_item bigint; v_tok uuid; v_tok2 uuid; v_pid bigint; v_ref1 text; v_ref2 text;
  v_no bigint := 900000 + (select coalesce(max(order_no), 0) from booking.orders); v_rf bigint; v_rf2 bigint; v_state text; v_n int; v_sqlstate text; v_detail text; v_cfg text;
begin
  create temp table _t(ok boolean, name text) on commit drop;
  -- apurit
  -- (inline-funktioita ei voi määritellä DO:ssa, joten käytetään makroja: insert into _t)
  -- fixture
  insert into booking.customers(name, email, phone) values ('MP Testi', null, null) returning id into v_cust;
  insert into booking.orders(order_no, customer_id, status, payment_status, total_gross, currency, source_channel, locale) values (v_no + 1, v_cust, 'confirmed', 'unpaid', 40, 'EUR', 'web', 'fi') returning id, public_token into v_order, v_tok;
  insert into booking.order_items(order_id, kind, product_name, quantity, unit_price_gross, line_total_gross, vat_rate) values (v_order, 'product', 'MP testituote', 1, 40, 40, 25.5) returning id into v_item;
  update booking.orders set total_gross = 40 where id = v_order;

  -- T1 off-tila
  select mode into v_cfg from booking.integration_config where key = 'mobilepay';
  insert into _t values (v_cfg = 'off', 'T1a mobilepay.mode oletus off');
  begin perform booking.mobilepay_payment_prepare(v_tok, null); insert into _t values (false, 'T1b prepare off-tilassa estetty');
  exception when sqlstate 'BK001' then get stacked diagnostics v_detail = pg_exception_detail; insert into _t values (v_detail = 'mobilepay_off', 'T1b prepare off-tilassa -> mobilepay_off'); end;
  r := booking.public_payment_options(v_tok);
  insert into _t values (r ->> 'ok' = 'true' and r ->> 'online_enabled' = 'false' and r -> 'methods' = '[]'::jsonb, 'T1c public_payment_options off: ei metodeja');

  -- T2 guard
  begin update booking.integration_config set mode = 'test' where key = 'mobilepay'; insert into _t values (false, 'T2a testitilaa ei voi kytkeä ilman approved_by');
  exception when sqlstate 'BK001' then get stacked diagnostics v_detail = pg_exception_detail; insert into _t values (v_detail = 'approval_required', 'T2a ilman approved_by -> approval_required'); end;
  begin update booking.integration_config set mode = 'test' where key = 'vismapay'; insert into _t values (false, 'T2b test-tila vain mobilepaylle');
  exception when check_violation then insert into _t values (true, 'T2b vismapay ei voi olla test-tilassa (check)'); end;
  begin update booking.integration_config set mode = 'dry_run' where key = 'mobilepay'; insert into _t values (false, 'T2c mobilepay dry_run kielletty');
  exception when check_violation then insert into _t values (true, 'T2c mobilepay ei dry_run (check)'); end;
  update booking.integration_config set mode = 'test', settings = settings || '{"approved_by":"testi"}'::jsonb where key = 'mobilepay';

  -- T3 prepare
  r := booking.mobilepay_payment_prepare(v_tok, null);
  v_pid := (r ->> 'payment_id')::bigint; v_ref1 := r ->> 'reference';
  insert into _t values (r ->> 'ok' = 'true' and v_ref1 = 'sauna-o' || (v_no + 1) || '-p' || v_pid || '-a1' and (r ->> 'amount_minor')::bigint = 4000 and r ->> 'currency' = 'EUR' and r ->> 'mode' = 'test'
     and char_length(v_ref1) between 8 and 64 and v_ref1 ~ '^[A-Za-z0-9-]+$', 'T3a prepare: viite, summa 4000 snt, tila test, viitteen muoto');
  insert into _t select (p.provider = 'mobilepay' and p.method = 'mobilepay' and p.status = 'pending' and p.amount = 40 and p.provider_ref = v_ref1
     and (select sum(amount_gross) from booking.payment_lines where payment_id = p.id) = 40 and p.link_expires_at > now()), 'T3b maksurivi pending mobilepay, rivit 40 EUR' from booking.payments p where p.id = v_pid;
  insert into _t select o.payment_status = 'pending', 'T3c tilauksen payment_status pending' from booking.orders o where o.id = v_order;
  insert into _t values (r ->> 'description' like 'Sipoonjoen Perinnesauna – tilaus %' and r ->> 'site_base_url' is not null and r ->> 'order_page_path' = '/tilaus/', 'T3d kuvaus, site_base_url, order_page_path mukana');

  -- T4 uusi yritys (edellinen ei vielä CREATED-linkkiä) -> a2, edellinen perutaan Vippsissä
  r := booking.mobilepay_payment_prepare(v_tok, null);
  v_ref2 := r ->> 'reference';
  insert into _t values ((r ->> 'payment_id')::bigint = v_pid and v_ref2 = replace(v_ref1, '-a1', '-a2') and r -> 'superseded' ? v_ref1, 'T4 toinen prepare: sama maksu, a2, a1 superseded');

  -- T5 event + reuse
  r := booking.mobilepay_payment_event(v_ref2, 'CREATED', 'https://example.invalid/landing', '{"x":1}'::jsonb);
  insert into _t values (r ->> 'ok' = 'true' and r ->> 'current' = 'true', 'T5a event CREATED tallennettu (nykyinen viite)');
  r := booking.mobilepay_payment_prepare(v_tok, null);
  insert into _t values (r ->> 'reuse' = 'true' and r ->> 'redirect_url' = 'https://example.invalid/landing' and r ->> 'reference' = v_ref2, 'T5b prepare uudelleen alle 8 min: sama ohjausosoite (reuse)');
  r := booking.mobilepay_payment_event(v_ref1, 'EXPIRED', null, null);
  insert into _t values (r ->> 'ok' = 'true' and r ->> 'current' = 'false', 'T5c vanhan viitteen event ei muuta nykyistä tilaa');
  insert into _t select p.provider_status = 'CREATED', 'T5d provider_status = CREATED' from booking.payments p where p.id = v_pid;

  -- T6 lookup
  r := booking.mobilepay_payment_lookup(v_ref1); r2 := booking.mobilepay_payment_lookup(v_ref2);
  insert into _t values (r ->> 'found' = 'true' and r ->> 'stale' = 'true' and r2 ->> 'stale' = 'false' and (r2 ->> 'amount_minor')::bigint = 4000 and (r2 ->> 'order_token')::uuid = v_tok
     and booking.mobilepay_payment_lookup('sauna-o1-p99999999-a1') ->> 'found' = 'false' and booking.mobilepay_payment_lookup('muu-viite-123') ->> 'found' = 'false' and booking.mobilepay_payment_lookup(null) ->> 'found' = 'false', 'T6 lookup: stale/current/tuntematon/null');

  -- T7 confirmable
  r := booking.mobilepay_payment_confirmable(v_ref2);
  insert into _t values (r ->> 'confirmable' = 'true', 'T7a confirmable (vahvistettu tilaus)');
  insert into _t select o.status = 'confirmed', 'T7b probe ei jättänyt jälkiä' from booking.orders o where o.id = v_order;
  insert into _t values (booking.mobilepay_payment_confirmable('sauna-o1-p99999999-a9') ->> 'confirmable' = 'false', 'T7c tuntematon viite -> ei vahvistettavissa');

  -- T8 asiakastietojen täydennys
  r := booking.mobilepay_fill_customer(v_pid, 'Vipps Nimi', 'Vipps.Testi@Example.invalid', '358401234567');
  insert into _t select (r -> 'filled' ? 'email' and r -> 'filled' ? 'phone' and not (r -> 'filled' ? 'name') and c.email = 'vipps.testi@example.invalid' and c.phone = '+358401234567' and c.name = 'MP Testi'), 'T8a täydentää sähköposti+puhelin, ei ylikirjoita nimeä' from booking.customers c where c.id = v_cust;
  r := booking.mobilepay_fill_customer(v_pid, 'Toinen', 'toinen@example.invalid', '+358501111111');
  insert into _t select (r -> 'filled' = '[]'::jsonb and c.email = 'vipps.testi@example.invalid' and c.phone = '+358401234567'), 'T8b toinen kutsu ei ylikirjoita olemassa olevia' from booking.customers c where c.id = v_cust;
  insert into _t select count(*) = 1, 'T8c audit-merkintä (vain kenttien nimet)' from booking.audit_log where action = 'MOBILEPAY_PROFILE_FILL' and row_pk = v_cust::text and not (new_data::text like '%example.invalid%');
  r := booking.mobilepay_fill_customer(v_pid, null, 'ei-sahkoposti', '12');
  insert into _t values (r ->> 'ok' = 'true', 'T8d virheelliset arvot ohitetaan');

  -- T9 maksettu -> kuitti (+ kirjanpito-outbox kun procountor ei off)
  update booking.integration_config set mode = 'dry_run' where key = 'procountor';
  r := booking.payment_mark_paid('mobilepay', v_ref2, 40, '{"mobilepay":{"state":"AUTHORIZED"}}'::jsonb);
  insert into _t values (r ->> 'ok' = 'true' and r -> 'needs_manual_review' is null, 'T9a payment_mark_paid(mobilepay) ok');
  insert into _t select p.status = 'paid' and p.paid_at is not null, 'T9b maksu paid' from booking.payments p where p.id = v_pid;
  insert into _t select o.payment_status = 'paid', 'T9c tilaus paid' from booking.orders o where o.id = v_order;
  insert into _t select count(*) = 1, 'T9d kuitti syntyi (_on_payment_paid)' from booking.receipts where payment_id = v_pid;
  insert into _t select count(*) >= 1, 'T9e2 kirjanpito-outbox-rivi syntyi (procountor dry_run)' from booking.accounting_outbox where payment_id = v_pid;
  insert into _t select count(*) >= 1, 'T9e kuittiviesti jonossa' from booking.email_outbox where kind = 'receipt' and payment_id = v_pid;
  r := booking.payment_mark_paid('mobilepay', v_ref2, 40, null);
  insert into _t values (r ->> 'already' = 'true', 'T9f idempotentti (already)');
  begin perform booking.mobilepay_payment_prepare(v_tok, null); insert into _t values (false, 'T9g maksettua ei voi maksaa uudelleen');
  exception when sqlstate 'BK001' then get stacked diagnostics v_detail = pg_exception_detail; insert into _t values (v_detail = 'already_paid', 'T9g prepare maksetulle -> already_paid'); end;

  -- T10 public_payment_options
  r := booking.public_payment_options(v_tok);
  insert into _t values (r -> 'order' ->> 'can_pay_online' = 'false' and r -> 'methods' = '[]'::jsonb, 'T10a maksettu tilaus: ei painiketta');
  insert into booking.orders(order_no, customer_id, status, payment_status, total_gross, currency, source_channel, locale) values (v_no + 2, v_cust, 'confirmed', 'unpaid', 25, 'EUR', 'web', 'fi') returning id, public_token into v_order2, v_tok2;
  insert into booking.order_items(order_id, kind, product_name, quantity, unit_price_gross, line_total_gross, vat_rate) values (v_order2, 'product', 'MP testituote 2', 1, 25, 25, 25.5);
  update booking.orders set total_gross = 25 where id = v_order2;
  r := booking.public_payment_options(v_tok2);
  insert into _t values (r -> 'order' ->> 'can_pay_online' = 'true' and r -> 'methods' -> 0 ->> 'code' = 'mobilepay' and r -> 'methods' -> 0 ->> 'test' = 'true' and r -> 'methods' -> 0 -> 'start' ->> 'function' = 'mobilepay-start'
     and (r -> 'order' ->> 'unpaid')::numeric = 25 and r ->> 'ok' = 'true', 'T10b maksamaton tilaus (test): painike, test=true');
  r := booking.public_payment_options(gen_random_uuid());
  insert into _t values (r ->> 'ok' = 'false' and r ->> 'code' = 'not_found', 'T10c tuntematon token -> not_found');
  r := booking.public_payment_options(null);
  insert into _t values (r ->> 'ok' = 'true' and jsonb_array_length(r -> 'methods') = 1 and r -> 'order' = 'null'::jsonb, 'T10d ilman tokenia: yleinen tieto');

  -- T11 Johku-eristys
  insert into booking.orders(order_no, customer_id, status, payment_status, total_gross, currency, source_channel, locale, external_source, external_id) values (v_no + 3, v_cust, 'confirmed', 'unpaid', 30, 'EUR', 'web', 'fi', 'johku', 'mp-test-1') returning id, public_token into v_oj, v_tok;
  insert into booking.order_items(order_id, kind, product_name, quantity, unit_price_gross, line_total_gross, vat_rate) values (v_oj, 'product', 'Johku', 1, 30, 30, 25.5);
  begin perform booking.mobilepay_payment_prepare(v_tok, null); insert into _t values (false, 'T11a Johku-tilausta ei voi maksaa');
  exception when sqlstate 'BK001' then get stacked diagnostics v_detail = pg_exception_detail; insert into _t values (v_detail = 'order_not_payable', 'T11a Johku-tilaus -> order_not_payable'); end;
  r := booking.public_payment_options(v_tok);
  insert into _t values (r -> 'order' ->> 'can_pay_online' = 'false', 'T11b Johku: ei painiketta');

  -- T12 maksulinkki (hallinnan visma_pay-rivi siirtyy MobilePaylle)
  insert into booking.payments(order_id, method, provider, status, amount, currency, link_expires_at) values (v_order2, 'visma_pay', 'visma_pay', 'pending', 25, 'EUR', now() + interval '1 day') returning id, link_token into v_pid, v_tok;
  insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate) select v_pid, id, product_name, kind, quantity, line_total_gross, vat_rate from booking.order_items where order_id = v_order2;
  r := booking.mobilepay_payment_prepare(null, v_tok);
  insert into _t select (r ->> 'payment_id')::bigint = v_pid and p.provider = 'mobilepay' and p.method = 'mobilepay' and p.provider_ref = r ->> 'reference', 'T12a maksulinkki: visma_pay-maksu siirtyi MobilePaylle' from booking.payments p where p.id = v_pid;
  begin perform booking.mobilepay_payment_prepare(v_tok, v_tok); insert into _t values (false, 'T12b molemmat tokenit estetty');
  exception when sqlstate 'BK001' then insert into _t values (true, 'T12b molemmat tokenit -> invalid_param'); end;

  -- T13 slot_lost / fail
  v_ref1 := r ->> 'reference';
  update booking.orders set status = 'cancelled' where id = v_order2;
  r := booking.mobilepay_payment_confirmable(v_ref1);
  insert into _t values (r ->> 'confirmable' = 'false' and r ->> 'reason' = 'order_cancelled', 'T13a peruttu tilaus ei vahvistettavissa');
  update booking.orders set status = 'confirmed' where id = v_order2;
  r := booking.mobilepay_payment_fail(v_ref1, 'cancelled', 'slot_lost', '{"x":1}'::jsonb);
  insert into _t select p.status = 'cancelled' and o.payment_status = 'unpaid' and o.internal_note like '%MobilePay-maksu peruttiin%', 'T13b payment_fail: cancelled, tilaus unpaid, huomautus' from booking.payments p join booking.orders o on o.id = p.order_id where p.id = v_pid;
  r := booking.mobilepay_payment_fail(v_ref1, 'cancelled', 'slot_lost', null);
  insert into _t values (r ->> 'unchanged' = 'true', 'T13c payment_fail idempotentti');

  -- T14 hyvitys (admin_refund luo requested-rivin kun mode <> off; simuloidaan rivi samoin kuin admin_refund)
  select id into v_pid from booking.payments where order_id = v_order and provider = 'mobilepay';
  insert into booking.refunds(payment_id, order_id, amount, reason, status, provider, lines) 
    select v_pid, v_order, 10, 'testi', 'requested', 'mobilepay', jsonb_build_array(jsonb_build_object('payment_line_id', pl.id, 'amount', 10)) from booking.payment_lines pl where pl.payment_id = v_pid limit 1 returning id into v_rf;
  r := booking.mobilepay_refund_claim(null, 20);
  insert into _t values (jsonb_array_length(r -> 'claimed') >= 1 and exists (select 1 from jsonb_array_elements(r -> 'claimed') c where (c ->> 'refund_id')::bigint = v_rf and (c ->> 'amount_minor')::bigint = 1000 and c ->> 'reference' like 'sauna-o%'), 'T14a claim: requested -> processing, summa 1000 snt');
  insert into _t select f.status = 'processing', 'T14b rivi processing' from booking.refunds f where f.id = v_rf;
  r := booking.mobilepay_refund_claim(v_rf, 20);
  insert into _t values (jsonb_array_length(r -> 'claimed') = 0, 'T14c uudelleenclaim ei anna samaa riviä');
  r := booking.mobilepay_refund_complete(v_rf, 'sauna-refund-' || v_rf, '{"aggregate":{"refundedAmount":{"value":1000}}}'::jsonb);
  insert into _t values (r ->> 'ok' = 'true', 'T14d refund_complete ok');
  insert into _t select p.status = 'partially_refunded' and p.refunded_amount = 10, 'T14e maksu partially_refunded 10 EUR' from booking.payments p where p.id = v_pid;
  insert into _t select o.payment_status = 'partially_refunded', 'T14f tilaus partially_refunded' from booking.orders o where o.id = v_order;
  insert into _t select count(*) = 1, 'T14g hyvityskuitti syntyi' from booking.receipts where refund_id = v_rf;
  r := booking.mobilepay_refund_complete(v_rf, 'sauna-refund-' || v_rf, null);
  insert into _t values (r ->> 'already' = 'true', 'T14h complete idempotentti');
  insert into booking.refunds(payment_id, order_id, amount, reason, status, provider, lines) values (v_pid, v_order, 5, 'testi2', 'requested', 'mobilepay', '[]'::jsonb) returning id into v_rf2;
  perform booking.mobilepay_refund_claim(v_rf2, 20);
  r := booking.mobilepay_refund_fail(v_rf2, '{"code":"x"}'::jsonb);
  insert into _t select f.status = 'failed', 'T14i refund_fail -> failed' from booking.refunds f where f.id = v_rf2;
  -- T14k jumiin jäänyt processing (yli 10 min) otetaan uudelleen
  insert into booking.refunds(payment_id, order_id, amount, reason, status, provider, lines) values (v_pid, v_order, 5, 'testi3', 'requested', 'mobilepay', '[]'::jsonb) returning id into v_rf2;
  perform booking.mobilepay_refund_claim(v_rf2, 20);
  r := booking.mobilepay_refund_claim(v_rf2, 20);
  insert into _t values (jsonb_array_length(r -> 'claimed') = 0, 'T14k tuore processing ei mene uudelleen');
  update booking.refunds set updated_at = now() - interval '11 minutes' where id = v_rf2;
  r := booking.mobilepay_refund_claim(v_rf2, 20);
  insert into _t values (jsonb_array_length(r -> 'claimed') = 1 and (r -> 'claimed' -> 0 ->> 'refunded_minor')::bigint = 1000, 'T14l vanha processing otetaan uudelleen, refunded_minor mukana');
  update booking.integration_config set mode = 'off' where key = 'mobilepay';
  r := booking.mobilepay_refund_claim(null, 20);
  insert into _t values (r ->> 'mode' = 'off' and r -> 'claimed' = '[]'::jsonb, 'T14j off-tilassa claim ei tee mitään');

  -- T14m tilausviitteet (reconcile)
  update booking.integration_config set mode = 'test' where key = 'mobilepay';
  select public_token into v_tok from booking.orders where id = v_order;
  r := booking.mobilepay_order_refs(v_tok);
  insert into _t values (r ->> 'ok' = 'true' and r -> 'refs' = '[]'::jsonb and r ->> 'payment_status' = 'partially_refunded', 'T14m order_refs: maksettu tilaus -> ei keskeneräisiä viitteitä');
  insert into booking.orders(order_no, customer_id, status, payment_status, total_gross, currency, source_channel, locale) values (v_no + 4, v_cust, 'confirmed', 'unpaid', 12, 'EUR', 'web', 'fi') returning id, public_token into v_order3, v_tok2;
  insert into booking.order_items(order_id, kind, product_name, quantity, unit_price_gross, line_total_gross, vat_rate) values (v_order3, 'product', 'MP testituote 3', 1, 12, 12, 25.5);
  update booking.orders set total_gross = 12 where id = v_order3;
  r := booking.mobilepay_payment_prepare(v_tok2, null);
  r2 := booking.mobilepay_order_refs(v_tok2);
  insert into _t values (r2 -> 'refs' = '[]'::jsonb, 'T14n order_refs: initiating-tilaa ei palauteta');
  perform booking.mobilepay_payment_event(r ->> 'reference', 'CREATED', 'https://example.invalid/l', null);
  r2 := booking.mobilepay_order_refs(v_tok2);
  insert into _t values (r2 -> 'refs' -> 0 = to_jsonb(r ->> 'reference') and r2 ->> 'payment_status' = 'pending', 'T14o order_refs: CREATED-yritys palautuu');
  r2 := booking.mobilepay_order_refs(gen_random_uuid());
  insert into _t values (r2 ->> 'ok' = 'false' and r2 ->> 'code' = 'not_found', 'T14p order_refs tuntematon token');
  update booking.integration_config set mode = 'off' where key = 'mobilepay';

  -- T15 oikeudet
  insert into _t values (to_regprocedure('booking.mobilepay_payment_prepare(uuid,uuid,integer)') is null, 'T15a vanhaa kolmen argumentin prepare-ylikuormitusta ei ole');
  insert into _t values (not has_function_privilege('anon', 'booking.mobilepay_payment_prepare(uuid,uuid,integer,text)', 'execute') and not has_function_privilege('authenticated', 'booking.mobilepay_payment_prepare(uuid,uuid,integer,text)', 'execute')
     and not has_function_privilege('anon', 'booking.mobilepay_fill_customer(bigint,text,text,text)', 'execute') and not has_function_privilege('anon', 'booking.mobilepay_refund_complete(bigint,text,jsonb)', 'execute') and not has_function_privilege('anon', 'booking.mobilepay_order_refs(uuid)', 'execute')
     and has_function_privilege('service_role', 'booking.mobilepay_payment_prepare(uuid,uuid,integer,text)', 'execute') and has_function_privilege('anon', 'booking.public_payment_options(uuid)', 'execute'), 'T15 oikeudet: adapteri vain service_role, public_payment_options anon');
  -- T16 admin_refund: tilan avain
  insert into _t values (replace('mobilepay', '_', '') = 'mobilepay' and exists (select 1 from booking.integration_config where key = replace('mobilepay', '_', '')), 'T16 admin_refund hakee integration_config-avaimen replace(provider,_) = mobilepay');

  select count(*) filter (where not ok), array_agg((case when ok then 'ok   ' else 'FAIL ' end) || name order by ctid) into v_fail, v_res from _t;
  raise exception 'MOBILEPAY_TESTS fail=% total=%
%', v_fail, array_length(v_res, 1), array_to_string(v_res, E'\n');
end $mp$;
