-- booking_185: laskutuslukko.
-- Ajo: migraation ja booking/supabase/tests/fixtures/10_test_helpers.sql:n JÄLKEEN (PG17, Tapio-dev).
-- Repon fixture on sama tiedosto kuin Tapio-devin 10_test_helpers.sql (md5 0458821cff5d672d80443d66b01f0d5f); sitä ei muuteta.
-- Tämä skripti korvaa test.pub_bookin: jaettu apuri jättää verkkomaksun pidon pending-tilaan, testi vahvistaa tilauksen.
-- Asettaa booking_horizon_days = 400 ja public_treatment_horizon_days = 150, lisää invoice_counters-sarjan L jos se puuttuu,
-- ja lähettää laskut sähköpostilla (admin_send_invoice: verkkolasku pois, sähköposti päälle). Lahjakortin koodi alkaa HH.
-- Hoitojen saatavuusikkuna on 13 vuorokautta (funktio rajaa 14).
-- Yksi transaktio, kaikki testivaraukset kumoutuvat lopussa.
-- Tapio-dev PG17, edellinen t185: pass=94 fail=5. Tämä versio korjaa ne viisi odotusta. Ei ajettu uudelleen tästä työtilasta.
-- Tapaus 19: t180_addons_paid_guard.sql, t182_order_reservation_addons.sql ja t184_paylink_no_deadline.sql
-- ajetaan ERIKSEEN migraation jälkeen. Niillä on oma BEGIN/ROLLBACK, joten niitä ei upoteta tähän.
-- "Veloitus ennallaan" = order_items (to_jsonb ilman updated_at), orders.total_gross, payments
-- (id, status, amount, refunded_amount, link_token, link_expires_at; payments-taulussa ei ole amount_gross-saraketta),
-- payment_lines, refunds, invoices ja invoice_lines.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create temp table t185_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  insert into t185_r values (coalesce(p_ok, false), p_label)
$$;
create function pg_temp.as_(p_user uuid, p_sql text) returns jsonb language plpgsql as $$
declare v jsonb; d text;
begin
  perform test.login(p_user);
  begin
    execute p_sql into v;
  exception when others then
    get stacked diagnostics d = pg_exception_detail;
    v := jsonb_build_object('err', coalesce(nullif(d, ''), sqlstate), 'msg', sqlerrm);
  end;
  perform test.logout();
  return v;
end $$;
create function pg_temp.snap(p_order bigint) returns jsonb language sql as $$
  select jsonb_build_object(
    'items', coalesce((select jsonb_agg((to_jsonb(i) - 'updated_at') order by i.id) from booking.order_items i where i.order_id = p_order), '[]'::jsonb),
    'total', (select total_gross from booking.orders where id = p_order),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'status', p.status, 'amount', p.amount, 'refunded_amount', p.refunded_amount, 'link_token', p.link_token, 'link_expires_at', p.link_expires_at) order by p.id) from booking.payments p where p.order_id = p_order), '[]'::jsonb),
    'lines', coalesce((select jsonb_agg(to_jsonb(pl) order by pl.id) from booking.payment_lines pl join booking.payments p on p.id = pl.payment_id where p.order_id = p_order), '[]'::jsonb),
    'refunds', coalesce((select jsonb_agg(to_jsonb(f) order by f.id) from booking.refunds f where f.order_id = p_order), '[]'::jsonb),
    'invoices', coalesce((select jsonb_agg((to_jsonb(i) - 'updated_at') order by i.id) from booking.invoices i where i.order_id = p_order), '[]'::jsonb),
    'invoice_lines', coalesce((select jsonb_agg(to_jsonb(l) order by l.id) from booking.invoice_lines l join booking.invoices i on i.id = l.invoice_id where i.order_id = p_order), '[]'::jsonb))
$$;

-- Jaettu test.pub_book jättää verkkomaksun pidon pending-tilaan. Tämä vahvistaa tilauksen ja varauksen.
create or replace function test.pub_book(p_rule bigint, p_date date, p_persons int, p_email text default null, p_name text default 'Testi Asiakas')
returns jsonb language plpgsql as $$
declare b jsonb; o bigint;
begin
  b := booking.public_create_booking(p_rule, p_date, p_persons, p_name, coalesce(p_email, 'asiakas' || nextval('test.seq') || '@example.com'), '0401234567', false, 'fi', null);
  if coalesce((b->>'ok')::boolean, false) then
    select id into o from booking.orders where public_token = (b->>'token')::uuid;
    update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = o and status = 'pending';
    update booking.orders set status = 'confirmed' where id = o and status = 'pending';
  end if;
  return b;
end $$;

insert into booking.invoice_counters(series, last_seq) values ('L', 0) on conflict do nothing;
update booking.settings set value = '400'::jsonb where key = 'booking_horizon_days';
update booking.settings set value = '150'::jsonb where key = 'public_treatment_horizon_days';

do $t185$
declare
  adm uuid := test.mk_staff('admin@t185.example.test', 'admin');
  vrule bigint := test.rule('Miesten sauna%');
  dt date := test.next_dow(1) + 98;
  mode0 jsonb; redeem0 jsonb; hours0 jsonb; vc0 jsonb; visma_mode text; mo_mode text;
  b jsonb; v jsonb; s0 jsonb; s1 jsonb; gb0 jsonb; gb1 jsonb; go0 jsonb; go1 jsonb;
  oid bigint; res_id bigint; item_id bigint; inv bigint; tok uuid; persons0 int; total0 numeric; pay_id bigint;
  card_id bigint; alt_space text; inv_pay bigint; inv_amt numeric; n_claims int; credit_id bigint;
  addon_max int; clamp_qty int; opt_code text;
  addon_id bigint; space_code text; tprod bigint; tstart timestamptz; tstart2 timestamptz;
  oid_t bigint; res_t bigint; tok_t uuid; inv_t bigint;
  oid_d bigint; res_d bigint; total_d numeric;
  oid_p bigint; res_p bigint; tok_p uuid; link_tok uuid; unpaid numeric;
  gc_id bigint; cl_id bigint; vc booking.voucher_claims;
  legs_pid bigint; n_items int; n_items2 int; d text; link_amt numeric;
