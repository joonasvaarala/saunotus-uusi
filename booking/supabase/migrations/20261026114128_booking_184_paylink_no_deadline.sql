-- booking_184: henkilökunnan maksulinkki oletuksena ILMAN takarajaa (omistaja Joonas 26.10.2026). Takaraja valinnainen 1–60 päivää. Asiakkaan oma
-- tilaussivu (_public_pay_json 14 vrk) ja pikakassa (admin_pos_send_link 1 vrk) ennallaan. Edge-funktiot ennallaan.
--   * Takarajaton linkki = payments.link_expires_at null JA raw.paylink = 'no_deadline' (merkintä asetetaan _create_link_payment-insertissä).
--     Merkintä tarvitaan, koska verkkokaupan maksurivit (public_create_booking / public_buy_gift_card / public_buy_annual_card) luodaan myös
--     link_expires_at null -arvolla; ne EIVÄT ole maksulinkkejä (peruttu Visma-maksu → cancelled kuten ennen).
--   * _create_link_payment: p_expires_days oletus null (= ei takarajaa), muuten 1–60. Uudelleenkäyttö (yksi avoin Visma-rivi, sama summa):
--     takarajaton pyyntö käyttää vain merkittyä takarajatonta linkkiä; takarajallinen pyyntö käyttää avointa riviä kuten ennen, paitsi henkilökunta
--     (is_staff) korvaa takarajattoman linkin uudella takarajallisella. → Asiakkaan tilaussivu / pikakassa eivät peru henkilökunnan takarajatonta linkkiä.
--   * admin_create_payment_link: p_expires_days oletus null. admin_add_to_order ja _vc_redeem: 14 → null (ei takarajaa).
--   * vismapay_payment_apply: maksulinkki = (link_expires_at null ja merkitty) tai link_expires_at - created_at > 2 h (booking_178). Merkitsemätön
--     null-rivi = verkkokaupan maksu, kuten ennen.
--   * mobilepay_payment_prepare: QR/PUSH_MESSAGE 20 min katkaisu vain verkkokaupan maksulle (p_link_token null eikä rivi ole maksulinkki).
--   * expire_payment_links ohittaa null-rivit (ennallaan) → takarajaton linkki ei vanhene; henkilökunta peruu tarvittaessa.
--   muutetut funktiot (tuotanto ennen → booking_184), md5(pg_get_functiondef):
--     booking._create_link_payment(bigint,integer,text): 533ac9af831c0c11e1f504e377a17827 -> 5e432077c560a10822db8ac0d2bbe7c2
--     booking.admin_create_payment_link(bigint,boolean,integer,text): fef2fe9aa3acf79b233086c133809918 -> 80004933a80f77a10fcf625f493a20ef
--     booking.admin_add_to_order(bigint,jsonb,boolean,boolean,text): f615f168c9af7a2f721ab2e9a7f59559 -> 5babbf859133aebd3e9e7c827bee3261
--     booking._vc_redeem(bigint,numeric,text,text,text): 6f52789346960d95370169446a61451b -> 2aa8e44cb2c6f150d3488f53f8d94c25
--     booking.vismapay_payment_apply(text,text,numeric,jsonb): 03fbbd2486b2c22dfa02d7ec84da626f -> 2f8a7e56ae9bb4e29f4025f91e7ea706
--     booking.mobilepay_payment_prepare(uuid,uuid,integer,text): 779fa5276d12e3a671a7ac394310fe97 -> 37573920d2f9f882e3d95c4f0c66575f
--   Oikeudet, SECURITY DEFINER, search_path='' ja omistaja ennallaan (CREATE OR REPLACE säilyttää; revoke/grant toistetaan varmuuden vuoksi).
--   riippuvuudet, ei muuteta (tuotanto = vaadittu, luettu sxbofnuisemspgquoxyv 26.10.2026 SELECTillä): ks. vartiolohko.
-- Rollback: rollbacks/20261026120000_booking_184_ROLLBACK.sql. Testi: tests/checkout/t184_paylink_no_deadline.sql (BEGIN … ROLLBACK).
set local lock_timeout = '5s';

