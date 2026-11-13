begin;
-- t284: asiakkaan oma pienennys + automaattinen osahyvitys (booking_284, tilausnäkymä v3 PR 3 / K).
-- Vaatii migraatiot 282–284 + booking_288 (PROD-tila) + fixtures/10_test_helpers.sql. Yksi transaktio; lopuksi rollback.
-- Montonio on mockattu: hyvitysrivi jää requested-tilaan, valmistuminen/epäonnistuminen simuloidaan montonio_refund_complete / montonio_refund_fail -funktioilla.
set local lock_timeout = '3s';
set local statement_timeout = '60s';
create temp table t284_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t284_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.as_(p_user uuid, p_sql text) returns jsonb language plpgsql as $$
declare v jsonb; d text;
begin
  perform test.login(p_user);
  begin execute p_sql into v;
  exception when others then
    get stacked diagnostics d = pg_exception_detail;
    v := jsonb_build_object('err', coalesce(nullif(d, ''), sqlstate), 'msg', sqlerrm);
  end;
  perform test.logout();
  return v;
end $$;
-- asiakkaan (anon) kutsu
create function pg_temp.anon_(p_ip text, p_sql text) returns jsonb language plpgsql as $$
declare v jsonb;
begin
  perform test.anon(p_ip);
  begin execute p_sql into v;
  exception when others then v := jsonb_build_object('err', sqlstate, 'msg', sqlerrm);
  end;
  perform test.logout();
  return v;
end $$;
-- tilaus: n henkilöä, maksettu kokonaan p_method:lla (montonio | card_terminal | partner)
create function pg_temp.mk(p_rule bigint, p_date date, p_persons int, p_email text, p_method text, p_gc numeric default 0, p_code text default null, out o_id bigint, out tok uuid) language plpgsql as $$
declare a jsonb; u uuid; v_unpaid numeric;
begin
  perform test.reset_rl();
  a := test.pub_book(p_rule, p_date, p_persons, p_email);
  if not coalesce((a ->> 'ok')::boolean, false) then raise exception 'pub_book: %', a; end if;
  tok := (a ->> 'token')::uuid; o_id := (test.ord(tok)).id;
  if p_gc > 0 then
    insert into booking.gift_cards(code, initial_amount, balance, valid_to, status) values (p_code, p_gc, p_gc, current_date + 200, 'active');
    perform booking._apply_gift_core(o_id, p_code, 'card_terminal', true, 'Testi');
  end if;
  select (booking._order_balance(o_id) ->> 'unpaid')::numeric into v_unpaid;
  if v_unpaid > 0 then
    select id into u from auth.users where email = 'adm@t284.example';
    perform test.login(u);
    perform booking.admin_record_payment(o_id, case when p_method = 'partner' then 'partner_voucher_elamyslahjat' else 'card_terminal' end, v_unpaid, null, null);
    perform test.logout();
  end if;
  if p_method = 'montonio' then
    update booking.payments set provider = 'montonio', method = 'montonio', raw = '{"order_uuid":"x","env":"test"}'::jsonb where order_id = o_id and method = 'card_terminal' and gift_card_id is null;
  end if;
end $$;
do $t$
declare
  v_rule bigint := test.rule('Miesten sauna%'); v_prod bigint; d date := test.next_dow(1, 20); d_near date := test.next_dow(1, 3);
  u_adm uuid := test.mk_staff('adm@t284.example', 'admin');
  v jsonb; w jsonb; o1 bigint; t1 uuid; o2 bigint; t2 uuid; o3 bigint; t3 uuid; o4 bigint; t4 uuid; o5 bigint; t5 uuid; o6 bigint; t6 uuid; o7 bigint; t7 uuid; o8 bigint; t8 uuid;
  v_ref bigint; v_n int; v_price numeric; v_rule_near bigint;