begin
  perform pg_temp.ck(vrule is not null, '0 sääntö löytyi');
  select value into mode0 from booking.settings where key = 'invoice_dispatch_mode';
  select value into redeem0 from booking.settings where key = 'gift_cards.redeem_enabled';
  select value into hours0 from booking.settings where key = 'customer_change_hours_before';
  select value into vc0 from booking.settings where key = 'voucher_claims.enabled';
  select mode into visma_mode from booking.integration_config where key = 'vismapay';
  select mode into mo_mode from booking.integration_config where key = 'montonio';
  insert into booking.integration_config(key, mode, settings) values ('montonio', 'test', '{"approved_by":"t185"}'::jsonb)
    on conflict (key) do update set mode = 'test', settings = booking.integration_config.settings || '{"approved_by":"t185"}'::jsonb;
  insert into booking.settings(key, value) values ('invoice_dispatch_mode', '"dry_run"'::jsonb)
    on conflict (key) do update set value = '"dry_run"'::jsonb;
  insert into booking.settings(key, value) values ('gift_cards.redeem_enabled', 'true'::jsonb)
    on conflict (key) do update set value = 'true'::jsonb;
  insert into booking.settings(key, value) values ('voucher_claims.enabled', 'true'::jsonb)
    on conflict (key) do update set value = 'true'::jsonb;

  -- ===== lähetetty lasku (tapaus 1 pohja) =====
  b := test.pub_book(vrule, dt, 2, 'sent@t185.example.test');
  perform pg_temp.ck((b ->> 'ok')::boolean, '1.0 testivaraus');
  tok := (b ->> 'token')::uuid;
  oid := (test.ord(tok)).id;
  select id, persons into res_id, persons0 from booking.reservations where order_id = oid limit 1;
  select id into addon_id from booking.addons where code = 'saunavihta';
  update booking.orders set payment_status = 'invoiced' where id = oid;
  select id into inv from booking.invoices where order_id = oid and kind = 'debit';
  perform pg_temp.ck(inv is not null and (select status from booking.invoices where id = inv) = 'draft', '1.0b luonnos syntyi');
  v := pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, false, true)', inv));
  perform pg_temp.ck(v ->> 'err' is null and (select status from booking.invoices where id = inv) = 'sent', '1.0c lasku lähetetty ' || coalesce(v ->> 'err', v ->> 'msg', ''));
  perform pg_temp.ck(booking._order_invoice_locked(oid), '1.0d lukko päällä');

  s0 := pg_temp.snap(oid);
  v := pg_temp.as_(adm, format('select booking.admin_set_reservation_addons(%s, %L::jsonb)', res_id, jsonb_build_array(jsonb_build_object('id', addon_id, 'quantity', 1))::text));
  perform pg_temp.ck(v ->> 'err' = 'order_invoiced' and pg_temp.snap(oid) = s0, '1 admin_set_reservation_addons');
  v := pg_temp.as_(adm, format('select booking.admin_add_to_order(%s, %L::jsonb, false, false, null)', oid, jsonb_build_array(jsonb_build_object('type', 'addon', 'reservation_id', res_id, 'addon_id', addon_id, 'quantity', 1))::text));
  perform pg_temp.ck(v ->> 'err' = 'order_invoiced' and pg_temp.snap(oid) = s0, '1 admin_add_to_order');
  v := pg_temp.as_(adm, format('select booking.public_add_to_order(%L::uuid, %L::jsonb)', tok, jsonb_build_array(jsonb_build_object('type', 'addon', 'addon_id', addon_id, 'quantity', 1))::text));
  perform pg_temp.ck(coalesce(v ->> 'code', v ->> 'err') = 'order_invoiced' and pg_temp.snap(oid) = s0, '1 public_add_to_order');
  v := booking.public_upsell_add(tok, '{"type":"addon","quantity":1}'::jsonb, gen_random_uuid(), null);
  perform pg_temp.ck(v ->> 'code' = 'order_invoiced' and pg_temp.snap(oid) = s0, '1 public_upsell_add');
  v := pg_temp.as_(adm, format('select booking.admin_create_payment_link(%s, false, null, null)', oid));
  perform pg_temp.ck(v ->> 'err' = 'order_invoiced' and pg_temp.snap(oid) = s0, '1 maksulinkki ilman takarajaa');
  v := pg_temp.as_(adm, format('select booking.admin_create_payment_link(%s, false, 7, null)', oid));
  perform pg_temp.ck(v ->> 'err' = 'order_invoiced' and pg_temp.snap(oid) = s0, '1 maksulinkki 7 pv');
  v := pg_temp.as_(adm, format('select booking.admin_record_payment(%s, %L, 1.00, null, null)', oid, 'card_terminal'));
  perform pg_temp.ck(v ->> 'err' = 'order_invoiced' and pg_temp.snap(oid) = s0, '1 admin_record_payment');
  insert into booking.gift_cards(code, issuer, kind, initial_amount, balance, status, source, vat_treatment, accounting_origin, balance_verified, valid_to)
  values ('HH185LOCK001', 'own', 'value', 50, 50, 'active', 'native', 'at_redemption', 'native', true, current_date + 100)
  returning id into gc_id;
  v := pg_temp.as_(adm, format('select booking.admin_redeem_gift_card(%s, %L, 10, null)', oid, 'HH185LOCK001'));
  perform pg_temp.ck(v ->> 'err' = 'order_invoiced' and pg_temp.snap(oid) = s0, '1 admin_redeem_gift_card');
  v := booking.public_apply_gift_card(tok, 'HH185LOCK001', 10);
  perform pg_temp.ck(v ->> 'code' = 'order_invoiced' and pg_temp.snap(oid) = s0, '1 public_apply_gift_card');

  -- lisäyspolut, joita kääreet eivät aina tavoita
  select count(*) into n_items from booking.order_items where order_id = oid;
  begin
    perform booking._attach_addons(res_id, jsonb_build_array(jsonb_build_object('id', addon_id, 'quantity', 1)));
    v := jsonb_build_object('err', 'none');
  exception when others then
    get stacked diagnostics d = pg_exception_detail;
    v := jsonb_build_object('err', coalesce(d, sqlstate));
  end;
  perform pg_temp.ck(v ->> 'err' = 'order_invoiced', '1b _attach_addons');
  begin
    perform booking._ritual_addon_attach(res_id, jsonb_build_object('ritual_start', '2026-12-01T16:00:00+02:00', 'quantity', 1));
    v := jsonb_build_object('err', 'none');
  exception when others then
    get stacked diagnostics d = pg_exception_detail;
    v := jsonb_build_object('err', coalesce(d, sqlstate));
  end;
  perform pg_temp.ck(v ->> 'err' = 'order_invoiced', '1b _ritual_addon_attach');
  begin
    perform booking._quiet_apply(oid, jsonb_build_object('percent', 10, 'rule_id', 1, 'hours_left', 5));
    v := jsonb_build_object('err', 'none');
  exception when others then
    get stacked diagnostics d = pg_exception_detail;
    v := jsonb_build_object('err', coalesce(d, sqlstate));
  end;
  perform pg_temp.ck(v ->> 'err' = 'order_invoiced', '1b _quiet_apply');
  insert into booking.voucher_claims(order_id, code, source, source_suggested, customer_name, locale)
  values (oid, 'T185PARTNER', 'kiitoskauppa', null, 'T185', 'fi') returning id into cl_id;
  select * into vc from booking.voucher_claims where id = cl_id;
  begin
    perform booking._vc_pay((select o from booking.orders o where o.id = oid), vc, 10);
    v := jsonb_build_object('err', 'none');
  exception when others then
    get stacked diagnostics d = pg_exception_detail;
    v := jsonb_build_object('err', coalesce(d, sqlstate));
  end;
  perform pg_temp.ck(v ->> 'err' = 'order_invoiced' and pg_temp.snap(oid) = s0, '1b _vc_pay');
  begin
    perform booking._create_booking_core(vrule, dt + 7, 2, null, 'admin', adm, 'fi', null, 'confirmed', null, false, null, null, null, null, oid);
    v := jsonb_build_object('err', 'none');
  exception when others then
    get stacked diagnostics d = pg_exception_detail;
    v := jsonb_build_object('err', coalesce(d, sqlstate));
  end;
  perform pg_temp.ck(v ->> 'err' = 'order_invoiced', '1b _create_booking_core olemassa olevaan');
  select pc.product_id into legs_pid from booking.product_config pc join kb.products p on p.id = pc.product_id
   where pc.bookable and p.active order by pc.product_id limit 1;
  begin
    perform booking._create_legs_booking('current', legs_pid, now() + interval '30 days', null, 1, null, 'admin', adm, null, null, null, false, null, false, null, oid, null);
    v := jsonb_build_object('err', 'none');
  exception when others then
    get stacked diagnostics d = pg_exception_detail;
    v := jsonb_build_object('err', coalesce(d, sqlstate));
  end;
  select count(*) into n_items2 from booking.order_items where order_id = oid;
  perform pg_temp.ck(v ->> 'err' = 'order_invoiced' and n_items2 = n_items and pg_temp.snap(oid) = s0, '1b _create_legs_booking olemassa olevaan ' || coalesce(v ->> 'err', ''));
  perform booking._attach_addons(res_id, '[]'::jsonb);
  perform pg_temp.ck(pg_temp.snap(oid) = s0, '1b tyhjä _attach_addons ei muuta');

  -- ===== 2 luonnos: muutokset toimivat =====
  b := test.pub_book(vrule, dt + 7, 2, 'draft@t185.example.test');
  oid_d := (test.ord((b ->> 'token')::uuid)).id;
  select id into res_d from booking.reservations where order_id = oid_d limit 1;
  update booking.orders set payment_status = 'invoiced' where id = oid_d;
  perform pg_temp.ck(not booking._order_invoice_locked(oid_d) and (select status from booking.invoices where order_id = oid_d and kind = 'debit') = 'draft', '2 luonnos ei ole lukossa');
  total_d := (select total_gross from booking.orders where id = oid_d);
  v := pg_temp.as_(adm, format('select booking.admin_set_reservation_addons(%s, %L::jsonb)', res_d, jsonb_build_array(jsonb_build_object('id', addon_id, 'quantity', 1))::text));
  perform pg_temp.ck(v ->> 'ok' = 'true' and (select total_gross from booking.orders where id = oid_d) > total_d, '2 lisäpalvelu päivittää summan');
  total_d := (select total_gross from booking.orders where id = oid_d);
  v := pg_temp.as_(adm, format('select booking.admin_change_booking(%s, null, null, 3)', res_d));
  perform pg_temp.ck(coalesce(v ->> 'ok', '') = 'true' and (select persons from booking.reservations where id = res_d) = 3, '2 henkilömäärä luonnoksessa');
  perform pg_temp.ck((select total_gross from booking.orders where id = oid_d) is distinct from total_d
                  or (select total_gross from booking.orders where id = oid_d) = (select sum(line_total_gross) from booking.order_items where order_id = oid_d),
                  '2 summa laskettu uudelleen');

  -- ===== 3 henkilökunta, lähetetty: siirto ja henkilömäärä, veloitus ennallaan =====
  s0 := pg_temp.snap(oid);
  v := pg_temp.as_(adm, format('select booking.admin_change_booking(%s, %s, %L::date, null)', res_id, vrule, dt + 14));
  perform pg_temp.ck(coalesce(v ->> 'ok', '') = 'true' and (v ->> 'invoice_locked')::boolean
    and (select (starts_at at time zone booking._tz())::date from booking.reservations where id = res_id) = dt + 14
    and pg_temp.snap(oid) = s0, '3 siirto, veloitus ennallaan');
  v := pg_temp.as_(adm, format('select booking.admin_change_booking(%s, null, null, %s)', res_id, persons0 + 1));
  perform pg_temp.ck(coalesce(v ->> 'ok', '') = 'true' and (select persons from booking.reservations where id = res_id) = persons0 + 1
    and (v ->> 'total')::numeric = (s0 ->> 'total')::numeric and pg_temp.snap(oid) = s0, '3 henkilömäärän nosto');
  perform pg_temp.ck((select new_data ->> 'invoice_locked' from booking.audit_log where row_pk = res_id::text and action = 'ADMIN_CHANGE' order by id desc limit 1) = 'true', '3 audit invoice_locked');
  v := pg_temp.as_(adm, format('select booking.admin_change_booking(%s, null, null, %s)', res_id, persons0));
  perform pg_temp.ck(coalesce(v ->> 'ok', '') = 'true' and (select persons from booking.reservations where id = res_id) = persons0 and pg_temp.snap(oid) = s0, '3 henkilömäärän lasku');
  v := pg_temp.as_(adm, format('select booking.admin_change_booking(%s, null, null, 500)', res_id));
  perform pg_temp.ck(v ->> 'err' = 'persons_max' and (select persons from booking.reservations where id = res_id) = persons0 and pg_temp.snap(oid) = s0, '3 kapasiteetti ' || coalesce(v ->> 'err', ''));

  -- ===== 4 asiakas, maksettu + lähetetty =====
  b := test.pub_book(vrule, dt + 21, 2, 'paid@t185.example.test');
  tok_p := (b ->> 'token')::uuid;
  oid_p := (test.ord(tok_p)).id;
  select id, persons into res_p, persons0 from booking.reservations where order_id = oid_p limit 1;
  total0 := (select total_gross from booking.orders where id = oid_p);
  v := pg_temp.as_(adm, format('select booking.admin_record_payment(%s, %L, %s, null, null)', oid_p, 'card_terminal', total0));
  perform pg_temp.ck(v ->> 'ok' = 'true', '4 maksu ennen laskua');
  update booking.orders set payment_status = 'invoiced' where id = oid_p;
  select id into inv from booking.invoices where order_id = oid_p and kind = 'debit';
  v := pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, false, true)', inv));
  perform pg_temp.ck((select status from booking.invoices where id = inv) = 'sent', '4 lasku lähetetty');
  s0 := pg_temp.snap(oid_p);
  v := booking.public_change_booking(tok_p, null, null, persons0 + 1);
  perform pg_temp.ck(v ->> 'code' = 'order_invoiced' and (select persons from booking.reservations where id = res_p) = persons0 and pg_temp.snap(oid_p) = s0, '4 public_change_booking nosto');
  v := booking.public_change_booking(tok_p, null, null, persons0 - 1);
  perform pg_temp.ck(v ->> 'code' = 'order_invoiced' and pg_temp.snap(oid_p) = s0, '4 public_change_booking lasku');
  v := booking.public_change_order_time(tok_p, res_p, null, null, null, persons0 + 1, null);
  perform pg_temp.ck(coalesce(v ->> 'code', v ->> 'err') = 'order_invoiced' and pg_temp.snap(oid_p) = s0, '4 public_change_order_time henkilömäärä');
  v := booking.public_change_booking(tok_p, vrule, dt + 28, null);
  perform pg_temp.ck(coalesce((v ->> 'ok')::boolean, false) and v ->> 'code' is distinct from 'price_change_requires_staff' and pg_temp.snap(oid_p) = s0
    and (select (starts_at at time zone booking._tz())::date from booking.reservations where id = res_p) = dt + 28, '4 asiakkaan siirto p_persons null');
  v := booking.public_change_booking(tok_p, vrule, dt + 35, persons0);
  perform pg_temp.ck(coalesce((v ->> 'ok')::boolean, false) and pg_temp.snap(oid_p) = s0, '4 siirto nykyisellä henkilömäärällä');
  v := booking.public_change_booking(tok_p, vrule, dt + 42, persons0 + 1);
  perform pg_temp.ck(v ->> 'code' = 'order_invoiced' and (select (starts_at at time zone booking._tz())::date from booking.reservations where id = res_p) = dt + 35 and pg_temp.snap(oid_p) = s0, '4 siirto ja henkilömäärä yhdessä');
  update booking.settings set value = '100000'::jsonb where key = 'customer_change_hours_before';
  v := booking.public_change_booking(tok_p, vrule, dt + 49, null);
  perform pg_temp.ck(v ->> 'code' = 'change_too_late' and pg_temp.snap(oid_p) = s0, '4 change_too_late');
  update booking.settings set value = coalesce(hours0, '48'::jsonb) where key = 'customer_change_hours_before';

  -- hoito, jos vapaa aika löytyy
  select pc.product_id into tprod from booking.product_config pc where pc.public_slots and pc.bookable order by pc.product_id limit 1;
  if tprod is not null then
    select q.starts_at into tstart from booking.public_treatment_availability(tprod, current_date + 14, current_date + 27, 2) q where q.status = 'available' order by 1 limit 1;
    select q.starts_at into tstart2 from booking.public_treatment_availability(tprod, current_date + 14, current_date + 27, 2) q where q.status = 'available' and q.starts_at > tstart + interval '1 day' order by 1 limit 1;
  end if;
  perform pg_temp.ck(tstart is not null and tstart2 is not null, '4b hoitoaika löytyi');
  if tstart is not null then
    b := booking.public_create_treatment_booking(tprod, tstart, 2, 'Testi Asiakas', 'tr@t185.example.test', '+358401112233', false, 'fi', null, 'private', null, null);
    perform pg_temp.ck((b ->> 'ok')::boolean, '4b hoito varattu ' || coalesce(b ->> 'code', ''));
    if coalesce((b ->> 'ok')::boolean, false) then
      tok_t := (b ->> 'token')::uuid;
      oid_t := (select id from booking.orders where public_token = tok_t);
      total0 := (select total_gross from booking.orders where id = oid_t);
      v := pg_temp.as_(adm, format('select booking.admin_record_payment(%s, %L, %s, null, null)', oid_t, 'card_terminal', total0));
      select id into res_t from booking.reservations where order_id = oid_t and status = 'confirmed' order by id limit 1;
      update booking.orders set payment_status = 'invoiced' where id = oid_t;
      select id into inv_t from booking.invoices where order_id = oid_t and kind = 'debit';
      v := pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, false, true)', inv_t));
      s0 := pg_temp.snap(oid_t);
      v := booking.public_change_treatment_booking(tok_t, null, 3, null);
      perform pg_temp.ck(v ->> 'code' = 'order_invoiced' and pg_temp.snap(oid_t) = s0, '4b hoito henkilömäärä');
      v := booking.public_change_treatment_booking(tok_t, tstart2, null, null);
      perform pg_temp.ck(coalesce((v ->> 'ok')::boolean, false) and v ->> 'code' is distinct from 'price_change_requires_staff' and pg_temp.snap(oid_t) = s0, '4b hoito aikasiirto');
      perform pg_temp.ck(res_t is not null and (select new_data ->> 'invoice_locked' from booking.audit_log where row_pk = res_t::text and action = 'CUSTOMER_CHANGE' order by id desc limit 1) = 'true', '4b hoito audit invoice_locked');
      v := booking.public_change_treatment_booking(tok_t, tstart2, 1, null);
      perform pg_temp.ck(v ->> 'code' = 'order_invoiced' and pg_temp.snap(oid_t) = s0, '4b hoito siirto ja henkilömäärä');
    end if;
  end if;

  -- lukitsematon asiakasmuutos
  b := test.pub_book(vrule, dt + 56, 2, 'open@t185.example.test');
  v := booking.public_change_booking((b ->> 'token')::uuid, null, null, 3);
  perform pg_temp.ck(coalesce((v ->> 'ok')::boolean, false) and v ->> 'code' is distinct from 'order_invoiced', '4c lukitsematon henkilömäärä ' || coalesce(v ->> 'code', 'ok'));

  -- asiakkaan ajan siirto public_change_order_time-funktiolla (kutsuu _sync_placeholder)
  b := test.pub_book(vrule, dt + 168, 2, 'mvtime@t185.example.test');
  tok := (b ->> 'token')::uuid;
  oid := (test.ord(tok)).id;
  select id, persons into res_id, persons0 from booking.reservations where order_id = oid limit 1;
  update booking.orders set payment_status = 'invoiced' where id = oid;
  select id into inv from booking.invoices where order_id = oid and kind = 'debit';
  v := pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, false, true)', inv));
  perform pg_temp.ck((select status from booking.invoices where id = inv) = 'sent', '4d lasku lähetetty');
  insert into booking.payments(order_id, method, provider, status, amount)
  values (oid, 'invoice', 'manual', 'pending', (select total_gross from booking.orders where id = oid))
  returning id, amount into inv_pay, inv_amt;
  s0 := pg_temp.snap(oid);
  v := booking.public_change_order_time(tok, res_id, null, vrule, dt + 175, null, null);
  perform pg_temp.ck(coalesce((v ->> 'ok')::boolean, false) and v ->> 'code' is distinct from 'price_change_requires_staff'
    and (select (starts_at at time zone booking._tz())::date from booking.reservations where id = res_id) = dt + 175
    and pg_temp.snap(oid) = s0
    and (select amount from booking.payments where id = inv_pay) is not distinct from inv_amt, '4d siirto p_persons null');
  v := booking.public_change_order_time(tok, res_id, null, vrule, dt + 182, persons0, null);
  perform pg_temp.ck(coalesce((v ->> 'ok')::boolean, false) and v ->> 'code' is distinct from 'price_change_requires_staff'
    and (select (starts_at at time zone booking._tz())::date from booking.reservations where id = res_id) = dt + 182
    and (select persons from booking.reservations where id = res_id) = persons0
    and pg_temp.snap(oid) = s0
    and (select amount from booking.payments where id = inv_pay) is not distinct from inv_amt, '4d siirto nykyisellä henkilömäärällä');

  -- ===== 5–7 lisäpalvelun lukko ilman laskua (päätös 11) =====
  b := test.pub_book(vrule, dt + 63, 2, 'addon@t185.example.test');
  oid := (test.ord((b ->> 'token')::uuid)).id;
  select id, order_item_id into res_id, item_id from booking.reservations where order_id = oid limit 1;
  v := pg_temp.as_(adm, format('select booking.admin_set_reservation_addons(%s, %L::jsonb)', res_id, jsonb_build_array(jsonb_build_object('id', addon_id, 'quantity', 2))::text));
  perform pg_temp.ck(v ->> 'ok' = 'true', '5 lisäpalvelu lisätty');
  select id into pay_id from booking.order_items where parent_item_id = item_id and kind = 'addon' order by id limit 1;
  total0 := (select line_total_gross from booking.order_items where id = pay_id);
  v := pg_temp.as_(adm, format('select booking.admin_record_payment(%s, %L, %s, null, null)', oid, 'card_terminal', (select total_gross from booking.orders where id = oid)));
  v := pg_temp.as_(adm, format('select booking.admin_change_booking(%s, null, null, 1)', res_id));
  perform pg_temp.ck(coalesce(v ->> 'ok', '') = 'true'
    and (select quantity from booking.order_items where id = pay_id) = 2
    and (select line_total_gross from booking.order_items where id = pay_id) = total0
    and not exists (select 1 from booking.refunds where order_id = oid), '5 maksettu lisäpalvelu ei rajaudu eikä hyvity');

  -- 6a: maksamaton lisäpalvelu ilman linkkiä rajataan. saunavihta.max_per_person on devissä 20,
  -- joten määrä 2 ei ylitä yhden hengen rajaa. Määrä on raja + 1: kahdelle se mahtuu, yhdelle se rajataan.
  b := test.pub_book(vrule, dt + 70, 2, 'clamp@t185.example.test');
  oid := (test.ord((b ->> 'token')::uuid)).id;
  select id, order_item_id into res_id, item_id from booking.reservations where order_id = oid limit 1;
  select max_per_person into addon_max from booking.addons where id = addon_id;
  clamp_qty := coalesce(addon_max, 0) + 1;
  perform pg_temp.ck(addon_max between 1 and 98 and clamp_qty <= least(addon_max * 2, 99), '6a määrä ylittää yhden hengen rajan ' || coalesce(addon_max::text, 'null'));
  v := pg_temp.as_(adm, format('select booking.admin_set_reservation_addons(%s, %L::jsonb)', res_id, jsonb_build_array(jsonb_build_object('id', addon_id, 'quantity', clamp_qty))::text));
  perform pg_temp.ck(v ->> 'ok' = 'true' and not exists (select 1 from booking.payments p where p.order_id = oid and p.provider <> 'manual' and p.status = 'pending'), '6a lisäpalvelu ilman linkkiä ' || coalesce(v ->> 'err', ''));
  v := pg_temp.as_(adm, format('select booking.admin_change_booking(%s, null, null, 1)', res_id));
  perform pg_temp.ck(coalesce(v ->> 'ok', '') = 'true'
    and (select quantity from booking.order_items where parent_item_id = item_id and kind = 'addon' order by id limit 1) = least(addon_max, 99)
    and (select price_breakdown ->> 'clamped_from' from booking.order_items where parent_item_id = item_id and kind = 'addon' order by id limit 1) = clamp_qty::text, '6a maksamaton lisäpalvelu rajattiin');

  -- 6b: avoin takarajaton linkki lukitsee lisäpalvelun, määrää ei rajata
  b := test.pub_book(vrule, dt + 196, 2, 'link@t185.example.test');
  oid := (test.ord((b ->> 'token')::uuid)).id;
  select id, order_item_id into res_id, item_id from booking.reservations where order_id = oid limit 1;
  v := pg_temp.as_(adm, format('select booking.admin_set_reservation_addons(%s, %L::jsonb)', res_id, jsonb_build_array(jsonb_build_object('id', addon_id, 'quantity', 2))::text));
  v := pg_temp.as_(adm, format('select booking.admin_create_payment_link(%s, false, null, null)', oid));
  perform pg_temp.ck(v ->> 'err' is null, '6b takarajaton linkki ' || coalesce(v ->> 'err', ''));
  select id, amount into pay_id, link_amt from booking.payments where order_id = oid and status = 'pending' and provider = 'montonio' order by id desc limit 1;
  perform pg_temp.ck((select link_expires_at is null and raw ->> 'paylink' = 'no_deadline' from booking.payments where id = pay_id), '6b linkki on takarajaton');
  v := pg_temp.as_(adm, format('select booking.admin_change_booking(%s, null, null, 1)', res_id));
  perform pg_temp.ck(coalesce(v ->> 'ok', '') = 'true'
    and (select quantity from booking.order_items where parent_item_id = item_id and kind = 'addon' order by id limit 1) = 2
    and (select price_breakdown ->> 'clamped_from' from booking.order_items where parent_item_id = item_id and kind = 'addon' order by id limit 1) is null
    and (select status from booking.payments where id = pay_id) = 'pending'
    and (select amount from booking.payments where id = pay_id) = link_amt, '6b linkitetty lisäpalvelu ei rajaudu');

  -- 7: osittain hyvitetty lisäpalvelu pysyy lukittuna
  b := test.pub_book(vrule, dt + 203, 2, 'part@t185.example.test');
  oid := (test.ord((b ->> 'token')::uuid)).id;
  select id, order_item_id into res_id, item_id from booking.reservations where order_id = oid limit 1;
  v := pg_temp.as_(adm, format('select booking.admin_set_reservation_addons(%s, %L::jsonb)', res_id, jsonb_build_array(jsonb_build_object('id', addon_id, 'quantity', 2))::text));
  v := pg_temp.as_(adm, format('select booking.admin_record_payment(%s, %L, %s, null, null)', oid, 'card_terminal', (select total_gross from booking.orders where id = oid)));
  select id into pay_id from booking.payments where order_id = oid and status = 'paid' order by id desc limit 1;
  select id, line_total_gross into item_id, total0 from booking.order_items where parent_item_id = (select order_item_id from booking.reservations where id = res_id) and kind = 'addon' order by id limit 1;
  select id, amount_gross into inv_pay, inv_amt from booking.payment_lines where payment_id = pay_id and order_item_id = item_id;
  perform pg_temp.ck(pay_id is not null and inv_pay is not null and inv_amt > 0, '7 maksettu lisäpalvelurivi');
  v := pg_temp.as_(adm, format('select booking.admin_refund(%s, %s, %L, %L::jsonb)', pay_id, round(inv_amt / 2, 2), 't185 osahyvitys',
                               jsonb_build_array(jsonb_build_object('payment_line_id', inv_pay, 'amount', round(inv_amt / 2, 2)))::text));
  perform pg_temp.ck(v ->> 'status' = 'done', '7 osahyvitys kirjautui');
  v := pg_temp.as_(adm, format('select booking.admin_set_reservation_addons(%s, %L::jsonb)', res_id, jsonb_build_array(jsonb_build_object('id', addon_id, 'quantity', 1))::text));
  perform pg_temp.ck(v ->> 'err' = 'addon_paid'
    and (select quantity from booking.order_items where id = item_id) = 2
    and (select line_total_gross from booking.order_items where id = item_id) = total0, '7 vähennys palauttaa addon_paid');
  v := pg_temp.as_(adm, format('select booking.admin_change_booking(%s, null, null, 1)', res_id));
  perform pg_temp.ck(coalesce(v ->> 'ok', '') = 'true' and v ->> 'err' is distinct from 'order_invoiced'
    and (select persons from booking.reservations where id = res_id) = 1
    and (select quantity from booking.order_items where id = item_id) = 2
    and (select line_total_gross from booking.order_items where id = item_id) = total0, '7 henkilömäärän lasku ei pienennä lisäpalvelua');

  -- ===== 8 linkki ja sitten lasku =====
  b := test.pub_book(vrule, dt + 77, 2, 'vp@t185.example.test');
  tok := (b ->> 'token')::uuid;
  oid := (test.ord(tok)).id;
  v := pg_temp.as_(adm, format('select booking.admin_create_payment_link(%s, false, null, null)', oid));
  perform pg_temp.ck(v ->> 'err' is null, '8 linkki ennen laskua');
  select link_token into link_tok from booking.payments where order_id = oid and status = 'pending' and provider = 'montonio' order by id desc limit 1;
  update booking.orders set payment_status = 'invoiced' where id = oid;
  select id into inv from booking.invoices where order_id = oid and kind = 'debit';
  v := pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, false, true)', inv));
  s0 := pg_temp.snap(oid);
  begin
    perform booking.mobilepay_payment_prepare(null, link_tok, 120, 'WEB_REDIRECT');
    v := jsonb_build_object('err', 'none');
  exception when others then
    get stacked diagnostics d = pg_exception_detail;
    v := jsonb_build_object('err', coalesce(d, sqlstate));
  end;
  perform pg_temp.ck(v ->> 'err' = 'order_not_payable' and pg_temp.snap(oid) = s0, '8 mobilepay order_not_payable');
  v := booking.vismapay_payment_prepare(null, link_tok);
  perform pg_temp.ck(v ->> 'code' = 'order_not_payable' and pg_temp.snap(oid) = s0, '8 vismapay linkki');
  update booking.integration_config set mode = 'dry_run' where key = 'vismapay';
  v := booking.vismapay_payment_prepare(tok, null);
  perform pg_temp.ck(v ->> 'code' = 'order_not_payable' and coalesce((v ->> 'ok')::boolean, false) = false and pg_temp.snap(oid) = s0, '8 vismapay dry_run');
  update booking.integration_config set mode = visma_mode where key = 'vismapay' and visma_mode is not null;

  -- sallittu: laskun merkintä maksetuksi ei ole order_invoiced
  v := pg_temp.as_(adm, format('select booking.admin_mark_invoice_paid(%s)', inv));
  perform pg_temp.ck(v ->> 'err' is distinct from 'order_invoiced' and (select status from booking.invoices where id = inv) = 'paid', 'sallittu admin_mark_invoice_paid');
  perform pg_temp.ck(booking._order_invoice_locked(oid), 'maksettu lasku pysyy lukossa');

  -- ===== 9 hyvitys pitää lukon =====
  b := test.pub_book(vrule, dt + 84, 2, 'cred@t185.example.test');
  tok := (b ->> 'token')::uuid;
  oid := (test.ord(tok)).id;
  select id into res_id from booking.reservations where order_id = oid limit 1;
  update booking.orders set payment_status = 'invoiced' where id = oid;
  select id into inv from booking.invoices where order_id = oid and kind = 'debit';
  v := pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, false, true)', inv));
  v := pg_temp.as_(adm, format('select booking.admin_credit_invoice(%s)', inv));
  credit_id := nullif(v ->> 'id', '')::bigint;
  perform pg_temp.ck(v ->> 'err' is null and credit_id is not null and v ->> 'kind' = 'credit' and v ->> 'status' = 'draft', '9 hyvitysluonnos ' || coalesce(v ->> 'err', v ->> 'msg', ''));
  v := pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, false, true)', credit_id));
  perform pg_temp.ck(v ->> 'err' is null and (select status from booking.invoices where id = inv) = 'credited', '9 hyvityslasku lähetetty ' || coalesce(v ->> 'err', v ->> 'msg', ''));
  perform pg_temp.ck(booking._order_invoice_locked(oid), '9 lukko hyvityksen jälkeen');
  s0 := pg_temp.snap(oid);
  v := pg_temp.as_(adm, format('select booking.admin_add_to_order(%s, %L::jsonb, false, false, null)', oid, '[{"type":"custom","description":"ei saa","amount":1,"vat_rate":25.5}]'::jsonb));
  perform pg_temp.ck(v ->> 'err' = 'order_invoiced' and pg_temp.snap(oid) = s0, '9 lisäys yhä estetty');
  v := pg_temp.as_(adm, format('select booking.admin_change_booking(%s, null, null, 4)', res_id));
  perform pg_temp.ck(coalesce(v ->> 'ok', '') = 'true' and (select persons from booking.reservations where id = res_id) = 4 and pg_temp.snap(oid) = s0, '9 henkilömäärä jäädyttää rivit');

  -- ===== 10–12 peruutus =====
  b := test.pub_book(vrule, dt + 91, 2, 'can@t185.example.test');
  oid := (test.ord((b ->> 'token')::uuid)).id;
  select id into res_id from booking.reservations where order_id = oid limit 1;
  update booking.orders set payment_status = 'invoiced' where id = oid;
  select id into inv from booking.invoices where order_id = oid and kind = 'debit';
  perform pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, false, true)', inv));
  s0 := pg_temp.snap(oid);
  v := pg_temp.as_(adm, format('select booking.admin_cancel_reservation(%s, %L, false, null)', res_id, 't185'));
  perform pg_temp.ck(coalesce(v ->> 'ok', '') = 'true' and (select status from booking.reservations where id = res_id) = 'cancelled'
    and (select status from booking.orders where id = oid) = 'cancelled' and pg_temp.snap(oid) = s0
    and not exists (select 1 from booking.refunds where order_id = oid), '10 peruutus ilman hyvitystä');

  b := test.pub_book(vrule, dt + 98, 2, 'canr@t185.example.test');
  oid := (test.ord((b ->> 'token')::uuid)).id;
  select id into res_id from booking.reservations where order_id = oid limit 1;
  total0 := (select total_gross from booking.orders where id = oid);
  perform pg_temp.as_(adm, format('select booking.admin_record_payment(%s, %L, %s, null, null)', oid, 'card_terminal', total0));
  update booking.orders set payment_status = 'invoiced' where id = oid;
  select id into inv from booking.invoices where order_id = oid and kind = 'debit';
  perform pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, false, true)', inv));
  s0 := pg_temp.snap(oid);
  v := pg_temp.as_(adm, format('select booking.admin_cancel_reservation(%s, %L, true, %L)', res_id, 't185', 't185'));
  perform pg_temp.ck(v ->> 'err' = 'order_invoiced' and (select status from booking.reservations where id = res_id) = 'confirmed'
    and pg_temp.snap(oid) = s0, '11 hyvittävä peruutus estetty');

  v := pg_temp.as_(adm, format('select booking.admin_set_reservation_status(%s, %L, %L)', res_id, 'cancelled', 't185'));
  perform pg_temp.ck(coalesce(v ->> 'ok', '') = 'true' and (select status from booking.reservations where id = res_id) = 'cancelled'
    and (select total_gross from booking.orders where id = oid) = (s0 ->> 'total')::numeric
    and not exists (select 1 from booking.refunds where order_id = oid), '12 tilan peruutus ilman hyvitystä');

  -- ilman laskua hyvittävä peruutus ei ole order_invoiced
  b := test.pub_book(vrule, dt + 105, 2, 'canok@t185.example.test');
  oid := (test.ord((b ->> 'token')::uuid)).id;
  select id into res_id from booking.reservations where order_id = oid limit 1;
  v := pg_temp.as_(adm, format('select booking.admin_cancel_reservation(%s, %L, true, %L)', res_id, 't185', 't185'));
  perform pg_temp.ck(v ->> 'err' is distinct from 'order_invoiced', '11b ilman laskua p_refund ei ole order_invoiced');

  -- ===== 13 asiakkaan peruutus =====
  b := test.pub_book(vrule, dt + 112, 2, 'pc@t185.example.test');
  tok := (b ->> 'token')::uuid;
  oid := (test.ord(tok)).id;
  update booking.orders set payment_status = 'invoiced' where id = oid;
  select id into inv from booking.invoices where order_id = oid and kind = 'debit';
  perform pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, false, true)', inv));
  s0 := pg_temp.snap(oid);
  v := booking.public_cancel_booking(tok);
  perform pg_temp.ck(v ->> 'code' = 'order_invoiced' and pg_temp.snap(oid) = s0 and (select status from booking.orders where id = oid) = 'confirmed', '13 confirmed');
  update booking.orders set status = 'pending' where id = oid;
  update booking.reservations set status = 'pending', hold_expires_at = now() + interval '1 hour' where order_id = oid;
  s1 := pg_temp.snap(oid);
  v := booking.public_cancel_booking(tok);
  perform pg_temp.ck(v ->> 'code' = 'order_invoiced' and (select status from booking.orders where id = oid) = 'pending' and pg_temp.snap(oid) = s1, '13 pending');
  b := test.pub_book(vrule, dt + 119, 2, 'pcok@t185.example.test');
  v := booking.public_cancel_booking((b ->> 'token')::uuid);
  perform pg_temp.ck(v ->> 'code' is distinct from 'order_invoiced', '13 lukitsematon ei ole order_invoiced');
  b := test.pub_book(vrule, dt + 126, 2, 'req@t185.example.test');
  tok := (b ->> 'token')::uuid;
  oid := (test.ord(tok)).id;
  update booking.orders set payment_status = 'invoiced' where id = oid;
  select id into inv from booking.invoices where order_id = oid and kind = 'debit';
  perform pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, false, true)', inv));
  v := booking.public_request_cancel(tok, 't185');
  perform pg_temp.ck(coalesce((v ->> 'ok')::boolean, false) and exists (select 1 from booking.order_requests where order_id = oid and kind = 'cancel'), '13 peruutuspyyntö ' || coalesce(v ->> 'code', ''));

  -- ===== 14 tila ja hoito =====
  b := test.pub_book(vrule, dt + 133, 2, 'mv@t185.example.test');
  oid := (test.ord((b ->> 'token')::uuid)).id;
  select r.id, sp.code into res_id, space_code
    from booking.reservations r
    join booking.resources sp on sp.id = r.space_id
   where r.order_id = oid limit 1;
  update booking.orders set payment_status = 'invoiced' where id = oid;
  select id into inv from booking.invoices where order_id = oid and kind = 'debit';
  perform pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, false, true)', inv));
  s0 := pg_temp.snap(oid);
  v := pg_temp.as_(adm, format('select booking.admin_set_reservation_option(%s, null, false)', res_id));
  perform pg_temp.ck(v ->> 'err' is distinct from 'order_invoiced' and pg_temp.snap(oid) = s0, '14 hoito/valinta ' || coalesce(v ->> 'err', v ->> 'ok', ''));
  select pc.product_id into tprod
    from booking.product_config pc
   where pc.public_slots and pc.bookable
     and (select count(distinct psr.space_id)
            from booking.product_space_rules psr
            join booking.resources sp on sp.id = psr.space_id and sp.active and sp.kind = 'space'
           where psr.product_id = pc.product_id and psr.leg_no = 1 and psr.active
             and 1 between psr.min_persons and coalesce(psr.max_persons, 1)) >= 2
   order by pc.product_id
   limit 1;
  tstart := null;
  opt_code := null;
  if tprod is not null then
    select q.starts_at into tstart from booking.public_treatment_availability(tprod, current_date + 60, current_date + 73, 1) q
     where q.status = 'available' order by 1 limit 1;
    select po.code into opt_code from booking.product_options po
     where po.product_id = tprod and po.active order by po.sort_order, po.id limit 1;
  end if;
  perform pg_temp.ck(tprod is not null and tstart is not null and opt_code is not null, '14 kahden tilan tuote, aika ja vaihtoehto ' || coalesce(tprod::text, 'ei') || ' ' || coalesce(opt_code, ''));
  if tstart is not null and opt_code is not null then
    b := booking.public_create_treatment_booking(tprod, tstart, 1, 'Testi Siirto', 'mvsp@t185.example.test', '+358401112244', false, 'fi', null, 'private', null, opt_code);
    perform pg_temp.ck((b ->> 'ok')::boolean, '14 hoito varattu ' || coalesce(b ->> 'code', ''));
    if coalesce((b ->> 'ok')::boolean, false) then
      oid := (select id from booking.orders where public_token = (b ->> 'token')::uuid);
      update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = oid and status = 'pending';
      update booking.orders set status = 'confirmed' where id = oid and status = 'pending';
      select r.id, sp.code into res_id, space_code
        from booking.reservations r join booking.resources sp on sp.id = r.space_id
       where r.order_id = oid and r.status = 'confirmed' order by r.id limit 1;
      select sp.code into alt_space
        from booking.reservations r
        join booking.product_space_rules psr on psr.product_id = r.product_id and psr.leg_no = 1 and psr.active
        join booking.resources sp on sp.id = psr.space_id and sp.active and sp.kind = 'space'
       where r.id = res_id and sp.id is distinct from r.space_id
         and r.persons between psr.min_persons and coalesce(psr.max_persons, r.persons)
       order by psr.priority, sp.code
       limit 1;
      update booking.orders set payment_status = 'invoiced' where id = oid;
      select id into inv from booking.invoices where order_id = oid and kind = 'debit';
      perform pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, false, true)', inv));
      s0 := pg_temp.snap(oid);
      v := pg_temp.as_(adm, format('select booking.admin_move_reservation_space(%s, %L, %L)', res_id, alt_space, 't185'));
      perform pg_temp.ck(alt_space is not null and alt_space is distinct from space_code
        and coalesce(v ->> 'ok', '') = 'true' and v ->> 'err' is distinct from 'order_invoiced'
        and (select sp.code from booking.reservations r join booking.resources sp on sp.id = r.space_id where r.id = res_id) = alt_space
        and pg_temp.snap(oid) = s0, '14 tilan siirto ' || coalesce(space_code, '') || ' -> ' || coalesce(alt_space, '') || ' ' || coalesce(v ->> 'err', v ->> 'code', ''));
    end if;
  end if;

  -- ===== 15 vuosikortin alennustriggeri: annual_card_id päällä, lukko estää discount_amountin muutoksen =====
  b := test.pub_book(vrule, dt + 140, 1, 'ann@t185.example.test');
  oid := (test.ord((b ->> 'token')::uuid)).id;
  select r.id, r.order_item_id into res_id, item_id from booking.reservations r where r.order_id = oid limit 1;
  perform pg_temp.ck((select mode from booking.reservations where id = res_id) = 'shared', '15 yleinen vuoro');
  update booking.orders set payment_status = 'invoiced' where id = oid;
  select id into inv from booking.invoices where order_id = oid and kind = 'debit';
  perform pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, false, true)', inv));
  perform pg_temp.ck(booking._order_invoice_locked(oid), '15 lukko ennen korttia');
  update booking.orders set total_gross = 0 where id = oid;
  update booking.order_items set line_total_gross = 0, unit_price_gross = 0, discount_amount = -1, discount_code_id = null where id = item_id;
  insert into booking.annual_cards(customer_id, valid_from, valid_to, active, code)
  values ((select customer_id from booking.orders where id = oid), (dt + 140) - 30, (dt + 140) + 30, true, 'T185ANNUAL1')
  returning id into card_id;
  update booking.reservations set annual_card_id = card_id where id = res_id;
  perform pg_temp.ck((select annual_card_id from booking.reservations where id = res_id) = card_id
    and (select discount_amount from booking.order_items where id = item_id) = -1, '15 annual_card_id ei muuttanut alennusta');
  update booking.reservations set persons = persons where id = res_id;
  perform pg_temp.ck((select discount_amount from booking.order_items where id = item_id) = -1
    and (select annual_card_id from booking.reservations where id = res_id) is not null, '15 triggeri ei päivitä discount_amountia laskulukossa');

  -- ===== 16 julkiset kentät: luonnos vs lähetetty, sama transaktio =====
  b := test.pub_book(vrule, dt + 147, 2, 'get@t185.example.test');
  tok := (b ->> 'token')::uuid;
  oid := (test.ord(tok)).id;
  update booking.orders set payment_status = 'invoiced' where id = oid;
  select id into inv from booking.invoices where order_id = oid and kind = 'debit';
  perform pg_temp.ck((select status from booking.invoices where id = inv) = 'draft' and not booking._order_invoice_locked(oid), '16 luonnos ei ole lukossa');
  perform test.reset_rl();
  gb0 := booking.public_get_booking(tok);
  go0 := booking.public_get_order(tok);
  perform pg_temp.ck((gb0 ->> 'invoice_locked') = 'false' and (go0 ->> 'invoice_locked') = 'false' and (go0 ->> 'ok') = 'true', '16 lukitsematon ennen lähetystä');
  perform pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, false, true)', inv));
  perform test.reset_rl();
  gb1 := booking.public_get_booking(tok);
  go1 := booking.public_get_order(tok);
  perform pg_temp.ck((gb1 ->> 'invoice_locked') = 'true' and (gb1 - 'invoice_locked') = (gb0 - 'invoice_locked')
    and (select jsonb_agg(k order by k) from jsonb_object_keys(gb1) as u(k)) = (select jsonb_agg(k order by k) from jsonb_object_keys(gb0) as u(k)), '16 booking vain invoice_locked muuttui');
  perform pg_temp.ck((go1 ->> 'invoice_locked') = 'true' and (go1 ->> 'can_add') = 'false'
    and (go1 - 'invoice_locked' - 'can_add' - 'add_until' - 'upsell') = (go0 - 'invoice_locked' - 'can_add' - 'add_until' - 'upsell')
    and (select jsonb_agg(k order by k) from jsonb_object_keys(go1) as u(k)) = (select jsonb_agg(k order by k) from jsonb_object_keys(go0) as u(k)), '16 order muuten sama, avaimet samat');
  perform pg_temp.ck(booking.public_upsell_for_order(tok) = jsonb_build_object('products', '[]'::jsonb, 'addons', '[]'::jsonb), '16 upsell tyhjä');
  v := pg_temp.as_(adm, format('select booking.admin_get_order(%s)', oid));
  perform pg_temp.ck((v ->> 'invoice_locked') = 'true' and v ->> 'invoice_no' is not null and (v ->> 'can_add') = 'false' and (v ->> 'staff_can_add') = 'false', '16 admin_get_order');

  -- ===== 17 link_stale =====
  b := test.pub_book(vrule, dt + 154, 2, 'stale@t185.example.test');
  oid := (test.ord((b ->> 'token')::uuid)).id;
  select id into res_id from booking.reservations where order_id = oid limit 1;
  v := pg_temp.as_(adm, format('select booking.admin_create_payment_link(%s, false, null, null)', oid));
  select id, amount into pay_id, total0 from booking.payments where order_id = oid and status = 'pending' and provider = 'montonio' order by id desc limit 1;
  v := pg_temp.as_(adm, format('select booking.admin_change_booking(%s, null, null, 1)', res_id));
  unpaid := (booking._order_balance(oid) ->> 'unpaid')::numeric;
  v := pg_temp.as_(adm, format('select booking.admin_get_order(%s)', oid));
  perform pg_temp.ck(total0 > unpaid + 0.004 and exists (
    select 1 from jsonb_array_elements(v -> 'payments') p
    where (p ->> 'id')::bigint = pay_id and (p ->> 'link_stale')::boolean), '17 vanha linkki link_stale');
  v := pg_temp.as_(adm, format('select booking.admin_create_payment_link(%s, false, null, null)', oid));
  v := pg_temp.as_(adm, format('select booking.admin_get_order(%s)', oid));
  perform pg_temp.ck(exists (
    select 1 from jsonb_array_elements(v -> 'payments') p
    where (p ->> 'status') = 'pending' and coalesce((p ->> 'link_stale')::boolean, true) = false), '17 uusi linkki ei ole vanhentunut');

  -- ===== 20 kumppanilahjakortti lukitulla tilauksella =====
  b := test.pub_book(vrule, dt + 210, 2, 'vc@t185.example.test');
  tok := (b ->> 'token')::uuid;
  oid := (test.ord(tok)).id;
  update booking.orders set payment_status = 'invoiced' where id = oid;
  select id into inv from booking.invoices where order_id = oid and kind = 'debit';
  perform pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, false, true)', inv));
  insert into booking.voucher_claims(order_id, code, source, customer_name, locale)
  values (oid, 'T185VCOPEN1', 'elamyslahjat', 'T185', 'fi') returning id into cl_id;
  s0 := pg_temp.snap(oid);
  perform test.reset_rl();
  v := booking.public_submit_voucher_claim(tok, 'T185VCOPEN1', 'elamyslahjat', null);
  perform pg_temp.ck(v ->> 'code' = 'order_invoiced'
    and (select status from booking.voucher_claims where id = cl_id) = 'open'
    and pg_temp.snap(oid) = s0, '20 avoin pyyntö ei kirjaudu lukitulle');
  select count(*) into n_claims from booking.voucher_claims where order_id = oid;
  perform test.reset_rl();
  v := booking.public_submit_voucher_claim(tok, 'T185VCNEW01', 'kokemuskauppa', null);
  perform pg_temp.ck(v ->> 'code' = 'order_invoiced'
    and (select count(*) from booking.voucher_claims where order_id = oid) = n_claims
    and not exists (select 1 from booking.voucher_claims where code = 'T185VCNEW01')
    and pg_temp.snap(oid) = s0, '20 uusi koodi ei luo pyyntöä');
  v := booking._vc_resolve(cl_id, 'redeemed', null, 't185', 10, 'partner-1', 'staff');
  perform pg_temp.ck((v ->> 'ok') = 'true' and (v -> 'claim' ->> 'needs_review') = 'true' and v ->> 'payment_id' is null
    and (select status from booking.voucher_claims where id = cl_id) = 'redeemed'
    and (select needs_review from booking.voucher_claims where id = cl_id)
    and (select payment_id from booking.voucher_claims where id = cl_id) is null
    and pg_temp.snap(oid) = s0, '20 _vc_resolve needs_review ilman maksua');

  -- ===== 18 oikeudet: migraatio vertaa proacl:ia ennen ja jälkeen samalla oid:lla (b185_acl). Tässä luokka jokaiselle korvatulle funktiolle. =====
  perform pg_temp.ck((
    select bool_and(has_function_privilege('anon', fn, 'execute') and has_function_privilege('authenticated', fn, 'execute'))
      from unnest(array[
        'booking.public_change_treatment_booking(uuid,timestamptz,integer,text)',
        'booking.public_cancel_booking(uuid)',
        'booking.public_get_booking(uuid)',
        'booking.public_get_order(uuid)',
        'booking.public_upsell_for_order(uuid)',
        'booking.public_upsell_add(uuid,jsonb,uuid,bigint)',
        'booking.public_submit_voucher_claim(uuid,text,text,bigint)'
      ]::regprocedure[]) fn), '18 julkiset asiakasfunktiot');
  perform pg_temp.ck((
    select bool_and(not has_function_privilege('anon', fn, 'execute') and has_function_privilege('authenticated', fn, 'execute'))
      from unnest(array[
        'booking.admin_cancel_reservation(bigint,text,boolean,text)',
        'booking.admin_record_payment(bigint,text,numeric,text,jsonb)',
        'booking.admin_get_order(bigint)',
        'booking.admin_set_reservation_addons(bigint,jsonb)'
      ]::regprocedure[]) fn), '18 hallintafunktiot');
  perform pg_temp.ck((
    select bool_and(not has_function_privilege('anon', fn, 'execute') and not has_function_privilege('authenticated', fn, 'execute'))
      from unnest(array[
        'booking._change_booking_core(bigint,bigint,date,integer,boolean,integer,uuid,text)',
        'booking._clamp_addons(bigint,integer)',
        'booking._addon_total_after(bigint,integer)',
        'booking._annual_res_discount_trg()',
        'booking._add_to_order(bigint,jsonb,boolean)',
        'booking._create_link_payment(bigint,integer,text)',
        'booking._gc_redeem(bigint,bigint,numeric,text,boolean)',
        'booking.mobilepay_payment_prepare(uuid,uuid,integer,text)',
        'booking._vc_pay(booking.orders,booking.voucher_claims,numeric)',
        'booking._attach_addons(bigint,jsonb)',
        'booking._ritual_addon_attach(bigint,jsonb)',
        'booking._create_legs_booking(text,bigint,timestamptz,timestamptz,integer,bigint,text,uuid,text,numeric,bigint,boolean,text,boolean,bigint,bigint,text)',
        'booking._create_booking_core(bigint,date,integer,bigint,text,uuid,text,text,text,integer,boolean,timestamptz,timestamptz,numeric,bigint,bigint)',
        'booking._quiet_apply(bigint,jsonb)',
        'booking.vismapay_payment_prepare(uuid,uuid)',
        'booking._vc_resolve(bigint,text,text,text,numeric,text,text)',
        'booking._order_invoice_locked(bigint)',
        'booking._addon_item_locked(bigint)'
      ]::regprocedure[]) fn), '18 sisäfunktiot ilman anon- ja authenticated-oikeutta');

  if mode0 is null then delete from booking.settings where key = 'invoice_dispatch_mode';
  else update booking.settings set value = mode0 where key = 'invoice_dispatch_mode'; end if;
  if redeem0 is null then delete from booking.settings where key = 'gift_cards.redeem_enabled';
  else update booking.settings set value = redeem0 where key = 'gift_cards.redeem_enabled'; end if;
  if hours0 is null then update booking.settings set value = '48'::jsonb where key = 'customer_change_hours_before';
  else update booking.settings set value = hours0 where key = 'customer_change_hours_before'; end if;
  if vc0 is null then delete from booking.settings where key = 'voucher_claims.enabled';
  else update booking.settings set value = vc0 where key = 'voucher_claims.enabled'; end if;
  if visma_mode is not null then update booking.integration_config set mode = visma_mode where key = 'vismapay'; end if;
  if mo_mode is not null then update booking.integration_config set mode = mo_mode where key = 'montonio'; end if;
exception when others then
  raise exception 't185 keskeytyi: %', sqlerrm;
end $t185$;

select format('TESTRESULT pass=%s fail=%s', count(*) filter (where ok), count(*) filter (where not ok)) from t185_r;
select label from t185_r where not ok;
rollback;