do $g$
declare v text; ok boolean := true; msg text := '';
begin
  v := md5(pg_get_functiondef(to_regprocedure('booking._create_link_payment(bigint,integer,text)')));
  if v is null or v <> '533ac9af831c0c11e1f504e377a17827' then ok := false; msg := msg || ' _create_link_payment=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_create_payment_link(bigint,boolean,integer,text)')));
  if v is null or v <> 'fef2fe9aa3acf79b233086c133809918' then ok := false; msg := msg || ' admin_create_payment_link=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_add_to_order(bigint,jsonb,boolean,boolean,text)')));
  if v is null or v <> 'f615f168c9af7a2f721ab2e9a7f59559' then ok := false; msg := msg || ' admin_add_to_order=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._vc_redeem(bigint,numeric,text,text,text)')));
  if v is null or v <> '6f52789346960d95370169446a61451b' then ok := false; msg := msg || ' _vc_redeem=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.vismapay_payment_apply(text,text,numeric,jsonb)')));
  if v is null or v <> '03fbbd2486b2c22dfa02d7ec84da626f' then ok := false; msg := msg || ' vismapay_payment_apply=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.mobilepay_payment_prepare(uuid,uuid,integer,text)')));
  if v is null or v <> '779fa5276d12e3a671a7ac394310fe97' then ok := false; msg := msg || ' mobilepay_payment_prepare=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._public_pay_json(bigint)')));
  if v is null or v <> 'cc3e61dbdfbd9a816cd9c982c73820c5' then ok := false; msg := msg || ' _public_pay_json=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.payment_prepare(bigint)')));
  if v is null or v <> 'ff791e6b919cdab466024182a4f663af' then ok := false; msg := msg || ' payment_prepare=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_pos_send_link(bigint,text,boolean)')));
  if v is null or v <> '735e92d8c8c52784bbba9b928c5a122b' then ok := false; msg := msg || ' admin_pos_send_link=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_add_to_order(uuid,jsonb)')));
  if v is null or v <> 'a7eaf138bff841c31f35ca4961065d12' then ok := false; msg := msg || ' public_add_to_order=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_change_order_time(uuid,bigint,timestamp with time zone,bigint,date,integer,text)')));
  if v is null or v <> '5c5d195c5720d872dbbf9f97a49f2558' then ok := false; msg := msg || ' public_change_order_time=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_mark_voucher_claim_redeemed(bigint,numeric,text,text)')));
  if v is null or v <> 'a4e69cb26eb44b72eacce7c167342884' then ok := false; msg := msg || ' admin_mark_voucher_claim_redeemed=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.svc_mark_voucher_claim_redeemed(bigint,numeric,text,text)')));
  if v is null or v <> '673f26a88054b2b31dcbab872557e383' then ok := false; msg := msg || ' svc_mark_voucher_claim_redeemed=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.vismapay_payment_prepare(uuid,uuid)')));
  if v is null or v <> '703c03c301f5a3008192cdbe65e559e2' then ok := false; msg := msg || ' vismapay_payment_prepare=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.vismapay_payment_event(text,text,text,text,jsonb)')));
  if v is null or v <> 'e6834eb7c9da8a0a8c531706eb6692fc' then ok := false; msg := msg || ' vismapay_payment_event=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.mobilepay_payment_event(text,text,text,jsonb)')));
  if v is null or v <> '44ef51b60eeb7e2abbff80c15636bfa0' then ok := false; msg := msg || ' mobilepay_payment_event=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.payment_mark_paid(text,text,numeric,jsonb)')));
  if v is null or v <> '8ceb0a7dea60d37e3ea6a17cec0e4c25' then ok := false; msg := msg || ' payment_mark_paid=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.payment_mark_failed(text,text,text,jsonb)')));
  if v is null or v <> '2dfe2d2c0757157be90484d60cef8046' then ok := false; msg := msg || ' payment_mark_failed=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.expire_payment_links()')));
  if v is null or v <> '0109d701ab1ccc4e57f6210989644f5c' then ok := false; msg := msg || ' expire_payment_links=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_payment_link_info(uuid)')));
  if v is null or v <> '647c556562046c75b7e7e33703c050a0' then ok := false; msg := msg || ' public_payment_link_info=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._order_balance(bigint)')));
  if v is null or v <> 'a6b31f93559de53d75a52d8a285f1170' then ok := false; msg := msg || ' _order_balance=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._link_json(bigint)')));
  if v is null or v <> '6244354a24ab97f251f9f80c4b240e1b' then ok := false; msg := msg || ' _link_json=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.is_staff()')));
  if v is null or v <> '40d8b86aa41ab71f29ef4e6c5257aa77' then ok := false; msg := msg || ' is_staff=' || coalesce(v, 'puuttuu'); end if;
  if (select data_type from information_schema.columns where table_schema = 'booking' and table_name = 'payments' and column_name = 'raw') is distinct from 'jsonb'
     or (select data_type from information_schema.columns where table_schema = 'booking' and table_name = 'payments' and column_name = 'link_expires_at') is distinct from 'timestamp with time zone' then ok := false; msg := msg || ' payments.raw/link_expires_at'; end if;
  if not ok then raise exception 'booking_184: tuotannon määrittelyt eivät vastaa odotettua:%. Ei muutoksia.', msg; end if;
end $g$;

CREATE OR REPLACE FUNCTION booking._create_link_payment(p_order_id bigint, p_expires_days integer DEFAULT NULL::integer, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- booking_184: p_expires_days null = maksulinkki ilman takarajaa (link_expires_at null, raw.paylink = 'no_deadline'); muuten 1–60 päivää kuten ennen.
-- Uudelleenkäyttö (sama summa, yksi avoin Visma-rivi): takarajaton pyyntö käyttää vain merkittyä takarajatonta linkkiä; takarajallinen pyyntö käyttää
-- avointa riviä kuten ennen, paitsi henkilökunta (is_staff) korvaa takarajattoman linkin takarajallisella. Asiakkaan/järjestelmän polut eivät siis peru
-- henkilökunnan takarajatonta linkkiä, kun summa ei muutu.
declare o booking.orders; v_tot numeric; v_open booking.payments; v_n int; v_id bigint; v_token uuid; v_exp timestamptz; v_unpaid numeric; v_open_nd boolean;
begin
  select * into o from booking.orders where id = p_order_id for update;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if o.external_source is not null or o.status not in ('pending','confirmed','completed') then perform booking._err('order_not_editable', 'Tilaukselle ei voi luoda maksulinkkiä'); end if;
  if p_expires_days is not null and (p_expires_days < 1 or p_expires_days > 60) then perform booking._err('invalid_param', 'Linkin voimassaolo 1–60 päivää'); end if;
  select coalesce(sum(remaining) filter (where remaining > 0), 0) into v_tot from booking._order_uncovered(o.id, false);
  v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;
  v_tot := least(v_tot, v_unpaid);
  if v_tot <= 0.004 then perform booking._err('nothing_to_pay', 'Ei maksettavaa'); end if;
  select count(*) into v_n from booking.payments where order_id = o.id and status = 'pending' and provider = 'visma_pay' and (link_expires_at is null or link_expires_at > now());
  if v_n = 1 then
    select * into v_open from booking.payments where order_id = o.id and status = 'pending' and provider = 'visma_pay' and (link_expires_at is null or link_expires_at > now());
    v_open_nd := v_open.link_expires_at is null and coalesce(v_open.raw ->> 'paylink', '') = 'no_deadline';
    if v_open.amount = v_tot and (case when p_expires_days is null then v_open_nd
                                       when v_open_nd then not booking.is_staff()
                                       else true end) then
      return jsonb_build_object('payment_id', v_open.id, 'link_token', v_open.link_token, 'amount', v_open.amount, 'expires_at', v_open.link_expires_at, 'reused', true);
    end if;
  end if;
  update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'korvattu uudella maksulinkillä')
   where order_id = o.id and status = 'pending' and provider = 'visma_pay';
  v_exp := case when p_expires_days is null then null else now() + make_interval(days => p_expires_days) end;
  insert into booking.payments(order_id, method, provider, status, amount, currency, link_expires_at, raw, note, created_by)
  values (o.id, 'visma_pay', 'visma_pay', 'pending', v_tot, o.currency, v_exp,
          case when v_exp is null then jsonb_build_object('paylink', 'no_deadline') end, p_note, auth.uid()) returning id, link_token into v_id, v_token;
  insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
  select v_id, item_id, description, kind, quantity, remaining, vat_rate from booking._order_uncovered(o.id, false) where remaining > 0;
  -- jos rivit ylittävät jäännöksen (poikkeus: hyvitetty/poistettu rivi), pienennetään suurinta riviä
  update booking.payment_lines set amount_gross = amount_gross - ((select sum(amount_gross) from booking.payment_lines where payment_id = v_id) - v_tot)
   where id = (select id from booking.payment_lines where payment_id = v_id order by amount_gross desc, id limit 1)
     and (select sum(amount_gross) from booking.payment_lines where payment_id = v_id) > v_tot;
  perform booking._refresh_order_payment(o.id);
  return jsonb_build_object('payment_id', v_id, 'link_token', v_token, 'amount', v_tot, 'expires_at', v_exp, 'reused', false);