begin
  select product_id into v_prod from booking.schedule_rules where id = v_rule;
  update booking.settings set value = '200'::jsonb where key = 'public_treatment_global_per_hour';
  update booking.settings set value = 'true'::jsonb where key = 'gift_cards.redeem_enabled';
  update booking.settings set value = '1000'::jsonb where key in ('rl_change_per_10min', 'rl_ip_per_10min', 'rl_email_per_10min');
  update booking.integration_config set mode = 'test', settings = settings || '{"approved_by":"testi"}'::jsonb where key = 'montonio';
  perform pg_temp.ck(not booking._flag_on('customer_auto_partial_refund_enabled') and not booking._flag_on('partial_refunds_enabled'), 'L0: liput oletuksena pois');
  perform pg_temp.ck((select value from booking.settings where key = 'customer_reduce_full_refund_days_private') = '14'::jsonb, 'L0b: private-raja 14 vrk');
  select r.id, r.id into v_rule_near from booking.schedule_rules r where r.id = v_rule;
  update booking.product_config set cancellation_tier = 'general' where product_id = v_prod;

  -- ===== liput pois: vanha käytös =====
  select * into o1, t1 from pg_temp.mk(v_rule, d, 3, 'a@t284.example', 'montonio');
  v := pg_temp.anon_('10.4.0.1', format('select booking.public_change_preview(%L, null, null, 2)', t1));
  perform pg_temp.ck((v ->> 'ok')::boolean and (v -> 'auto_refund' ->> 'enabled')::boolean is false and v -> 'auto_refund' ->> 'reason' = 'feature_disabled', 'A1: liput pois → esikatselu: ei käytössä ' || v::text);
  v := pg_temp.anon_('10.4.0.1', format('select booking.public_change_booking(%L, null, null, 2)', t1));
  perform pg_temp.ck(v ->> 'code' = 'price_change_requires_staff' and (select persons from booking.reservations where order_id = o1) = 3, 'A2: liput pois → price_change_requires_staff, ei muutosta ' || v::text);
  update booking.settings set value = 'true'::jsonb where key = 'customer_auto_partial_refund_enabled';
  v := pg_temp.anon_('10.4.0.1', format('select booking.public_change_preview(%L, null, null, 2)', t1));
  perform pg_temp.ck(v -> 'auto_refund' ->> 'reason' = 'feature_disabled', 'A3: pelkkä asiakaslippu ei riitä (hallinnan lippu vaaditaan)');
  update booking.settings set value = 'true'::jsonb where key = 'partial_refunds_enabled';

  -- ===== käyttöön: esikatselu + vahvistus =====
  v := pg_temp.anon_('10.4.0.1', format('select booking.public_change_preview(%L, null, null, 2)', t1));
  perform pg_temp.ck((v -> 'auto_refund' ->> 'allowed')::boolean and (v -> 'auto_refund' ->> 'amount')::numeric = 29 and (v ->> 'new_total')::numeric = 58 and not (v ->> 'price_up')::boolean, 'B1: esikatselu: uusi hinta 58, hyvitys 29 ' || v::text);
  perform pg_temp.ck((select persons from booking.reservations where order_id = o1) = 3 and not exists (select 1 from booking.refunds where order_id = o1), 'B1b: esikatselu ei muuta mitään');
  v := pg_temp.anon_('10.4.0.1', format('select booking.public_change_booking(%L, null, null, 2)', t1));
  perform pg_temp.ck(v ->> 'code' = 'refund_confirmation_required' and (v ->> 'refund_amount')::numeric = 29, 'B2: ilman vahvistettua hyvitystä ei tehdä ' || v::text);
  v := pg_temp.anon_('10.4.0.1', format('select booking.public_change_booking(%L, null, null, 2, 28)', t1));
  perform pg_temp.ck(v ->> 'code' = 'refund_confirmation_required' and (select persons from booking.reservations where order_id = o1) = 3, 'B3: väärä summa → ei tehdä');
  v := pg_temp.anon_('10.4.0.1', format('select booking.public_change_booking(%L, null, null, 2, 29)', t1));
  perform pg_temp.ck((v ->> 'ok')::boolean and (v ->> 'refund_amount')::numeric = 29 and (v ->> 'total')::numeric = 58, 'B4: pienennys tehty ' || v::text);
  select id into v_ref from booking.refunds where order_id = o1;
  perform pg_temp.ck((select count(*) from booking.refunds where order_id = o1) = 1 and (select amount from booking.refunds where id = v_ref) = 29 and (select status from booking.refunds where id = v_ref) = 'requested'
                     and (select provider from booking.refunds where id = v_ref) = 'montonio' and (select created_by from booking.refunds where id = v_ref) is null and (select reason from booking.refunds where id = v_ref) = 'customer_reduce', 'B5: hyvitysrivi requested / montonio / created_by null / customer_reduce');
  perform pg_temp.ck(exists (select 1 from booking.audit_log where action = 'CUSTOMER_REDUCE_REFUND' and row_pk = o1::text) and exists (select 1 from booking.email_outbox where order_id = o1 and kind = 'order_change' and payload ->> 'source' = 'customer_reduce'), 'B6: audit + order_change-viesti');
  perform pg_temp.ck((select sum((x ->> 'amount')::numeric) from booking.refunds f, jsonb_array_elements(f.lines) x where f.order_id = o1) = 29, 'B7: rivikohdistus = hyvitys');
  -- idempotenssi: sama pyyntö uudelleen (tuplaklikkaus) ei hyvitä kahdesti
  v := pg_temp.anon_('10.4.0.1', format('select booking.public_change_booking(%L, null, null, 2, 29)', t1));
  perform pg_temp.ck((v ->> 'ok')::boolean and (select count(*) from booking.refunds where order_id = o1) = 1 and v ->> 'refund_amount' is null, 'B8: idempotenssi: toisto ei luo toista hyvitystä ' || v::text);
  -- jäähtymisaika: toinen pienennys heti → ohjataan henkilökunnalle
  v := pg_temp.anon_('10.4.0.1', format('select booking.public_change_preview(%L, null, null, 1)', t1));
  perform pg_temp.ck(v -> 'auto_refund' ->> 'reason' = 'cooldown', 'C1: heti toinen pienennys → jäähtymisaika (käsittelyssä oleva hyvitys huomioitu rahavarassa) ' || v::text);
  -- Montonio vahvistaa → kuitti, sitten jäähtymisaika
  perform booking.montonio_refund_complete(v_ref, 'prov-284-1', null);
  perform pg_temp.ck((select status from booking.refunds where id = v_ref) = 'done' and (select refunded_amount from booking.payments where order_id = o1 and provider = 'montonio') = 29, 'C2: Montonio vahvisti: hyvitetty 29');
  v := pg_temp.anon_('10.4.0.1', format('select booking.public_change_preview(%L, null, null, 1)', t1));
  perform pg_temp.ck(v -> 'auto_refund' ->> 'reason' = 'cooldown', 'C3: enintään 1 pienennys / tunti ' || v::text);
  update booking.audit_log set at = now() - interval '2 hours' where action = 'CUSTOMER_REDUCE_REFUND' and row_pk = o1::text;
  v := pg_temp.anon_('10.4.0.1', format('select booking.public_change_booking(%L, null, null, 1, 29)', t1));
  perform pg_temp.ck((v ->> 'ok')::boolean and (select sum(amount) from booking.refunds where order_id = o1) = 58 and (select amount from booking.payments where order_id = o1 and provider = 'montonio') = 87, 'C4: tunnin jälkeen uusi pienennys; hyvitetty yhteensä 58 ≤ maksettu 87');
  v := pg_temp.anon_('10.4.0.1', format('select booking.public_change_booking(%L, null, null, 3, 0)', t1));
  perform pg_temp.ck(v ->> 'code' = 'price_change_requires_staff', 'C5: hinnan nousu ennallaan (henkilökunnalle) ' || v::text);

  -- ===== REJECTED → epäonnistunut hyvitys: raha ei lähde, ylisuoritus jää hallinnan hyvitettäväksi =====
  select id into v_ref from booking.refunds where order_id = o1 and status = 'requested';
  perform booking.montonio_refund_fail(v_ref, '{"status":"REJECTED"}'::jsonb);
  perform pg_temp.ck((select status from booking.refunds where id = v_ref) = 'failed' and (booking._order_refund_info(o1) ->> 'refundable_max')::numeric = 29, 'D1: REJECTED → failed; 29 € hyvitettävissä hallinnasta');

  -- ===== ehtorajat =====
  update booking.product_config set cancellation_tier = null where product_id = v_prod;
  select * into o2, t2 from pg_temp.mk(v_rule, d + 7, 3, 'b@t284.example', 'montonio');
  v := pg_temp.anon_('10.4.0.2', format('select booking.public_change_preview(%L, null, null, 2)', t2));
  perform pg_temp.ck(v -> 'auto_refund' ->> 'reason' = 'not_classified', 'E1: luokittelematon tuote → henkilökunnalle ' || v::text);
  v := pg_temp.anon_('10.4.0.2', format('select booking.public_change_booking(%L, null, null, 2, 29)', t2));
  perform pg_temp.ck(v ->> 'code' = 'price_change_requires_staff' and v ->> 'reduce_reason' = 'not_classified' and (select count(*) from booking.refunds where order_id = o2) = 0, 'E2: luokittelematon → ei muutosta eikä hyvitystä');
  -- yleinen vuoro: alle 48 h → core estää; yli → ok
  update booking.product_config set cancellation_tier = 'general' where product_id = v_prod;
  select * into o3, t3 from pg_temp.mk(v_rule, d_near, 3, 'c@t284.example', 'montonio');
  v := pg_temp.anon_('10.4.0.3', format('select booking.public_change_preview(%L, null, null, 2)', t3));
  perform pg_temp.ck((v -> 'auto_refund' ->> 'allowed')::boolean, 'F1: yleinen vuoro ≥ 48 h → sallittu (alkuun ' || (select (starts_at - now())::text from booking.reservations where order_id = o3) || ')');
  update booking.reservations set starts_at = now() + interval '40 hours', ends_at = now() + interval '41 hours' where order_id = o3;
  v := pg_temp.anon_('10.4.0.3', format('select booking.public_change_preview(%L, null, null, 2)', t3));
  perform pg_temp.ck(v -> 'auto_refund' ->> 'reason' = 'too_late', 'F2: yleinen vuoro < 48 h → estetty ' || v::text);
  v := pg_temp.anon_('10.4.0.3', format('select booking.public_change_booking(%L, null, null, 2, 29)', t3));
  perform pg_temp.ck(v ->> 'code' = 'price_change_requires_staff' and (select count(*) from booking.refunds where order_id = o3) = 0, 'F3: < 48 h → ei muutosta');
  -- yksityis-/tapahtumaryhmä: 14 vrk
  update booking.product_config set cancellation_tier = 'private_event' where product_id = v_prod;
  select * into o4, t4 from pg_temp.mk(v_rule, d_near, 3, 'd@t284.example', 'montonio');
  update booking.reservations set starts_at = now() + interval '13 days', ends_at = now() + interval '13 days 1 hour' where order_id = o4;
  v := pg_temp.anon_('10.4.0.4', format('select booking.public_change_preview(%L, null, null, 2)', t4));
  perform pg_temp.ck(v -> 'auto_refund' ->> 'reason' = 'too_late_private', 'G1: private_event 13 vrk → estetty (50 % -porras henkilökunnalle) ' || v::text);
  update booking.reservations set starts_at = now() + interval '15 days', ends_at = now() + interval '15 days 1 hour' where order_id = o4;
  v := pg_temp.anon_('10.4.0.4', format('select booking.public_change_preview(%L, null, null, 2)', t4));
  perform pg_temp.ck((v -> 'auto_refund' ->> 'allowed')::boolean, 'G2: private_event 15 vrk → sallittu ' || v::text);
  update booking.reservations set starts_at = now() + interval '14 days' + interval '1 minute', ends_at = now() + interval '14 days 1 hour' where order_id = o4;
  v := pg_temp.anon_('10.4.0.4', format('select booking.public_change_preview(%L, null, null, 2)', t4));
  perform pg_temp.ck((v -> 'auto_refund' ->> 'allowed')::boolean, 'G3: private_event 14 vrk + 1 min → sallittu (raja ≥ 14 vrk)');
  update booking.reservations set starts_at = now() + interval '14 days' - interval '1 minute', ends_at = now() + interval '14 days 1 hour' where order_id = o4;
  v := pg_temp.anon_('10.4.0.4', format('select booking.public_change_preview(%L, null, null, 2)', t4));
  perform pg_temp.ck(v -> 'auto_refund' ->> 'reason' = 'too_late_private', 'G4: private_event 14 vrk - 1 min → estetty');
  update booking.product_config set cancellation_tier = 'general' where product_id = v_prod;

  -- ===== maksutavat =====
  select * into o5, t5 from pg_temp.mk(v_rule, d + 14, 3, 'e@t284.example', 'card_terminal');
  v := pg_temp.anon_('10.4.0.5', format('select booking.public_change_preview(%L, null, null, 2)', t5));
  perform pg_temp.ck(v -> 'auto_refund' ->> 'reason' = 'payment_method', 'H1: käteinen/pääte → estetty ' || v::text);
  select * into o6, t6 from pg_temp.mk(v_rule, d + 21, 3, 'f@t284.example', 'montonio', 20, 'HHGCAAA28401');
  v := pg_temp.anon_('10.4.0.6', format('select booking.public_change_preview(%L, null, null, 2)', t6));
  perform pg_temp.ck(v -> 'auto_refund' ->> 'reason' = 'payment_method', 'H2: lahjakortti + Montonio → estetty (lahjakorttiosuutta ei hyvitetä automaattisesti)');
  select * into o7, t7 from pg_temp.mk(v_rule, d + 28, 3, 'g@t284.example', 'partner');
  v := pg_temp.anon_('10.4.0.7', format('select booking.public_change_preview(%L, null, null, 2)', t7));
  perform pg_temp.ck(v -> 'auto_refund' ->> 'reason' = 'payment_method', 'H3: kumppanikoodi → estetty');
  v := pg_temp.anon_('10.4.0.7', format('select booking.public_change_booking(%L, null, null, 2, 29)', t7));
  perform pg_temp.ck(v ->> 'code' = 'price_change_requires_staff' and (select persons from booking.reservations where order_id = o7) = 3 and not exists (select 1 from booking.refunds where order_id = o7), 'H4: estetty → ei muutosta, ei hyvitystä');
  -- laskulukko
  select * into o8, t8 from pg_temp.mk(v_rule, d + 35, 3, 'h@t284.example', 'montonio');
  insert into booking.invoice_customers(company_name) values ('T284 Oy');
  insert into booking.invoices(order_id, customer_id, kind, status, due_date, seller_snapshot, customer_snapshot) select o8, (select max(id) from booking.invoice_customers), 'debit', 'sent', current_date + 14, '{}'::jsonb, '{}'::jsonb;
  v := pg_temp.anon_('10.4.0.8', format('select booking.public_change_preview(%L, null, null, 2)', t8));
  perform pg_temp.ck(v -> 'auto_refund' = 'null'::jsonb, 'I1: laskulukko → esikatselussa ei hintamuutosta/hyvitystä ' || v::text);
  v := pg_temp.anon_('10.4.0.8', format('select booking.public_change_booking(%L, null, null, 2, 29)', t8));
  perform pg_temp.ck(v ->> 'code' = 'order_invoiced' and (select persons from booking.reservations where order_id = o8) = 3 and not exists (select 1 from booking.refunds where order_id = o8), 'I2: laskulukko → muutos ja hyvitys estetty (order_invoiced) ' || v::text);
  -- minimi 0,05 €
  update kb.products set price = 0.04 where id = v_prod;
  select * into o8, t8 from pg_temp.mk(v_rule, d + 42, 2, 'i@t284.example', 'montonio');
  v := pg_temp.anon_('10.4.0.9', format('select booking.public_change_preview(%L, null, null, 1)', t8));
  perform pg_temp.ck(v -> 'auto_refund' ->> 'reason' = 'refund_too_small', 'J1: hyvitys < 0,05 € → estetty ' || v::text);

  -- ===== rate limit =====
  update booking.settings set value = '2'::jsonb where key = 'rl_change_per_10min';
  perform test.reset_rl();
  v := pg_temp.anon_('10.4.0.10', format('select booking.public_change_preview(%L, null, null, 1)', t5));
  v := pg_temp.anon_('10.4.0.10', format('select booking.public_change_preview(%L, null, null, 1)', t5));
  v := pg_temp.anon_('10.4.0.10', format('select booking.public_change_preview(%L, null, null, 1)', t5));
  perform pg_temp.ck(v ->> 'code' = 'rate_limited', 'R1: esikatselun rate limit ' || v::text);
  v := pg_temp.anon_('10.4.0.11', format('select booking.public_change_booking(%L, null, null, 1, 0)', t5));
  v := pg_temp.anon_('10.4.0.11', format('select booking.public_change_booking(%L, null, null, 1, 0)', t5));
  v := pg_temp.anon_('10.4.0.11', format('select booking.public_change_booking(%L, null, null, 1, 0)', t5));
  perform pg_temp.ck(v ->> 'code' = 'rate_limited', 'R2: muutoksen rate limit');
  update booking.settings set value = '1000'::jsonb where key = 'rl_change_per_10min';

  -- ===== lippu pois → estetty =====
  update booking.settings set value = 'false'::jsonb where key = 'customer_auto_partial_refund_enabled';
  perform test.reset_rl();
  select * into o2, t2 from pg_temp.mk(v_rule, d + 49, 3, 'j@t284.example', 'montonio');
  v := pg_temp.anon_('10.4.0.12', format('select booking.public_change_booking(%L, null, null, 2, 29)', t2));
  perform pg_temp.ck(v ->> 'code' = 'price_change_requires_staff' and v ->> 'reduce_reason' = 'feature_disabled' and not exists (select 1 from booking.refunds where order_id = o2), 'Z1: lippu pois → estetty, ei hyvitystä');
end $t$;
select 'RESULT ' || case when ok then 'ok' else 'NOT OK' end || ' - ' || label from t284_r;
select 'SUMMARY ' || count(*) filter (where not ok) || ' failed / ' || count(*) from t284_r;
rollback;
