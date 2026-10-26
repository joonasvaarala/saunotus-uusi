-- booking_185: laskutuslukko. Aja migraation ja fixtures/10_test_helpers.sql:n jälkeen.
-- Yksi transaktio, kaikki testivaraukset kumoutuvat lopussa. Ei ajettu tästä työtilasta (ei Tapio-dev-kantaa).
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

do $t185$
declare
  adm uuid := test.mk_staff('admin@t185.example.test', 'admin');
  vrule bigint := test.rule('Miesten sauna%');
  dt date := test.next_dow(1) + 98;
  mode0 jsonb; redeem0 jsonb; hours0 jsonb;
  b jsonb; v jsonb; s0 jsonb; s1 jsonb;
  oid bigint; res_id bigint; item_id bigint; inv bigint; tok uuid; persons0 int; total0 numeric; pay_id bigint;
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
  insert into booking.settings(key, value) values ('invoice_dispatch_mode', '"dry_run"'::jsonb)
    on conflict (key) do update set value = '"dry_run"'::jsonb;
  insert into booking.settings(key, value) values ('gift_cards.redeem_enabled', 'true'::jsonb)
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
  v := pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, true, false)', inv));
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
  values ('T185LOCK0001', 'own', 'value', 50, 50, 'active', 'native', 'at_redemption', 'native', true, current_date + 100)
  returning id into gc_id;
  v := pg_temp.as_(adm, format('select booking.admin_redeem_gift_card(%s, %L, 10, null)', oid, 'T185LOCK0001'));
  perform pg_temp.ck(v ->> 'err' = 'order_invoiced' and pg_temp.snap(oid) = s0, '1 admin_redeem_gift_card');
  v := booking.public_apply_gift_card(tok, 'T185LOCK0001', 10);
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
  perform pg_temp.ck(v ->> 'err' = 'capacity_exceeded' and (select persons from booking.reservations where id = res_id) = persons0 and pg_temp.snap(oid) = s0, '3 kapasiteetti ' || coalesce(v ->> 'err', ''));

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
  v := pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, true, false)', inv));
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
    select q.starts_at into tstart from booking.public_treatment_availability(tprod, current_date + 14, current_date + 50, 2) q where q.status = 'available' order by 1 limit 1;
    select q.starts_at into tstart2 from booking.public_treatment_availability(tprod, current_date + 14, current_date + 50, 2) q where q.status = 'available' and q.starts_at > tstart + interval '1 day' order by 1 limit 1;
  end if;
  perform pg_temp.ck(tstart is not null and tstart2 is not null, '4b hoitoaika löytyi');
  if tstart is not null then
    b := booking.public_create_treatment_booking(tprod, tstart, 2, 'Testi Asiakas', 'tr@t185.example.test', '+358401112233', false, 'fi', null, 'private', null, null);
    perform pg_temp.ck((b ->> 'ok')::boolean, '4b hoito varattu ' || coalesce(b ->> 'code', ''));
    if coalesce((b ->> 'ok')::boolean, false) then
      tok_t := (b ->> 'token')::uuid;
      oid_t := (select id from booking.orders where public_token = tok_t);
      select id into res_t from booking.reservations where order_id = oid_t and status = 'confirmed' order by id limit 1;
      total0 := (select total_gross from booking.orders where id = oid_t);
      v := pg_temp.as_(adm, format('select booking.admin_record_payment(%s, %L, %s, null, null)', oid_t, 'card_terminal', total0));
      update booking.orders set payment_status = 'invoiced' where id = oid_t;
      select id into inv_t from booking.invoices where order_id = oid_t and kind = 'debit';
      v := pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, true, false)', inv_t));
      s0 := pg_temp.snap(oid_t);
      v := booking.public_change_treatment_booking(tok_t, null, 3, null);
      perform pg_temp.ck(v ->> 'code' = 'order_invoiced' and pg_temp.snap(oid_t) = s0, '4b hoito henkilömäärä');
      v := booking.public_change_treatment_booking(tok_t, tstart2, null, null);
      perform pg_temp.ck(coalesce((v ->> 'ok')::boolean, false) and v ->> 'code' is distinct from 'price_change_requires_staff' and pg_temp.snap(oid_t) = s0, '4b hoito aikasiirto');
      v := booking.public_change_treatment_booking(tok_t, tstart2, 1, null);
      perform pg_temp.ck(v ->> 'code' = 'order_invoiced' and pg_temp.snap(oid_t) = s0, '4b hoito siirto ja henkilömäärä');
    end if;
  end if;

  -- lukitsematon asiakasmuutos
  b := test.pub_book(vrule, dt + 56, 2, 'open@t185.example.test');
  v := booking.public_change_booking((b ->> 'token')::uuid, null, null, 3);
  perform pg_temp.ck(coalesce((v ->> 'ok')::boolean, false) and v ->> 'code' is distinct from 'order_invoiced', '4c lukitsematon henkilömäärä ' || coalesce(v ->> 'code', 'ok'));

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

  b := test.pub_book(vrule, dt + 70, 2, 'link@t185.example.test');
  oid := (test.ord((b ->> 'token')::uuid)).id;
  select id, order_item_id into res_id, item_id from booking.reservations where order_id = oid limit 1;
  v := pg_temp.as_(adm, format('select booking.admin_set_reservation_addons(%s, %L::jsonb)', res_id, jsonb_build_array(jsonb_build_object('id', addon_id, 'quantity', 2))::text));
  v := pg_temp.as_(adm, format('select booking.admin_create_payment_link(%s, false, null, null)', oid));
  perform pg_temp.ck(v ->> 'err' is null, '6 takarajaton linkki ' || coalesce(v ->> 'err', ''));
  select id, amount into pay_id, link_amt from booking.payments where order_id = oid and status = 'pending' and provider = 'visma_pay' order by id desc limit 1;
  perform pg_temp.ck((select link_expires_at is null and raw ->> 'paylink' = 'no_deadline' from booking.payments where id = pay_id), '6 linkki on takarajaton');
  v := pg_temp.as_(adm, format('select booking.admin_change_booking(%s, null, null, 1)', res_id));
  perform pg_temp.ck(coalesce(v ->> 'ok', '') = 'true'
    and (select status from booking.payments where id = pay_id) = 'pending'
    and (select amount from booking.payments where id = pay_id) = link_amt, '6 linkkirivi säilyi');
  perform pg_temp.ck(exists (select 1 from booking.order_items where parent_item_id = item_id and kind = 'addon' and price_breakdown ->> 'clamped_from' is not null)
    or (select quantity from booking.order_items where parent_item_id = item_id and kind = 'addon' order by id limit 1) <= 1, '6 maksamaton lisäpalvelu rajattiin');

  -- ===== 8 linkki ja sitten lasku =====
  b := test.pub_book(vrule, dt + 77, 2, 'vp@t185.example.test');
  tok := (b ->> 'token')::uuid;
  oid := (test.ord(tok)).id;
  v := pg_temp.as_(adm, format('select booking.admin_create_payment_link(%s, false, null, null)', oid));
  perform pg_temp.ck(v ->> 'err' is null, '8 linkki ennen laskua');
  select link_token into link_tok from booking.payments where order_id = oid and status = 'pending' and provider = 'visma_pay' order by id desc limit 1;
  update booking.orders set payment_status = 'invoiced' where id = oid;
  select id into inv from booking.invoices where order_id = oid and kind = 'debit';
  v := pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, true, false)', inv));
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
  update booking.integration_config set mode = 'test' where key = 'vismapay';

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
  v := pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, true, false)', inv));
  v := pg_temp.as_(adm, format('select booking.admin_credit_invoice(%s)', inv));
  perform pg_temp.ck(v ->> 'err' is null and (select status from booking.invoices where id = inv) = 'credited', '9 hyvityslasku ' || coalesce(v ->> 'err', ''));
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
  perform pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, true, false)', inv));
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
  perform pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, true, false)', inv));
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
  perform pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, true, false)', inv));
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
  perform pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, true, false)', inv));
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
  perform pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, true, false)', inv));
  s0 := pg_temp.snap(oid);
  v := pg_temp.as_(adm, format('select booking.admin_move_reservation_space(%s, %L, %L)', res_id, space_code, 't185'));
  perform pg_temp.ck(v ->> 'err' is distinct from 'order_invoiced' and pg_temp.snap(oid) = s0, '14 tilan siirto ' || coalesce(v ->> 'err', v ->> 'ok', ''));
  v := pg_temp.as_(adm, format('select booking.admin_set_reservation_option(%s, null, false)', res_id));
  perform pg_temp.ck(v ->> 'err' is distinct from 'order_invoiced' and pg_temp.snap(oid) = s0, '14 hoito/valinta ' || coalesce(v ->> 'err', v ->> 'ok', ''));

  -- ===== 15 vuosikortin alennustriggeri suoralla päivityksellä =====
  b := test.pub_book(vrule, dt + 140, 2, 'ann@t185.example.test');
  oid := (test.ord((b ->> 'token')::uuid)).id;
  select r.id, r.order_item_id into res_id, item_id from booking.reservations r where r.order_id = oid limit 1;
  update booking.orders set payment_status = 'invoiced' where id = oid;
  select id into inv from booking.invoices where order_id = oid and kind = 'debit';
  perform pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, true, false)', inv));
  update booking.order_items set line_total_gross = 0, unit_price_gross = 0, discount_amount = -1, discount_code_id = null where id = item_id;
  update booking.reservations set persons = persons where id = res_id;
  perform pg_temp.ck((select discount_amount from booking.order_items where id = item_id) = -1, '15 triggeri ei päivitä discount_amountia laskulukossa');

  -- ===== 16 julkiset kentät =====
  b := test.pub_book(vrule, dt + 147, 2, 'get@t185.example.test');
  tok := (b ->> 'token')::uuid;
  perform pg_temp.ck((booking.public_get_booking(tok) ->> 'invoice_locked') = 'false', '16 booking lukitsematon');
  perform pg_temp.ck((booking.public_get_order(tok) ->> 'invoice_locked') = 'false', '16 order invoice_locked false');
  update booking.orders set payment_status = 'invoiced' where id = (test.ord(tok)).id;
  select id into inv from booking.invoices where order_id = (test.ord(tok)).id and kind = 'debit';
  perform pg_temp.as_(adm, format('select booking.admin_send_invoice(%s, true, false)', inv));
  perform pg_temp.ck((booking.public_get_booking(tok) ->> 'invoice_locked') = 'true', '16 booking lukittu');
  perform pg_temp.ck((booking.public_get_order(tok) ->> 'can_add') = 'false' and (booking.public_get_order(tok) ->> 'invoice_locked') = 'true', '16 order can_add false');
  perform pg_temp.ck(booking.public_upsell_for_order(tok) = jsonb_build_object('products', '[]'::jsonb, 'addons', '[]'::jsonb), '16 upsell tyhjä');
  v := pg_temp.as_(adm, format('select booking.admin_get_order(%s)', (test.ord(tok)).id));
  perform pg_temp.ck((v ->> 'invoice_locked') = 'true' and v ->> 'invoice_no' is not null and (v ->> 'can_add') = 'false' and (v ->> 'staff_can_add') = 'false', '16 admin_get_order');

  -- ===== 17 link_stale =====
  b := test.pub_book(vrule, dt + 154, 2, 'stale@t185.example.test');
  oid := (test.ord((b ->> 'token')::uuid)).id;
  select id into res_id from booking.reservations where order_id = oid limit 1;
  v := pg_temp.as_(adm, format('select booking.admin_create_payment_link(%s, false, null, null)', oid));
  select id, amount into pay_id, total0 from booking.payments where order_id = oid and status = 'pending' and provider = 'visma_pay' order by id desc limit 1;
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

  -- ===== 18 oikeudet =====
  perform pg_temp.ck(not has_function_privilege('anon', 'booking.admin_get_order(bigint)', 'execute')
    and not has_function_privilege('anon', 'booking.admin_record_payment(bigint,text,numeric,text,jsonb)', 'execute')
    and not has_function_privilege('anon', 'booking._order_invoice_locked(bigint)', 'execute')
    and not has_function_privilege('anon', 'booking._addon_item_locked(bigint)', 'execute')
    and not has_function_privilege('authenticated', 'booking._order_invoice_locked(bigint)', 'execute')
    and not has_function_privilege('authenticated', 'booking._addon_item_locked(bigint)', 'execute'), '18 anon ja authenticated ilman apufunktioita');
  perform pg_temp.ck(has_function_privilege('anon', 'booking.public_cancel_booking(uuid)', 'execute')
    and has_function_privilege('anon', 'booking.public_get_booking(uuid)', 'execute'), '18 julkiset oikeudet säilyvät');

  if mode0 is null then delete from booking.settings where key = 'invoice_dispatch_mode';
  else update booking.settings set value = mode0 where key = 'invoice_dispatch_mode'; end if;
  if redeem0 is null then delete from booking.settings where key = 'gift_cards.redeem_enabled';
  else update booking.settings set value = redeem0 where key = 'gift_cards.redeem_enabled'; end if;
  if hours0 is null then update booking.settings set value = '48'::jsonb where key = 'customer_change_hours_before';
  else update booking.settings set value = hours0 where key = 'customer_change_hours_before'; end if;
exception when others then
  raise exception 't185 keskeytyi: %', sqlerrm;
end $t185$;

select format('TESTRESULT pass=%s fail=%s', count(*) filter (where ok), count(*) filter (where not ok)) from t185_r;
select label from t185_r where not ok;
rollback;