end $function$
;

CREATE OR REPLACE FUNCTION booking.admin_create_payment_link(p_order_id bigint, p_send_email boolean DEFAULT false, p_expires_days integer DEFAULT NULL::integer, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v jsonb; v_pid bigint; v_mail boolean := false;
begin
  perform booking._require_permission('payments.manage');
  v := booking._create_link_payment(p_order_id, p_expires_days, p_note);
  v_pid := (v ->> 'payment_id')::bigint;
  if p_send_email then v_mail := booking._enqueue_email('payment_link', p_order_id, null, v_pid, 'payment_link:' || v_pid || ':' || to_char(now(), 'YYYYMMDDHH24MI')); end if;
  return jsonb_build_object('ok', true) || (booking._link_json(v_pid)) || jsonb_build_object('online_payment_enabled', booking._vismapay_online(), 'email_queued', v_mail);
end $function$
;

CREATE OR REPLACE FUNCTION booking.admin_add_to_order(p_order_id bigint, p_items jsonb, p_create_link boolean DEFAULT false, p_send_email boolean DEFAULT false, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v jsonb; v_pay jsonb; v_link jsonb := null; v_mail boolean := false; v_pid bigint; v_code text;
begin
  perform booking._require_permission('bookings.manage');
  v := booking._add_to_order(p_order_id, p_items, true);
  if p_note is not null then update booking.orders set internal_note = concat_ws(E'\n', internal_note, btrim(p_note)) where id = p_order_id; end if;
  if p_create_link or p_send_email then
    begin
      v_pay := booking._create_link_payment(p_order_id, null::integer, p_note);   -- booking_184: ei takarajaa
      v_pid := (v_pay ->> 'payment_id')::bigint;
      v_link := booking._link_json(v_pid);
      if p_send_email then
        v_mail := booking._enqueue_email('payment_link', p_order_id, null, v_pid, 'payment_link:' || v_pid || ':' || to_char(now(), 'YYYYMMDDHH24MI'));
      end if;
    exception when sqlstate 'BK001' then
      get stacked diagnostics v_code = pg_exception_detail;
      if v_code is distinct from 'nothing_to_pay' then raise; end if;
    end;
  end if;
  return jsonb_build_object('ok', true, 'order_id', p_order_id, 'added', v -> 'added', 'added_total', v -> 'added_total',
                            'balance', booking._order_balance(p_order_id),
                            'payment', case when v_link is null then null else v_link - 'lines' end, 'email_queued', v_mail);
end $function$
;

CREATE OR REPLACE FUNCTION booking._vc_redeem(p_id bigint, p_amount numeric, p_partner_ref text, p_note text, p_by text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c booking.voucher_claims; o booking.orders; v jsonb; v_due numeric; v_link jsonb; v_pid bigint; v_diff numeric; v_mail boolean := false;
begin
  if p_amount is not null then
    if p_amount <= 0 or p_amount <> round(p_amount, 2) then perform booking._err('invalid_amount', 'Lahjakortin arvon pitää olla yli 0 € (enintään 2 desimaalia)'); end if;
    select * into c from booking.voucher_claims where id = p_id for update;
    if found and c.status in ('open', 'processing', 'problem') then
      select * into o from booking.orders where id = c.order_id for update;
      if found and o.status in ('pending', 'confirmed') and o.external_source is null then
        v_due := booking._vc_due(o, c);
        if p_amount > v_due then
          perform booking._err('voucher_exceeds_total', format('Lahjakortin arvo %s € ylittää maksettavan summan %s €', p_amount, v_due));
        end if;
      end if;
    end if;
  end if;
  v := booking._vc_mark_redeemed(p_id, p_amount, p_partner_ref, p_note, p_by);
  -- booking_174 (booking_176: myös botti): arvo pienempi kuin maksettava → erotus maksulinkkinä asiakkaalle (Visma Pay -linkki, sähköposti payment_link / voucher_difference)
  if v_due is not null and p_amount < v_due and not coalesce((v ->> 'already')::boolean, false) and (v ->> 'payment_id') is not null then
    select * into o from booking.orders where id = o.id;
    v_link := booking._create_link_payment(o.id, null::integer, 'Kumppanilahjakortin erotus, pyyntö #' || p_id);   -- booking_184: ei takarajaa
    v_pid := (v_link ->> 'payment_id')::bigint;
    v_diff := (v_link ->> 'amount')::numeric;
    v_mail := booking._enqueue_email('payment_link', o.id, null, v_pid, 'payment_link:voucher_difference:' || p_id || ':' || v_pid,
                jsonb_build_object('variant', 'voucher_difference', 'claim_id', p_id, 'voucher_value', (v ->> 'amount')::numeric, 'difference', v_diff,
                                   'total', (v ->> 'amount')::numeric + v_diff));
    -- booking_176: erotuksen maksusta ei kuittisähköpostia (_on_payment_paid)
    insert into booking.vc_difference_payments(order_id, claim_id, payment_id) values (o.id, p_id, v_pid) on conflict (payment_id) do nothing;
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
    values (auth.uid(), booking._jwt_role(), 'booking.voucher_claims', p_id::text, 'VOUCHER_DIFFERENCE_LINK', null,
            jsonb_build_object('voucher_value', (v ->> 'amount')::numeric, 'due', v_due, 'difference', v_diff, 'link_payment_id', v_pid, 'email_queued', v_mail, 'by', p_by));
  end if;
  return v || jsonb_build_object('voucher_value', case when (v ->> 'already')::boolean then null else (v ->> 'amount')::numeric end, 'due', v_due,
    'difference', v_diff, 'payment_link', case when v_pid is not null then booking._link_json(v_pid) || jsonb_build_object('online_payment_enabled', booking._vismapay_online()) end,
    'email_queued', v_mail);
end $function$
;

CREATE OR REPLACE FUNCTION booking.vismapay_payment_apply(p_order_number text, p_outcome text, p_amount numeric DEFAULT NULL::numeric, p_raw jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- booking_178: (1) maksulinkki (link_expires_at - created_at > 2 h, eli _create_link_payment; booking_184: myös takarajaton linkki = link_expires_at null
-- ja raw.paylink = 'no_deadline'; verkkokaupan maksurivi, jolla link_expires_at null ilman merkintää, EI ole linkki) EI kulu peruttuun/hylättyyn Visma-yritykseen: maksu jää
-- pending-tilaan, vanha Visma-token/ohjausosoite poistetaan (vismapay_payment_prepare luo seuraavalla painalluksella uuden yrityksen -a<n+1>), kun linkki on
-- voimassa, ei korvattu ja tilauksella on maksettavaa (summa ≤ maksamatta). Muuten ja verkkokaupan tavallisessa maksussa kuten ennen (cancelled/failed).
-- (2) vanhan yrityksen tilausnumero löytyy booking.vismapay_attempts-taulusta: myöhästynyt "maksettu" kirjataan samalle maksuriville täsmälleen kerran
-- (provider_ref vaihdetaan maksaneeseen yritykseen, jotta hyvitys osuu oikeaan Visma-tilaukseen); jos rivi on jo maksettu toisella yrityksellä, maksua ei
-- kirjata toista kertaa vaan tilaukselle merkitään TUPLAVELOITUS tarkistettavaksi (outcome needs_review, code duplicate_paid). Vanhan yrityksen
-- peruutus/hylkäys ei muuta maksua.
declare
  pay booking.payments; att booking.vismapay_attempts;
  v_raw jsonb := coalesce(p_raw, '{}'::jsonb); v_res jsonb; v_current boolean; v_unpaid numeric; v_why text; v_prev text;
begin
  if p_order_number is null or p_order_number !~ '^sauna-[a-z0-9_-]+$' then
    return jsonb_build_object('ok', false, 'code', 'invalid_param');
  end if;
  if p_outcome is null or p_outcome not in ('paid', 'failed', 'cancelled', 'pending', 'authorized', 'needs_review') then
    return jsonb_build_object('ok', false, 'code', 'invalid_param');
  end if;
  select * into pay from booking.payments where provider = 'visma_pay' and provider_ref = p_order_number for update;
  if not found then
    select * into att from booking.vismapay_attempts where order_number = p_order_number;
    if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
    select * into pay from booking.payments where id = att.payment_id and provider = 'visma_pay' for update;
    if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  end if;
  select * into att from booking.vismapay_attempts where order_number = p_order_number for update;
  v_current := pay.provider_ref is not distinct from p_order_number;

  if pay.status in ('paid', 'partially_refunded', 'refunded') then
    if p_outcome = 'paid' and not v_current then
      -- sama maksurivi on jo maksettu toisella Visma-yrityksellä → ei toista kirjausta; rahat palautetaan käsin
      if att.outcome is distinct from 'duplicate_paid' then
        update booking.vismapay_attempts set outcome = 'duplicate_paid', outcome_at = now() where order_number = p_order_number;
        update booking.orders set internal_note = coalesce(internal_note || E'\n', '') || 'VISMA PAY: TUPLAVELOITUS – maksu ' || coalesce(pay.provider_ref, '?')
               || ' on jo kirjattu, myös ' || p_order_number || ' maksettiin. Palauta ' || p_order_number || ' Visma Payn hallinnasta.' where id = pay.order_id;
        insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
        values (null, 'service_role', 'payments', pay.id::text, 'VISMAPAY_DUPLICATE_PAID',
                jsonb_build_object('order_number', p_order_number, 'paid_order_number', pay.provider_ref, 'reported', p_amount, 'payment_status', pay.status));
      end if;
      return jsonb_build_object('ok', true, 'already', true, 'outcome', 'needs_review', 'code', 'duplicate_paid');
    end if;
    if pay.status = 'paid' or p_outcome = 'paid' then
      return jsonb_build_object('ok', true, 'already', true, 'outcome', 'paid');
    end if;
  end if;
  if pay.status in ('failed', 'cancelled', 'refunded') and p_outcome in ('failed', 'cancelled', 'pending', 'authorized') then
    if not v_current and p_outcome in ('failed', 'cancelled') and att.order_number is not null and att.outcome is null then
      update booking.vismapay_attempts set outcome = p_outcome, outcome_at = now() where order_number = p_order_number;
    end if;
    return jsonb_build_object('ok', true, 'unchanged', true, 'outcome', pay.status);
  end if;

  if p_outcome = 'paid' then
    if p_amount is null or round(p_amount * 100) <> round(pay.amount * 100) then
      update booking.payments set provider_status = 'amount_mismatch', raw = coalesce(raw, '{}'::jsonb) || jsonb_build_object('amount_mismatch', true, 'reported_amount', p_amount) where id = pay.id;
      update booking.orders set internal_note = coalesce(internal_note || E'\n', '') || 'VISMA PAY: summa ei täsmää, maksua ei merkitty maksetuksi (' || p_order_number || ')' where id = pay.order_id;
      insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
      values (null, 'service_role', 'payments', pay.id::text, 'VISMAPAY_AMOUNT_MISMATCH', jsonb_build_object('order_number', p_order_number, 'reported', p_amount, 'expected', pay.amount));
      return jsonb_build_object('ok', true, 'outcome', 'needs_review', 'code', 'amount_mismatch');
    end if;
    if not v_current then
      -- myöhästynyt maksu vanhalle yritykselle: rivi siirretään maksaneeseen tilausnumeroon (uudempi yritys merkitään korvatuksi triggerissä)
      v_prev := pay.provider_ref;
      update booking.payments
         set provider_ref = p_order_number,
             link_url = case when link_url like 'https://www.vismapay.com/%' then null else link_url end,
             raw = (coalesce(raw, '{}'::jsonb) - 'token' - 'redirect_url' - 'token_valid_until') || jsonb_build_object('last_state', 'late_paid', 'replaced_ref', v_prev)
       where id = pay.id;
      insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
      values (null, 'service_role', 'payments', pay.id::text, 'VISMAPAY_LATE_PAID', jsonb_build_object('order_number', p_order_number, 'superseded', v_prev, 'status_before', pay.status));
    end if;
    v_res := booking.payment_mark_paid('visma_pay', p_order_number, pay.amount, v_raw || jsonb_build_object('source', v_raw -> 'source'));
    update booking.vismapay_attempts set outcome = 'paid', outcome_at = now() where order_number = p_order_number;
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
    values (null, 'service_role', 'payments', pay.id::text, 'VISMAPAY_PAID', jsonb_build_object('order_number', p_order_number, 'result', v_res));
    return v_res || jsonb_build_object('outcome', 'paid');
  elsif p_outcome = 'needs_review' then
    update booking.payments set provider_status = 'needs_review', raw = coalesce(raw, '{}'::jsonb) || v_raw where id = pay.id;
    update booking.orders set internal_note = coalesce(internal_note || E'\n', '') || 'VISMA PAY: maksu vaatii tarkistuksen (' || p_order_number || ')' where id = pay.order_id;
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
    values (null, 'service_role', 'payments', pay.id::text, 'VISMAPAY_NEEDS_REVIEW', v_raw);
    return jsonb_build_object('ok', true, 'outcome', 'needs_review');
  elsif p_outcome in ('failed', 'cancelled') then
    if not v_current then
      -- vanha yritys peruttu/hylätty: maksu (ja sen uudempi yritys) ennallaan
      if att.order_number is not null and att.outcome is null then
        update booking.vismapay_attempts set outcome = p_outcome, outcome_at = now() where order_number = p_order_number;
        insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
        values (null, 'service_role', 'payments', pay.id::text, 'VISMAPAY_ATTEMPT_' || upper(p_outcome), v_raw || jsonb_build_object('order_number', p_order_number, 'current', pay.provider_ref));
      end if;
      return jsonb_build_object('ok', true, 'unchanged', true, 'stale', true, 'outcome', p_outcome);
    end if;
    if pay.status <> 'pending' then
      return jsonb_build_object('ok', true, 'unchanged', true, 'outcome', pay.status);
    end if;
    if pay.provider_status is not distinct from p_outcome and coalesce(pay.raw ->> 'retryable', '') = 'true' then
      return jsonb_build_object('ok', true, 'unchanged', true, 'retryable', true, 'outcome', p_outcome);
    end if;
    v_unpaid := coalesce((booking._order_balance(pay.order_id) ->> 'unpaid')::numeric, 0);
    if (case when pay.link_expires_at is null then coalesce(pay.raw ->> 'paylink', '') <> 'no_deadline'
             else pay.link_expires_at - pay.created_at <= interval '2 hours' end) then v_why := 'not_link';
    elsif pay.link_expires_at <= now() then v_why := 'link_expired';
    elsif exists (select 1 from booking.payments x where x.order_id = pay.order_id and x.id > pay.id and x.status not in ('cancelled', 'failed')) then v_why := 'replaced';
    elsif v_unpaid <= 0.004 then v_why := 'nothing_to_pay';
    elsif pay.amount > v_unpaid + 0.004 then v_why := 'link_stale';
    end if;
    if v_why is null then
      update booking.payments
         set provider_status = p_outcome,
             link_url = case when link_url like 'https://www.vismapay.com/%' then null else link_url end,
             raw = (coalesce(raw, '{}'::jsonb) - 'token' - 'redirect_url' - 'token_valid_until')
                   || jsonb_build_object('last_state', p_outcome, 'retryable', true, 'detail', v_raw - 'customer' - 'email')
       where id = pay.id;
      update booking.vismapay_attempts set outcome = p_outcome, outcome_at = now() where order_number = p_order_number;
      insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
      values (null, 'service_role', 'payments', pay.id::text, 'VISMAPAY_' || upper(p_outcome) || '_RETRYABLE',
              v_raw || jsonb_build_object('order_number', p_order_number, 'attempt', att.attempt, 'link_expires_at', pay.link_expires_at));
      return jsonb_build_object('ok', true, 'outcome', p_outcome, 'retryable', true);
    end if;
    perform booking.payment_mark_failed('visma_pay', p_order_number, p_outcome, v_raw);
    update booking.vismapay_attempts set outcome = p_outcome, outcome_at = now() where order_number = p_order_number;
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
    values (null, 'service_role', 'payments', pay.id::text, 'VISMAPAY_' || upper(p_outcome),
            case when v_why = 'not_link' then v_raw else v_raw || jsonb_build_object('retry_blocked', v_why) end);
    return jsonb_build_object('ok', true, 'outcome', p_outcome) || case when v_why = 'not_link' then '{}'::jsonb else jsonb_build_object('retryable', false, 'reason', v_why) end;
  else
    if not v_current then
      return jsonb_build_object('ok', true, 'unchanged', true, 'stale', true, 'outcome', p_outcome);
    end if;
    update booking.payments set provider_status = p_outcome, raw = coalesce(raw, '{}'::jsonb) || v_raw where id = pay.id and status = 'pending';
    return jsonb_build_object('ok', true, 'outcome', p_outcome);
  end if;
end $function$
;

CREATE OR REPLACE FUNCTION booking.mobilepay_payment_prepare(p_order_token uuid DEFAULT NULL::uuid, p_link_token uuid DEFAULT NULL::uuid, p_expires_minutes integer DEFAULT 120, p_user_flow text DEFAULT 'WEB_REDIRECT'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_mode text := booking._mobilepay_mode(); o booking.orders; pay booking.payments; v_tot numeric; v_unpaid numeric; v_open booking.payments;
  v_super jsonb := '[]'::jsonb; v_raw jsonb; v_mp jsonb; v_att int; v_ref text; v_id bigint; v_exp timestamptz; r record; v_started timestamptz;
  v_flow text; v_mins integer;
begin
  if v_mode = 'off' then perform booking._err('mobilepay_off', 'MobilePay-verkkomaksu ei ole käytössä'); end if;
  if (p_order_token is null) = (p_link_token is null) then perform booking._err('invalid_param', 'Anna joko p_order_token tai p_link_token'); end if;
  if p_expires_minutes is null or p_expires_minutes < 15 or p_expires_minutes > 1440 then perform booking._err('invalid_param', 'Voimassaolo 15–1440 min'); end if;
  v_flow := upper(btrim(coalesce(p_user_flow, 'WEB_REDIRECT')));
  if v_flow not in ('WEB_REDIRECT', 'QR', 'PUSH_MESSAGE') then perform booking._err('invalid_param', 'userFlow: WEB_REDIRECT, QR tai PUSH_MESSAGE'); end if;
  v_mins := p_expires_minutes;
  if v_flow in ('QR', 'PUSH_MESSAGE') and v_mins > 20 then v_mins := 20; end if;
  if not booking._rate_limit('mpstart:' || coalesce(p_order_token, p_link_token)::text, 12, interval '10 minutes') then perform booking._err('rate_limited', 'Liian monta yritystä, yritä hetken kuluttua uudelleen'); end if;

  if p_link_token is not null then
    select * into pay from booking.payments where link_token = p_link_token for update;
    if not found then perform booking._err('not_found', 'Maksulinkkiä ei löydy'); end if;
    select * into o from booking.orders where id = pay.order_id for update;
  else
    select * into o from booking.orders where public_token = p_order_token for update;
    if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  end if;
  if o.external_source is not null then perform booking._err('order_not_payable', 'Tilausta ei voi maksaa verkossa'); end if;       -- Johku-eristys
  if o.status not in ('pending', 'confirmed', 'completed', 'expired') then perform booking._err('order_not_payable', 'Tilausta ei voi maksaa verkossa'); end if;
  if o.status = 'pending' and o.hold_kind = 'preliminary' then perform booking._err('order_not_payable', 'Alustavaa varausta ei makseta ennen vahvistusta'); end if;
  if v_flow = 'PUSH_MESSAGE' and o.source_channel is distinct from 'pikakassa' then
    perform booking._err('push_not_allowed', 'Mobiilimaksupyyntö on vain pikakassan tilauksille');
  end if;
  if o.currency <> 'EUR' then perform booking._err('unsupported_currency', 'Vain EUR tuettu'); end if;
  v_unpaid := (booking._order_balance(o.id) ->> 'unpaid')::numeric;

  if p_link_token is not null then
    if pay.status = 'paid' then perform booking._err('already_paid', 'Maksu on jo maksettu'); end if;
    if pay.status <> 'pending' then perform booking._err('payment_not_pending', 'Maksulinkki ei ole enää voimassa'); end if;
    if pay.provider not in ('visma_pay', 'mobilepay') then perform booking._err('payment_not_online', 'Ei verkkomaksu'); end if;
    if pay.provider = 'visma_pay' and pay.provider_ref is not null then perform booking._err('other_provider_started', 'Maksu on aloitettu toisella maksutavalla'); end if;
    if pay.link_expires_at is not null and pay.link_expires_at < now() then perform booking._err('link_expired', 'Maksulinkki on vanhentunut'); end if;
    if pay.amount > v_unpaid + 0.004 then perform booking._err('link_stale', 'Maksulinkin summa ei vastaa enää maksamatonta osuutta – pyydä uusi linkki'); end if;
    if pay.provider = 'visma_pay' then   -- asiakas valitsi MobilePayn maksulinkin sivulla: siirretään maksu MobilePaylle
      update booking.payments set provider = 'mobilepay', method = 'mobilepay', note = concat_ws(' | ', note, 'vaihdettu MobilePaylle') where id = pay.id returning * into pay;
    end if;
  else
    select coalesce(sum(remaining) filter (where remaining > 0), 0) into v_tot from booking._order_uncovered(o.id, false);
    v_tot := least(v_tot, v_unpaid);
    if v_tot <= 0.004 then
      if exists (select 1 from booking.payments where order_id = o.id and status in ('paid', 'partially_refunded', 'refunded')) then perform booking._err('already_paid', 'Tilaus on jo maksettu'); end if;
      perform booking._err('nothing_to_pay', 'Ei maksettavaa');
    end if;
    if exists (select 1 from booking.payments where order_id = o.id and status = 'pending' and provider = 'visma_pay' and provider_ref is not null and (link_expires_at is null or link_expires_at > now())) then
      perform booking._err('other_provider_started', 'Maksu on aloitettu toisella maksutavalla');
    end if;
    select * into v_open from booking.payments where order_id = o.id and status = 'pending' and provider = 'mobilepay' and (link_expires_at is null or link_expires_at > now()) and amount = v_tot
      order by id desc limit 1 for update;
    if found then
      pay := v_open;
    else
      for r in select id, provider_ref, raw from booking.payments where order_id = o.id and status = 'pending' and provider in ('mobilepay', 'visma_pay') for update loop
        if r.provider_ref is not null and coalesce(r.raw -> 'mobilepay' ->> 'last_state', 'CREATED') = 'CREATED' then
          v_super := v_super || jsonb_build_array(r.provider_ref);
        end if;
        update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'korvattu uudella MobilePay-maksulla') where id = r.id;
      end loop;
      v_exp := now() + make_interval(mins => v_mins);
      insert into booking.payments(order_id, method, provider, status, amount, currency, link_expires_at, note)
      values (o.id, 'mobilepay', 'mobilepay', 'pending', v_tot, o.currency, v_exp, 'MobilePay-verkkomaksu') returning * into pay;
      insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
      select pay.id, item_id, description, kind, quantity, remaining, vat_rate from booking._order_uncovered(o.id, false) where remaining > 0;
      update booking.payment_lines set amount_gross = amount_gross - ((select sum(amount_gross) from booking.payment_lines where payment_id = pay.id) - v_tot)
       where id = (select id from booking.payment_lines where payment_id = pay.id order by amount_gross desc, id limit 1)
         and (select sum(amount_gross) from booking.payment_lines where payment_id = pay.id) > v_tot;
    end if;
  end if;

  perform booking._checkout_extend_hold(o.id);    -- booking_53: MobilePay-maksu alkaa -> paikka pysyy varattuna lopputulokseen asti (katto: checkout_mobilepay_max_wait_minutes)
  v_raw := coalesce(pay.raw, '{}'::jsonb); v_mp := coalesce(v_raw -> 'mobilepay', '{}'::jsonb);
  v_started := nullif(v_mp ->> 'attempt_started_at', '')::timestamptz;
  -- sama yritys vielä kesken (alle 8 min, sama user_flow, Vipps-maksu luotu, ei lopputilaa): käytetään samaa ohjausosoitetta
  if pay.provider_ref is not null and coalesce(v_mp ->> 'last_state', 'CREATED') = 'CREATED' and v_started is not null and v_started > now() - interval '8 minutes'
     and coalesce(v_mp ->> 'user_flow', 'WEB_REDIRECT') = v_flow
     and (v_flow = 'PUSH_MESSAGE' or pay.link_url is not null) then
    return jsonb_build_object('ok', true, 'reuse', true, 'payment_id', pay.id, 'reference', pay.provider_ref, 'redirect_url', pay.link_url,
      'user_flow', v_flow, 'pushed', v_flow = 'PUSH_MESSAGE', 'order_no', o.order_no, 'order_token', o.public_token, 'mode', v_mode);
  end if;
  if pay.provider_ref is not null and coalesce(v_mp ->> 'last_state', 'CREATED') = 'CREATED' then
    v_super := v_super || jsonb_build_array(pay.provider_ref);   -- edellinen keskeneräinen yritys perutaan Vippsissä
  end if;
  v_att := coalesce((v_mp ->> 'attempts')::int, 0) + 1;
  v_ref := 'sauna-o' || o.order_no || '-p' || pay.id || '-a' || v_att;
  v_mp := v_mp || jsonb_build_object('attempts', v_att, 'attempt_started_at', now(), 'last_state', null, 'env', v_mode, 'user_flow', v_flow,
                                     'refs', coalesce(v_mp -> 'refs', '[]'::jsonb) || to_jsonb(v_ref));
  update booking.payments set provider_ref = v_ref, provider_status = 'initiating', link_url = null,
         -- booking_184: 20 min katkaisu vain verkkokaupan maksulle, ei maksulinkille (takarajaton tai voimassaolo yli 2 h)
         link_expires_at = case when p_link_token is null and v_flow in ('QR', 'PUSH_MESSAGE')
                                     and not coalesce((pay.link_expires_at is null and coalesce(pay.raw ->> 'paylink', '') = 'no_deadline')
                                                      or pay.link_expires_at - pay.created_at > interval '2 hours', false)
                                then least(coalesce(link_expires_at, now() + interval '20 minutes'), now() + interval '20 minutes') else link_expires_at end,
         raw = jsonb_set(v_raw, '{mobilepay}', v_mp, true) where id = pay.id;
  perform booking._refresh_order_payment(o.id);
  return jsonb_build_object('ok', true, 'reuse', false, 'payment_id', pay.id, 'reference', v_ref, 'attempt', v_att, 'amount', pay.amount, 'amount_minor', round(pay.amount * 100)::bigint,
    'currency', pay.currency, 'order_id', o.id, 'order_no', o.order_no, 'order_token', o.public_token, 'locale', o.locale, 'mode', v_mode, 'user_flow', v_flow, 'superseded', v_super,
    'description', left('Sipoonjoen Perinnesauna – tilaus ' || o.order_no, 100),
    'site_base_url', booking._setting('site_base_url', null) #>> '{}', 'order_page_path', booking._setting('order_page_path', to_jsonb('/tilaus/'::text)) #>> '{}');
end $function$
;

revoke all on function booking._create_link_payment(bigint,integer,text) from public, anon, authenticated;
grant execute on function booking._create_link_payment(bigint,integer,text) to service_role;
revoke all on function booking.admin_create_payment_link(bigint,boolean,integer,text) from public, anon;
grant execute on function booking.admin_create_payment_link(bigint,boolean,integer,text) to authenticated, service_role;
revoke all on function booking.admin_add_to_order(bigint,jsonb,boolean,boolean,text) from public, anon;
grant execute on function booking.admin_add_to_order(bigint,jsonb,boolean,boolean,text) to authenticated, service_role;
revoke all on function booking._vc_redeem(bigint,numeric,text,text,text) from public, anon, authenticated, service_role;
revoke all on function booking.vismapay_payment_apply(text,text,numeric,jsonb) from public, anon, authenticated;
grant execute on function booking.vismapay_payment_apply(text,text,numeric,jsonb) to service_role;
revoke all on function booking.mobilepay_payment_prepare(uuid,uuid,integer,text) from public, anon, authenticated;
grant execute on function booking.mobilepay_payment_prepare(uuid,uuid,integer,text) to service_role;

do $v$
begin
  if md5(pg_get_functiondef('booking._create_link_payment(bigint,integer,text)'::regprocedure)) <> '5e432077c560a10822db8ac0d2bbe7c2' then raise exception 'booking_184: _create_link_payment md5 ei vastaa odotettua'; end if;
  if md5(pg_get_functiondef('booking.admin_create_payment_link(bigint,boolean,integer,text)'::regprocedure)) <> '80004933a80f77a10fcf625f493a20ef' then raise exception 'booking_184: admin_create_payment_link md5 ei vastaa odotettua'; end if;
  if md5(pg_get_functiondef('booking.admin_add_to_order(bigint,jsonb,boolean,boolean,text)'::regprocedure)) <> '5babbf859133aebd3e9e7c827bee3261' then raise exception 'booking_184: admin_add_to_order md5 ei vastaa odotettua'; end if;
  if md5(pg_get_functiondef('booking._vc_redeem(bigint,numeric,text,text,text)'::regprocedure)) <> '2aa8e44cb2c6f150d3488f53f8d94c25' then raise exception 'booking_184: _vc_redeem md5 ei vastaa odotettua'; end if;
  if md5(pg_get_functiondef('booking.vismapay_payment_apply(text,text,numeric,jsonb)'::regprocedure)) <> '2f8a7e56ae9bb4e29f4025f91e7ea706' then raise exception 'booking_184: vismapay_payment_apply md5 ei vastaa odotettua'; end if;
  if md5(pg_get_functiondef('booking.mobilepay_payment_prepare(uuid,uuid,integer,text)'::regprocedure)) <> '37573920d2f9f882e3d95c4f0c66575f' then raise exception 'booking_184: mobilepay_payment_prepare md5 ei vastaa odotettua'; end if;
  if exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid in ('booking._create_link_payment(bigint,integer,text)'::regprocedure, 'booking.admin_create_payment_link(bigint,boolean,integer,text)'::regprocedure, 'booking.admin_add_to_order(bigint,jsonb,boolean,boolean,text)'::regprocedure, 'booking._vc_redeem(bigint,numeric,text,text,text)'::regprocedure, 'booking.vismapay_payment_apply(text,text,numeric,jsonb)'::regprocedure, 'booking.mobilepay_payment_prepare(uuid,uuid,integer,text)'::regprocedure) and a.grantee = 0) then raise exception 'booking_184: PUBLIC-oikeus jäi'; end if;
  if exists (select 1 from pg_proc p where p.oid in ('booking._create_link_payment(bigint,integer,text)'::regprocedure, 'booking.admin_create_payment_link(bigint,boolean,integer,text)'::regprocedure, 'booking.admin_add_to_order(bigint,jsonb,boolean,boolean,text)'::regprocedure, 'booking._vc_redeem(bigint,numeric,text,text,text)'::regprocedure, 'booking.vismapay_payment_apply(text,text,numeric,jsonb)'::regprocedure, 'booking.mobilepay_payment_prepare(uuid,uuid,integer,text)'::regprocedure) and (not p.prosecdef or p.proconfig is distinct from array['search_path=""'] or p.proowner <> 'postgres'::regrole)) then raise exception 'booking_184: SECURITY DEFINER / search_path / omistaja väärin'; end if;
  if has_function_privilege('anon', 'booking._create_link_payment(bigint,integer,text)', 'execute')
     or has_function_privilege('authenticated', 'booking._create_link_payment(bigint,integer,text)', 'execute')
     or not has_function_privilege('service_role', 'booking._create_link_payment(bigint,integer,text)', 'execute')
     or has_function_privilege('anon', 'booking.admin_create_payment_link(bigint,boolean,integer,text)', 'execute')
     or not has_function_privilege('authenticated', 'booking.admin_create_payment_link(bigint,boolean,integer,text)', 'execute')
     or not has_function_privilege('service_role', 'booking.admin_create_payment_link(bigint,boolean,integer,text)', 'execute')
     or has_function_privilege('anon', 'booking.admin_add_to_order(bigint,jsonb,boolean,boolean,text)', 'execute')
     or not has_function_privilege('authenticated', 'booking.admin_add_to_order(bigint,jsonb,boolean,boolean,text)', 'execute')
     or not has_function_privilege('service_role', 'booking.admin_add_to_order(bigint,jsonb,boolean,boolean,text)', 'execute')
     or has_function_privilege('anon', 'booking._vc_redeem(bigint,numeric,text,text,text)', 'execute')
     or has_function_privilege('authenticated', 'booking._vc_redeem(bigint,numeric,text,text,text)', 'execute')
     or has_function_privilege('service_role', 'booking._vc_redeem(bigint,numeric,text,text,text)', 'execute')
     or has_function_privilege('anon', 'booking.vismapay_payment_apply(text,text,numeric,jsonb)', 'execute')
     or has_function_privilege('authenticated', 'booking.vismapay_payment_apply(text,text,numeric,jsonb)', 'execute')
     or not has_function_privilege('service_role', 'booking.vismapay_payment_apply(text,text,numeric,jsonb)', 'execute')
     or has_function_privilege('anon', 'booking.mobilepay_payment_prepare(uuid,uuid,integer,text)', 'execute')
     or has_function_privilege('authenticated', 'booking.mobilepay_payment_prepare(uuid,uuid,integer,text)', 'execute')
     or not has_function_privilege('service_role', 'booking.mobilepay_payment_prepare(uuid,uuid,integer,text)', 'execute') then raise exception 'booking_184: funktio-oikeudet väärin'; end if;
end $v$;
