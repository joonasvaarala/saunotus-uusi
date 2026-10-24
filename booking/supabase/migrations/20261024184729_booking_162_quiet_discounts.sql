-- booking_162: hiljaisten aikojen ale (Joonas 24.10.2026).
-- Jälkilöylyvuoro (tuote 26), jossa ei ole yhtään varausta: −20 % kun alkuun on enintään 72 h, −30 % kun alkuun on enintään 36 h
-- (rajat mukaan lukien: tasan 36 h → 30 %). "Tyhjä" = vuoron tilalla (schedule_rules.space_id) ei ole yhtään aktiivista varausta / pitoa
-- (booking.v_claims, booking._res_active) eikä aktiivista tilasulkua (booking.space_blocks) vuoron aikana. Tuote 49 (yritysten jälkilöylyt)
-- käyttää samaa saunaa (space_id 1, exclusive, 19:00), joten kummankin varaus tekee vuorosta ei-tyhjän.
-- Prosentti koskee koko vuoron hintaa lisähenkilöineen (varausrivi), ei lisäpalveluita. Hinta lasketaan ja lukitaan palvelimella varaushetkellä
-- (order_items.line_total_gross / discount_amount / price_breakdown.quiet). Ei pinoudu alennuskoodien eikä vuosi-/kausikorttien kanssa:
-- suurempi etu voittaa (tasatilanteessa hiljaisen ajan ale, jolloin koodia ei käytetä eikä sen käyttökertaa kuluteta).
-- Vuoron siirto / hinnan uudelleenlaskenta (_change_booking_core kirjoittaa price_breakdownin uudelleen) poistaa alen (trigger order_items_quiet_reset).
-- Pois päältä: asetus quiet_discounts.enabled = false (luodaan false, ei julkinen). Kun false, varaus- ja koodifunktiot toimivat kuten ennen
-- (sama vastaus, ei uusia kenttiä) ja public_quiet_offers palauttaa []. Joonas kytkee päälle hallinnasta (Hiljaiset ajat) tai
-- update booking.settings set value = 'true' where key = 'quiet_discounts.enabled';
-- Perushinnat, ALV, URL:t, maksupalveluiden asetukset ja public-skeema ennallaan.
-- Korvattavat funktiot (tarkistetaan tuotannon md5(pg_get_functiondef) ennen korvausta; uudelleenajossa hyväksytään jo korvattu versio):
--   booking.public_create_booking       f7b15dca769f5fb4abfd9f81090718ac
--   booking.public_create_booking_code  31a03d52526c7b22d2643be477589b7f
--   booking.public_preview_code         aaac81dc8ae5704a67b56184e5cd4cd7
-- Uudet: taulu booking.quiet_discount_rules, funktiot _quiet_offers, _quiet_for_rule, _quiet_apply, _order_items_quiet_reset_trg,
--   admin_quiet_rules_list, admin_quiet_rule_upsert, admin_quiet_rule_delete, admin_quiet_set_enabled, admin_quiet_preview, public_quiet_offers,
--   trigger order_items_quiet_reset, asetus quiet_discounts.enabled.
-- Ajojärjestys: booking_159:n ja booking_161:n (20261024182650) jälkeen; ei riipu booking_161:stä. Yksi transaktio. Uudelleenajettava.
-- Rollback: rollbacks/20261024184729_booking_162_ROLLBACK.sql
set local lock_timeout = '5s';

do $g$
declare r record;
begin
  for r in select * from (values
      ('booking.public_create_booking(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb)', 'f7b15dca769f5fb4abfd9f81090718ac'),
      ('booking.public_create_booking_code(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb,text)', '31a03d52526c7b22d2643be477589b7f'),
      ('booking.public_preview_code(text,bigint,date,integer,jsonb,text,text)', 'aaac81dc8ae5704a67b56184e5cd4cd7')
    ) x(sig, md5)
  loop
    if to_regprocedure(r.sig) is null then raise exception 'booking_162: funktiota % ei ole', r.sig; end if;
    if md5(pg_get_functiondef(r.sig::regprocedure)) <> r.md5 and pg_get_functiondef(r.sig::regprocedure) !~ 'booking_162' then
      raise exception 'booking_162: % poikkeaa tuotannon versiosta (md5 %, odotettiin %); mitään ei muutettu',
        r.sig, md5(pg_get_functiondef(r.sig::regprocedure)), r.md5;
    end if;
  end loop;
end $g$;

-- ---------------------------------------------------------------- taulu ja asetus
create table if not exists booking.quiet_discount_rules (
  id bigint generated always as identity primary key,
  label text not null check (char_length(btrim(label)) between 1 and 80),
  label_en text check (label_en is null or char_length(label_en) <= 80),
  product_ids bigint[] not null check (cardinality(product_ids) between 1 and 20),
  hours_before integer not null check (hours_before between 1 and 336),
  percent numeric(5,2) not null check (percent > 0 and percent <= 90),
  condition text not null default 'empty_slot' check (condition = 'empty_slot'),
  channel text not null default 'shop' check (channel = 'shop'),
  valid_from date,
  valid_to date,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint quiet_discount_rules_valid_range check (valid_to is null or valid_from is null or valid_to >= valid_from)
);
comment on table booking.quiet_discount_rules is 'booking_162: hiljaisten aikojen ale. Tyhjä vuoro, alkuun enintään hours_before tuntia → percent % vuoron hinnasta (suurin voimassa oleva porras). Vain verkkokauppa. Kytkin: settings quiet_discounts.enabled.';
alter table booking.quiet_discount_rules enable row level security;
revoke all on booking.quiet_discount_rules from public, anon, authenticated;
do $t$ begin
  if not exists (select 1 from pg_trigger where tgname = 'quiet_discount_rules_updated' and tgrelid = 'booking.quiet_discount_rules'::regclass) then
    create trigger quiet_discount_rules_updated before update on booking.quiet_discount_rules for each row execute function booking.set_updated_at();
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'audit_trg' and tgrelid = 'booking.quiet_discount_rules'::regclass) then
    perform booking._add_audit('booking.quiet_discount_rules');
  end if;
end $t$;

insert into booking.quiet_discount_rules(label, label_en, product_ids, hours_before, percent)
select x.label, x.label_en, array[26]::bigint[], x.h, x.p
  from (values ('Hiljainen aika 72 h', 'Quiet time 72 h', 72, 20.00), ('Hiljainen aika 36 h', 'Quiet time 36 h', 36, 30.00)) x(label, label_en, h, p)
 where exists (select 1 from kb.products where id = 26)
   and not exists (select 1 from booking.quiet_discount_rules q where 26 = any(q.product_ids) and q.hours_before = x.h);

insert into booking.settings(key, value, description, is_public)
values ('quiet_discounts.enabled', 'false'::jsonb, 'booking_162: hiljaisten aikojen ale käytössä (true/false). Säännöt: Hallinta → Hiljaiset ajat.', false)
on conflict (key) do nothing;

-- ---------------------------------------------------------------- laskenta
-- Tarjoukset päiväväliltä (enintään 15 päivää). p_require_enabled = false vain hallinnan esikatselulle.
create or replace function booking._quiet_offers(p_from date, p_to date, p_rule_id bigint default null, p_require_enabled boolean default true)
returns table(product_id bigint, rule_id bigint, label text, label_en text, session_date date, starts_at timestamptz, ends_at timestamptz,
              quiet_rule_id bigint, percent numeric, hours_before integer, base_price numeric, discount_amount numeric, discounted_price numeric,
              price_mode text, included_persons integer, extra_person_price numeric, max_persons integer, sale_closes_at timestamptz,
              next_change_at timestamptz)
language sql stable security definer set search_path = '' as $f$
  with s as (
    select x.* from booking._sessions(p_from, p_to, null, true) x
     where p_from is not null and p_to is not null and p_to >= p_from and p_to - p_from <= 14
       and (not p_require_enabled or coalesce((booking._setting('quiet_discounts.enabled', 'false'::jsonb) #>> '{}')::boolean, false))
       and x.status = 'available' and x.starts_at > now() and (x.sale_closes_at is null or x.sale_closes_at > now())
       and (p_rule_id is null or x.rule_id = p_rule_id)
       and exists (select 1 from booking.quiet_discount_rules q where q.active and x.product_id = any(q.product_ids))
  ), e as (   -- tyhjä vuoro: ei aktiivisia varauksia / pitoja eikä tilasulkuja vuoron tilalla (kaikki tuotteet, esim. 26 ja 49)
    select s.*, sr.space_id from s join booking.schedule_rules sr on sr.id = s.rule_id
     where sr.space_id is not null
       and not exists (select 1 from booking.v_claims c where c.resource_id = sr.space_id and booking._res_active(c.status, c.hold_expires_at)
                         and c.claim_start < s.ends_at and c.claim_end > s.starts_at)
       and not exists (select 1 from booking.space_blocks b where b.space_id = sr.space_id and b.active
                         and b.starts_at < s.ends_at and b.ends_at > s.starts_at)
  ), c as (
    select distinct on (e.rule_id, e.starts_at) e.*, q.id as qid, q.percent as qpct, q.hours_before as qh
      from e join booking.quiet_discount_rules q on q.active and e.product_id = any(q.product_ids)
       and (q.valid_from is null or e.session_date >= q.valid_from) and (q.valid_to is null or e.session_date <= q.valid_to)
       and e.starts_at - make_interval(hours => q.hours_before) <= now()
     order by e.rule_id, e.starts_at, q.percent desc, q.hours_before asc, q.id
  )
  select c.product_id, c.rule_id, c.label, c.label_en, c.session_date, c.starts_at, c.ends_at, c.qid, c.qpct, c.qh,
         c.base_price, round(coalesce(c.base_price, 0) * c.qpct / 100, 2), coalesce(c.base_price, 0) - round(coalesce(c.base_price, 0) * c.qpct / 100, 2),
         c.price_mode, c.included_persons, c.extra_person_price, c.max_persons, c.sale_closes_at,
         nullif(least(coalesce((select min(c.starts_at - make_interval(hours => q2.hours_before)) from booking.quiet_discount_rules q2
                                 where q2.active and c.product_id = any(q2.product_ids) and q2.percent > c.qpct
                                   and (q2.valid_from is null or c.session_date >= q2.valid_from) and (q2.valid_to is null or c.session_date <= q2.valid_to)
                                   and c.starts_at - make_interval(hours => q2.hours_before) > now()), 'infinity'::timestamptz),
                      coalesce(c.sale_closes_at, c.starts_at)), 'infinity'::timestamptz)
    from c
   order by c.starts_at, c.rule_id
$f$;
comment on function booking._quiet_offers(date, date, bigint, boolean) is 'booking_162: hiljaisten aikojen tarjoukset (tyhjät vuorot, paras voimassa oleva porras).';

-- Yhden vuoron tarjous varaushetkellä (null = ei alea). Arvioidaan ENNEN varauksen luontia.
create or replace function booking._quiet_for_rule(p_rule_id bigint, p_date date)
returns jsonb language sql stable security definer set search_path = '' as $f$
  select jsonb_build_object('rule_id', o.quiet_rule_id, 'percent', o.percent, 'hours_before', o.hours_before,
                            'hours_left', round((extract(epoch from (o.starts_at - now())) / 3600)::numeric, 2), 'starts_at', o.starts_at)
    from booking._quiet_offers(p_date, p_date, p_rule_id, true) o
   order by o.starts_at limit 1
$f$;

-- Ale tilauksen varausriville (koko vuoron hinta lisähenkilöineen). Palauttaa alen euromäärän.
create or replace function booking._quiet_apply(p_order_id bigint, p_quiet jsonb)
returns numeric language plpgsql security definer set search_path = '' as $f$
declare v_item booking.order_items; v_amt numeric;
begin
  if p_quiet is null or p_order_id is null then return 0; end if;
  select * into v_item from booking.order_items where order_id = p_order_id and kind = 'reservation' order by id limit 1 for update;
  if v_item.id is null or coalesce(v_item.line_total_gross, 0) <= 0 then return 0; end if;
  v_amt := least(v_item.line_total_gross, round(v_item.line_total_gross * (p_quiet ->> 'percent')::numeric / 100, 2));
  if v_amt <= 0 then return 0; end if;
  update booking.order_items
     set line_total_gross = line_total_gross - v_amt, discount_amount = v_amt,
         price_breakdown = coalesce(price_breakdown, '{}'::jsonb) || jsonb_build_object('quiet', jsonb_build_object(
           'rule_id', (p_quiet ->> 'rule_id')::bigint, 'percent', (p_quiet ->> 'percent')::numeric, 'base', v_item.line_total_gross,
           'amount', v_amt, 'hours_left', (p_quiet ->> 'hours_left')::numeric, 'source', 'quiet'))
   where id = v_item.id;
  update booking.orders set total_gross = total_gross - v_amt where id = p_order_id;
  return v_amt;
end $f$;

-- Siirto / hinnan uudelleenlaskenta kirjoittaa price_breakdownin uudelleen ilman quiet-avainta → ale pois (discount_amount 0).
create or replace function booking._order_items_quiet_reset_trg()
returns trigger language plpgsql set search_path = '' as $f$
begin
  if old.price_breakdown ? 'quiet' and not (coalesce(new.price_breakdown, '{}'::jsonb) ? 'quiet')
     and not (coalesce(new.price_breakdown, '{}'::jsonb) ? 'quiet_superseded') and new.discount_code_id is null then
    new.discount_amount := 0;
    new.price_breakdown := coalesce(new.price_breakdown, '{}'::jsonb) || jsonb_build_object('quiet_removed',
      jsonb_build_object('percent', old.price_breakdown #> '{quiet,percent}', 'amount', old.price_breakdown #> '{quiet,amount}', 'at', now()));
  end if;
  return new;
end $f$;
do $t$ begin
  if not exists (select 1 from pg_trigger where tgname = 'order_items_quiet_reset' and tgrelid = 'booking.order_items'::regclass) then
    create trigger order_items_quiet_reset before update of price_breakdown on booking.order_items
      for each row execute function booking._order_items_quiet_reset_trg();
  end if;
end $t$;

-- ---------------------------------------------------------------- korvattavat funktiot (tuotannon versio + booking_162-muutokset)
CREATE OR REPLACE FUNCTION booking.public_create_booking(p_rule_id bigint, p_date date, p_persons integer, p_name text, p_email text, p_phone text, p_marketing_consent boolean DEFAULT false, p_locale text DEFAULT 'fi'::text, p_note text DEFAULT NULL::text, p_customer_kind text DEFAULT 'private'::text, p_company jsonb DEFAULT NULL::jsonb, p_addons jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_mode text := booking._setting('public_payment_mode', '"pay_later"'::jsonb) #>> '{}';
  v_ip text := booking._client_ip();
  v_cust bigint; v_res jsonb; v_status text; v_pay_method text; v_pay_provider text;
  v_email text := lower(btrim(coalesce(p_email, ''))); v_name text := btrim(coalesce(p_name, '')); v_phone text := btrim(coalesce(p_phone, ''));
  v_detail text; v_msg text;
  v_hold int; v_invoice boolean; v_hold_mode boolean; v_group boolean; v_thr int := booking._checkout_cfg_int('checkout_group_threshold_persons', 0, 0, 1000);
  v_kind text := lower(btrim(coalesce(nullif(p_customer_kind, ''), 'private'))); v_is_company boolean; v_company jsonb; v_add numeric; v_total numeric;
  v_quiet jsonb; v_qamt numeric := 0;  -- booking_162: hiljaisten aikojen ale
begin
  if not coalesce((booking._setting('public_booking_enabled', 'true'::jsonb) #>> '{}')::boolean, true) then
    return jsonb_build_object('ok', false, 'code', 'booking_disabled', 'message', 'Verkkovaraus ei ole tällä hetkellä käytössä');
  end if;

  -- rate limit (kirjataan myös estetyt yritykset)
  if v_ip is not null and not booking._rate_limit('ip:' || v_ip, (booking._setting('rl_ip_per_10min', '12'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_email <> '' and not booking._rate_limit('email:' || v_email, (booking._setting('rl_email_per_10min', '5'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;

  -- syötteiden validointi
  select k.is_company into v_is_company from booking.customer_kinds k where k.code = v_kind and k.active;
  if v_is_company is null then
    return jsonb_build_object('ok', false, 'code', 'invalid_customer_kind', 'message', 'Valitse asiakastyyppi (yksityinen / yritys)');
  end if;
  if char_length(v_name) < 2 or char_length(v_name) > 120 then
    return jsonb_build_object('ok', false, 'code', 'invalid_name', 'message', case when v_is_company then 'Anna yhteyshenkilön nimi' else 'Anna nimi' end);
  end if;
  if not booking._valid_email(v_email) then
    return jsonb_build_object('ok', false, 'code', 'invalid_email', 'message', 'Tarkista sähköpostiosoite');
  end if;
  if v_phone !~ '^[0-9+()\- ]{6,30}$' then
    return jsonb_build_object('ok', false, 'code', 'invalid_phone', 'message', 'Tarkista puhelinnumero');
  end if;
  if p_persons is null or p_persons < 1 or p_persons > 50 then
    return jsonb_build_object('ok', false, 'code', 'invalid_persons', 'message', 'Tarkista henkilömäärä');
  end if;
  if p_note is not null and char_length(p_note) > 1000 then
    return jsonb_build_object('ok', false, 'code', 'invalid_note', 'message', 'Viesti on liian pitkä');
  end if;
  if p_date is null or p_date < (now() at time zone booking._tz())::date
     or p_date > (now() at time zone booking._tz())::date + (booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int then
    return jsonb_build_object('ok', false, 'code', 'invalid_date', 'message', 'Päivä ei ole varattavissa');
  end if;
  -- rajoita samanaikaisia maksamattomia pitoja / sähköposti
  if (select count(*) from booking.orders o join booking.customers c on c.id = o.customer_id
       where lower(c.email) = v_email and o.status = 'pending' and o.created_at > now() - interval '1 hour') >= 3 then
    return jsonb_build_object('ok', false, 'code', 'too_many_pending', 'message', 'Sinulla on jo useita keskeneräisiä varauksia');
  end if;

  -- booking_53: pitotila (public_payment_mode <> 'pay_later'): varaus odottaa maksua; yritysasiakas laskulle jos checkout_company_invoice_enabled
  v_invoice := v_is_company and coalesce((booking._setting('checkout_company_invoice_enabled', 'true'::jsonb) #>> '{}')::boolean, true);
  v_hold_mode := v_mode <> 'pay_later' and not v_invoice;
  v_group := v_hold_mode and v_thr > 0 and p_persons >= v_thr;
  if v_hold_mode and not v_group and not booking._checkout_online_available() then
    return jsonb_build_object('ok', false, 'code', 'online_payment_unavailable', 'message', 'Verkkomaksu ei ole tilapäisesti käytettävissä – varausta ei voi tehdä juuri nyt');
  end if;
  v_status := case when v_hold_mode then 'pending' else 'confirmed' end;
  v_pay_method := case when v_is_company then 'invoice' else 'pay_later' end;
  v_pay_provider := 'manual';
  v_hold := case when v_group then booking._checkout_cfg_int('checkout_group_hold_days', 7, 1, 60) * 1440 else booking._checkout_hold_minutes() end;

  begin  -- alitransaktio: virhe kumoaa asiakkaan/tilauksen/varauksen luonnin mutta rate limit -kirjaus säilyy
    -- booking_139: jonotuspidon haltija (sama sähköposti, voimassa oleva pito tähän vuoroon) ei kilpaile omaa pitoaan vastaan.
    -- Transaktiokohtainen asetus; virhe kumoaa sen alitransaktion mukana, onnistuneen luonnin jälkeen se nollataan alla.
    perform set_config('booking.waitlist_hold_exempt', coalesce((select w.id::text from booking.waitlist_entries w
      where w.rule_id = p_rule_id and w.session_date = p_date and lower(w.customer_email) = v_email
        and w.status = 'notified' and w.hold_expires_at > now() order by w.id limit 1), ''), true);
    if v_is_company then v_company := booking._clean_company(p_company); end if;
    if v_is_company then
      v_cust := booking._upsert_company_customer(v_kind, v_name, v_email, v_phone, v_company, p_marketing_consent, 'web_booking', p_locale,
                                                 (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    else
      v_cust := booking._upsert_customer(v_name, v_email, v_phone, p_marketing_consent, 'web_booking', p_locale,
                                         (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    end if;
    -- booking_162: hiljaisen ajan ale arvioidaan ennen varauksen luontia (tyhjä vuoro); null kun asetus pois tai ei tarjousta
    v_quiet := booking._quiet_for_rule(p_rule_id, p_date);
    v_res := booking._create_booking_core(p_rule_id, p_date, p_persons, v_cust, 'web', null, p_locale, p_note,
                                          v_status, v_hold, true);
    perform booking._stamp_order_billing((v_res ->> 'order_id')::bigint, v_cust, v_company);
    v_add := booking._attach_addons((v_res ->> 'reservation_id')::bigint, p_addons);
    v_qamt := booking._quiet_apply((v_res ->> 'order_id')::bigint, v_quiet);
    v_total := (v_res ->> 'total')::numeric - v_qamt + v_add;
    if not v_hold_mode then   -- pitotilassa ei luoda paikkaajamaksua: maksu syntyy vasta kun asiakas maksaa (MobilePay / lahjakortti)
      insert into booking.payments(order_id, method, provider, status, amount)
      values ((v_res ->> 'order_id')::bigint, v_pay_method, v_pay_provider, 'pending', v_total);
    end if;
    update booking.orders set payment_status = 'unpaid', hold_kind = case when v_hold_mode then (case when v_group then 'preliminary' else 'checkout' end) end
     where id = (v_res ->> 'order_id')::bigint;
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;
  perform set_config('booking.waitlist_hold_exempt', '', true);

  return jsonb_build_object('ok', true, 'order_no', v_res -> 'order_no', 'token', v_res -> 'public_token',
                            'status', v_status, 'starts_at', v_res -> 'starts_at', 'ends_at', v_res -> 'ends_at',
                            'total', v_total, 'addons_total', v_add, 'hold_expires_at', v_res -> 'hold_expires_at',
                            'payment_mode', v_mode, 'payment_url', null, 'product_name', v_res -> 'product_name', 'customer_kind', v_kind)
         || case when v_qamt > 0 then jsonb_build_object('discount', v_qamt, 'discount_source', 'quiet',
                 'quiet', jsonb_build_object('percent', (v_quiet ->> 'percent')::numeric, 'amount', v_qamt)) else '{}'::jsonb end
         || booking._checkout_state_json((v_res ->> 'order_id')::bigint);
end $function$;

CREATE OR REPLACE FUNCTION booking.public_create_booking_code(p_rule_id bigint, p_date date, p_persons integer, p_name text, p_email text, p_phone text, p_marketing_consent boolean DEFAULT false, p_locale text DEFAULT 'fi'::text, p_note text DEFAULT NULL::text, p_customer_kind text DEFAULT 'private'::text, p_company jsonb DEFAULT NULL::jsonb, p_addons jsonb DEFAULT NULL::jsonb, p_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_code text := booking._norm_code(p_code); v_ip text := booking._client_ip();
  v_email text := lower(btrim(coalesce(p_email, ''))); v_name text := btrim(coalesce(p_name, '')); v_phone text := btrim(coalesce(p_phone, ''));
  v_kind text := lower(btrim(coalesce(nullif(p_customer_kind, ''), 'private')));
  v_card booking.annual_cards; d booking.discount_codes; v_res jsonb; v_order booking.orders; v_cust bigint; v_err text; v_detail text; v_msg text;
  v_lines jsonb; v_calc jsonb; s jsonb; v_disc numeric; v_total numeric; pr record; v_mode text := booking._setting('public_payment_mode', '"pay_later"'::jsonb) #>> '{}';
  v_qamt numeric := 0; v_qitem bigint;  -- booking_162: hiljaisen ajan ale (ei pinoudu koodin kanssa, suurempi etu voittaa)
begin
  if v_code = '' then
    return booking.public_create_booking(p_rule_id, p_date, p_persons, p_name, p_email, p_phone, p_marketing_consent, p_locale, p_note,
                                         p_customer_kind, p_company, p_addons);
  end if;
  if char_length(v_code) > 40 then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;
  if not booking._code_rate_ok(v_code, v_email, v_phone, v_ip) then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', booking._code_msg('rate_limited'));
  end if;
  select * into v_card from booking.annual_cards where code = v_code;
  if v_card.id is null then select * into d from booking.discount_codes where code = v_code for update; end if;
  if v_card.id is null and d.id is null then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;
  -- booking_143: henkilökohtainen kortti, jonka omistaja ei täsmää → sama vastaus kuin tuntemattomalla koodilla (ennen muita tarkistuksia)
  if v_card.id is not null and not booking._annual_card_owner_ok(v_card, v_email, v_phone) then
    return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code'));
  end if;

  -- ---- vuosikortti / yhteinen vuosikorttikoodi
  if v_card.id is not null or d.is_annual_card_code then
    if not coalesce((booking._setting('public_booking_enabled', 'true'::jsonb) #>> '{}')::boolean, true) then
      return jsonb_build_object('ok', false, 'code', 'booking_disabled', 'message', 'Verkkovaraus ei ole tällä hetkellä käytössä');
    end if;
    if v_ip is not null and not booking._rate_limit('ip:' || v_ip, (booking._setting('rl_ip_per_10min', '12'::jsonb) #>> '{}')::int, interval '10 minutes') then
      return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', booking._code_msg('rate_limited'));
    end if;
    if v_email <> '' and not booking._rate_limit('email:' || v_email, (booking._setting('rl_email_per_10min', '5'::jsonb) #>> '{}')::int, interval '10 minutes') then
      return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', booking._code_msg('rate_limited'));
    end if;
    if char_length(v_name) < 2 or char_length(v_name) > 120 then return jsonb_build_object('ok', false, 'code', 'invalid_name', 'message', 'Anna nimi'); end if;
    if not booking._valid_email(v_email) then return jsonb_build_object('ok', false, 'code', 'invalid_email', 'message', 'Tarkista sähköpostiosoite'); end if;
    if v_phone !~ '^[0-9+()\- ]{6,30}$' then return jsonb_build_object('ok', false, 'code', 'invalid_phone', 'message', 'Tarkista puhelinnumero'); end if;
    if p_note is not null and char_length(p_note) > 1000 then return jsonb_build_object('ok', false, 'code', 'invalid_note', 'message', 'Viesti on liian pitkä'); end if;
    if p_date is null or p_date < (now() at time zone booking._tz())::date
       or p_date > (now() at time zone booking._tz())::date + (booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int then
      return jsonb_build_object('ok', false, 'code', 'invalid_date', 'message', 'Päivä ei ole varattavissa');
    end if;
    v_err := case
      when v_kind <> 'private' then 'annual_card_private_only'
      when p_addons is not null and jsonb_typeof(p_addons) = 'array' and exists (select 1 from jsonb_array_elements(p_addons) x where coalesce(x ->> 'quantity', '0') <> '0') then 'annual_card_no_addons'
      when p_persons is distinct from booking._annual_max_persons() then 'annual_card_persons'
      else booking._annual_rule_check(p_rule_id, p_date, v_card, d) end;
    if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
    begin
      if v_card.id is not null then v_cust := v_card.customer_id;
      else
        v_cust := booking._upsert_customer(v_name, v_email, v_phone, p_marketing_consent, 'web_booking', p_locale,
                                           (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
      end if;
      perform booking._annual_lock_identity(v_cust, v_email, v_phone);
      if booking._annual_limit(v_cust, v_email, v_phone) then perform booking._err('annual_card_limit', booking._code_msg('annual_card_limit')); end if;
      -- henkilökohtaisen kortin rivin alennus (alkuperäinen hinta) kirjataan triggerissä reservations_annual_discount
      v_res := booking._create_booking_core(p_rule_id, p_date, p_persons, v_cust, 'web', null, p_locale, p_note, 'confirmed', null, true,
                                            null, null, case when v_card.id is null then 0 end, v_card.id);
      if d.id is not null then
        select * into pr from booking._rule_price(p_rule_id, p_persons);
        update booking.order_items set discount_code_id = d.id, discount_amount = pr.total
         where order_id = (v_res ->> 'order_id')::bigint and kind = 'reservation';
        update booking.orders set discount_code_id = d.id where id = (v_res ->> 'order_id')::bigint;
        update booking.discount_codes set used_count = used_count + 1 where id = d.id;
      end if;
      insert into booking.payments(order_id, method, provider, status, amount, paid_at, note)
      values ((v_res ->> 'order_id')::bigint, 'annual_card', 'manual', 'paid', 0, now(), 'Vuosikorttivaraus verkossa (' || v_code || ')');
      update booking.orders set payment_status = 'paid' where id = (v_res ->> 'order_id')::bigint;
    exception when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
    end;
    return jsonb_build_object('ok', true, 'order_no', v_res -> 'order_no', 'token', v_res -> 'public_token', 'status', 'confirmed',
                              'starts_at', v_res -> 'starts_at', 'ends_at', v_res -> 'ends_at', 'total', 0, 'addons_total', 0,
                              'hold_expires_at', null, 'payment_mode', v_mode, 'payment_url', null, 'product_name', v_res -> 'product_name',
                              'customer_kind', 'private', 'code_type', case when v_card.id is not null then 'annual_card' else 'annual_code' end,
                              'discount', (select coalesce(sum(discount_amount), 0) from booking.order_items where order_id = (v_res ->> 'order_id')::bigint))
           || booking._checkout_state_json((v_res ->> 'order_id')::bigint);
  end if;

  -- ---- alennuskoodi
  v_err := booking._discount_state(d);
  if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
  begin
    v_res := booking.public_create_booking(p_rule_id, p_date, p_persons, p_name, p_email, p_phone, p_marketing_consent, p_locale, p_note,
                                           p_customer_kind, p_company, p_addons);
    if not coalesce((v_res ->> 'ok')::boolean, false) then return v_res; end if;
    select * into v_order from booking.orders where public_token = (v_res ->> 'token')::uuid for update;
    -- booking_162: koodin alennus lasketaan alennuksettomista riveistä (hiljaisen ajan ale lisätään takaisin)
    select oi.id, coalesce((oi.price_breakdown #>> '{quiet,amount}')::numeric, 0) into v_qitem, v_qamt
      from booking.order_items oi where oi.order_id = v_order.id and oi.kind = 'reservation' and oi.price_breakdown ? 'quiet' order by oi.id limit 1;
    v_qamt := coalesce(v_qamt, 0);
    select coalesce(jsonb_agg(jsonb_build_object('key', oi.id, 'product_id', oi.product_id, 'kind', oi.kind,
             'gross', oi.line_total_gross + case when oi.id = v_qitem then v_qamt else 0 end) order by oi.id), '[]'::jsonb)
      into v_lines from booking.order_items oi where oi.order_id = v_order.id;
    v_calc := booking._discount_split(d, v_lines);
    v_disc := (v_calc ->> 'discount')::numeric;
    if v_disc <= 0 then perform booking._err('code_not_applicable', booking._code_msg('code_not_applicable')); end if;
    if v_qamt > 0 and v_qamt >= v_disc then
      -- hiljaisen ajan ale on vähintään yhtä suuri etu: koodia ei käytetä (käyttökertaa ei kuluteta), varaus jää alennettuun hintaan
      return v_res || jsonb_build_object('code_applied', false, 'discount_source', 'quiet', 'code_discount', v_disc, 'discount_code', null, 'code_type', 'discount');
    end if;
    if v_qamt > 0 then   -- koodi on suurempi etu: hiljaisen ajan ale perutaan riviltä ennen koodin alennusta
      update booking.order_items
         set line_total_gross = line_total_gross + v_qamt, discount_amount = 0,
             price_breakdown = (price_breakdown - 'quiet') || jsonb_build_object('quiet_superseded', (price_breakdown -> 'quiet') || jsonb_build_object('by', 'code'))
       where id = v_qitem;
    end if;
    for s in select x from jsonb_array_elements(v_calc -> 'shares') x loop
      update booking.order_items set discount_code_id = d.id, discount_amount = coalesce(discount_amount, 0) + (s ->> 'amount')::numeric,
             line_total_gross = line_total_gross - (s ->> 'amount')::numeric
       where id = (s ->> 'key')::bigint and order_id = v_order.id;
    end loop;
    update booking.orders set discount_code_id = d.id,
           total_gross = coalesce((select sum(line_total_gross) from booking.order_items where order_id = v_order.id), 0)
     where id = v_order.id returning total_gross into v_total;
    update booking.discount_codes set used_count = used_count + 1 where id = d.id;
    if v_total > 0 then
      update booking.payments set amount = v_total where order_id = v_order.id and status = 'pending' and provider = 'manual';
    else   -- 100 % alennus: ei maksettavaa → vahvistetaan heti
      update booking.payments set status = 'cancelled' where order_id = v_order.id and status = 'pending';
      insert into booking.payments(order_id, method, provider, status, amount, paid_at, note)
      values (v_order.id, 'other', 'manual', 'paid', 0, now(), 'Alennuskoodi ' || d.code || ' (100 %)');
      update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = v_order.id and status = 'pending';
      update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()), hold_kind = null where id = v_order.id and status = 'pending';
      update booking.orders set payment_status = 'paid' where id = v_order.id;
    end if;
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
    return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;
  select * into v_order from booking.orders where id = v_order.id;
  return v_res || jsonb_build_object('total', v_total, 'status', v_order.status, 'hold_expires_at',
                    (select min(hold_expires_at) from booking.reservations where order_id = v_order.id and status = 'pending'),
                    'discount', v_disc, 'discount_code', d.code, 'code_type', 'discount',
                    'addons_total', (select coalesce(sum(line_total_gross), 0) from booking.order_items where order_id = v_order.id and kind = 'addon'))
                || case when v_qamt > 0 then jsonb_build_object('discount_source', 'code', 'quiet', null) else '{}'::jsonb end
                || booking._checkout_state_json(v_order.id);
end $function$;

CREATE OR REPLACE FUNCTION booking.public_preview_code(p_code text, p_rule_id bigint, p_date date, p_persons integer, p_addons jsonb DEFAULT NULL::jsonb, p_email text DEFAULT NULL::text, p_phone text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_code text := booking._norm_code(p_code); v_ip text := booking._client_ip(); v_card booking.annual_cards; d booking.discount_codes;
  r booking.schedule_rules; pr record; v_lines jsonb := '[]'::jsonb; v_sub numeric; v_err text; v_calc jsonb; e jsonb; a booking.addons; v_q int;
  v_quiet jsonb; v_qamt numeric := 0;  -- booking_162
begin
  if v_code = '' or char_length(v_code) > 40 then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;
  select * into r from booking.schedule_rules where id = p_rule_id and active;
  if r.id is null or p_persons is null or p_persons < 1 or p_persons > 50 then
    return jsonb_build_object('ok', false, 'code', 'invalid_session', 'message', 'Valitse vuoro ja henkilömäärä');
  end if;
  select * into pr from booking._rule_price(p_rule_id, p_persons);
  v_lines := jsonb_build_array(jsonb_build_object('key', 0, 'product_id', r.product_id, 'kind', 'reservation', 'gross', pr.total));
  v_sub := pr.total;
  if p_addons is not null and jsonb_typeof(p_addons) = 'array' then
    for e in select x from jsonb_array_elements(p_addons) x limit 20 loop
      continue when jsonb_typeof(e) <> 'object' or coalesce(e ->> 'quantity', '') !~ '^\d{1,4}$' or coalesce(e ->> 'id', '') !~ '^\d{1,18}$';
      v_q := (e ->> 'quantity')::int; continue when v_q = 0;
      select * into a from booking.addons where id = (e ->> 'id')::bigint and active;
      continue when a.id is null;
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('key', a.id, 'product_id', null, 'kind', 'addon', 'gross', a.price_gross * v_q));
      v_sub := v_sub + a.price_gross * v_q;
    end loop;
  end if;

  select * into v_card from booking.annual_cards where code = v_code;
  if v_card.id is null then select * into d from booking.discount_codes where code = v_code; end if;
  if v_card.id is null and d.id is null then return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code')); end if;
  -- booking_143: henkilökohtainen kortti + yhteystiedot, jotka eivät ole omistajan → sama vastaus kuin tuntemattomalla koodilla
  if v_card.id is not null and (nullif(btrim(coalesce(p_email, '')), '') is not null or booking._phone_key(p_phone) is not null)
     and not booking._annual_card_owner_ok(v_card, p_email, p_phone) then
    return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', booking._code_msg('invalid_code'));
  end if;

  if v_card.id is not null or d.is_annual_card_code then
    v_err := booking._annual_rule_check(p_rule_id, p_date, v_card, d);
    if v_err is null and (nullif(btrim(coalesce(p_email, '')), '') is not null or booking._phone_key(p_phone) is not null)
       and booking._annual_limit(v_card.customer_id, p_email, p_phone) then v_err := 'annual_card_limit'; end if;
    if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
    select * into pr from booking._rule_price(p_rule_id, booking._annual_max_persons());
    return jsonb_build_object('ok', true, 'type', case when v_card.id is not null then 'annual_card' else 'annual_code' end, 'code', v_code,
      'persons', booking._annual_max_persons(), 'addons_allowed', false, 'subtotal', pr.total, 'discount', pr.total, 'total', 0,
      'valid_to', coalesce(v_card.valid_to, d.valid_to));
  end if;

  v_err := booking._discount_state(d);
  if v_err is not null then return jsonb_build_object('ok', false, 'code', v_err, 'message', booking._code_msg(v_err)); end if;
  v_calc := booking._discount_split(d, v_lines);
  if (v_calc ->> 'discount')::numeric <= 0 then
    return jsonb_build_object('ok', false, 'code', 'code_not_applicable', 'message', booking._code_msg('code_not_applicable'));
  end if;
  -- booking_162: hiljaisen ajan ale ei pinoudu koodin kanssa; koodi voittaa vain jos se on suurempi etu
  v_quiet := booking._quiet_for_rule(p_rule_id, p_date);
  if v_quiet is not null then v_qamt := least(pr.total, round(pr.total * (v_quiet ->> 'percent')::numeric / 100, 2)); end if;
  if v_qamt > 0 and v_qamt >= (v_calc ->> 'discount')::numeric then
    return jsonb_build_object('ok', true, 'type', 'discount', 'code', v_code, 'kind', d.kind, 'value', d.value, 'subtotal', v_sub,
      'discount', v_qamt, 'total', v_sub - v_qamt, 'addons_allowed', true, 'discount_source', 'quiet', 'code_applied', false,
      'code_discount', (v_calc ->> 'discount')::numeric, 'quiet', jsonb_build_object('percent', (v_quiet ->> 'percent')::numeric, 'amount', v_qamt));
  end if;
  return jsonb_build_object('ok', true, 'type', 'discount', 'code', v_code, 'kind', d.kind, 'value', d.value, 'subtotal', v_sub,
    'discount', (v_calc ->> 'discount')::numeric, 'total', v_sub - (v_calc ->> 'discount')::numeric, 'addons_allowed', true)
    || case when v_qamt > 0 then jsonb_build_object('discount_source', 'code', 'code_applied', true,
         'quiet', jsonb_build_object('percent', (v_quiet ->> 'percent')::numeric, 'amount', v_qamt)) else '{}'::jsonb end;
end $function$;

-- ---------------------------------------------------------------- hallinta
create or replace function booking._quiet_rule_json(q booking.quiet_discount_rules)
returns jsonb language sql stable security definer set search_path = '' as $f$
  select jsonb_build_object('id', q.id, 'label', q.label, 'label_en', q.label_en, 'product_ids', to_jsonb(q.product_ids),
    'product_names', coalesce((select jsonb_agg(p.name order by p.id) from kb.products p where p.id = any(q.product_ids)), '[]'::jsonb),
    'hours_before', q.hours_before, 'percent', q.percent, 'condition', q.condition, 'channel', q.channel,
    'valid_from', q.valid_from, 'valid_to', q.valid_to, 'active', q.active, 'updated_at', q.updated_at)
$f$;

create or replace function booking.admin_quiet_rules_list()
returns jsonb language plpgsql stable security definer set search_path = '' as $f$
begin
  perform booking._require_staff();
  return jsonb_build_object(
    'enabled', coalesce((booking._setting('quiet_discounts.enabled', 'false'::jsonb) #>> '{}')::boolean, false),
    'can_edit', booking.has_permission('catalog.edit'),
    'can_toggle', booking.has_permission('settings.edit'),
    'rules', coalesce((select jsonb_agg(booking._quiet_rule_json(q) order by q.active desc, q.hours_before desc, q.id) from booking.quiet_discount_rules q), '[]'::jsonb),
    'products', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name) order by p.id)
                            from kb.products p where exists (select 1 from booking.schedule_rules sr where sr.product_id = p.id and sr.active)), '[]'::jsonb));
end $f$;

create or replace function booking.admin_quiet_rule_upsert(p_id bigint, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $f$
declare q booking.quiet_discount_rules; v_ids bigint[]; v_pct numeric; v_h int; v_from date; v_to date;
begin
  perform booking._require_permission('catalog.edit');
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then perform booking._err('invalid_value', 'Virheelliset tiedot'); end if;
  if p_id is not null then
    select * into q from booking.quiet_discount_rules where id = p_id for update;
    if q.id is null then perform booking._err('not_found', 'Sääntöä ei löydy'); end if;
  else
    q.active := true; q.condition := 'empty_slot'; q.channel := 'shop';
  end if;
  begin
    if p_patch ? 'label' then q.label := btrim(coalesce(p_patch ->> 'label', '')); end if;
    if p_patch ? 'label_en' then q.label_en := nullif(btrim(coalesce(p_patch ->> 'label_en', '')), ''); end if;
    if p_patch ? 'product_ids' then
      if jsonb_typeof(p_patch -> 'product_ids') <> 'array' then perform booking._err('invalid_value', 'Valitse tuotteet'); end if;
      select array_agg(distinct (x #>> '{}')::bigint order by (x #>> '{}')::bigint) into v_ids from jsonb_array_elements(p_patch -> 'product_ids') x;
      q.product_ids := v_ids;
    end if;
    if p_patch ? 'hours_before' then v_h := (p_patch ->> 'hours_before')::numeric; q.hours_before := v_h;
      if (p_patch ->> 'hours_before')::numeric <> v_h then perform booking._err('invalid_value', 'Tunnit kokonaislukuna'); end if; end if;
    if p_patch ? 'percent' then v_pct := (p_patch ->> 'percent')::numeric; q.percent := v_pct;
      if v_pct <> round(v_pct, 2) then perform booking._err('invalid_value', 'Prosentti enintään kahdella desimaalilla'); end if; end if;
    if p_patch ? 'valid_from' then v_from := nullif(p_patch ->> 'valid_from', '')::date; q.valid_from := v_from; end if;
    if p_patch ? 'valid_to' then v_to := nullif(p_patch ->> 'valid_to', '')::date; q.valid_to := v_to; end if;
    if p_patch ? 'active' then q.active := (p_patch ->> 'active')::boolean; end if;
  exception when invalid_text_representation or numeric_value_out_of_range or invalid_datetime_format or datetime_field_overflow then
    perform booking._err('invalid_value', 'Virheellinen arvo');
  end;
  if q.label is null or char_length(q.label) not between 1 and 80 then perform booking._err('invalid_value', 'Nimi 1–80 merkkiä'); end if;
  if q.label_en is not null and char_length(q.label_en) > 80 then perform booking._err('invalid_value', 'Englanninkielinen nimi enintään 80 merkkiä'); end if;
  if q.product_ids is null or cardinality(q.product_ids) not between 1 and 20
     or exists (select 1 from unnest(q.product_ids) u(id) where not exists (select 1 from kb.products p where p.id = u.id)) then
    perform booking._err('invalid_value', 'Valitse 1–20 olemassa olevaa tuotetta');
  end if;
  if q.hours_before is null or q.hours_before not between 1 and 336 then perform booking._err('invalid_value', 'Tunnit ennen alkua 1–336'); end if;
  if q.percent is null or q.percent <= 0 or q.percent > 90 then perform booking._err('invalid_value', 'Ale 0–90 %'); end if;
  if q.valid_from is not null and q.valid_to is not null and q.valid_to < q.valid_from then perform booking._err('invalid_value', 'Voimassaolon loppu ennen alkua'); end if;
  if q.active and exists (select 1 from booking.quiet_discount_rules o where o.active and o.id is distinct from q.id
                            and o.product_ids && q.product_ids and o.hours_before = q.hours_before) then
    perform booking._err('quiet_overlap', 'Samalle tuotteelle on jo aktiivinen porras samalla tuntimäärällä');
  end if;
  if p_id is null then
    insert into booking.quiet_discount_rules(label, label_en, product_ids, hours_before, percent, valid_from, valid_to, active)
    values (q.label, q.label_en, q.product_ids, q.hours_before, q.percent, q.valid_from, q.valid_to, q.active) returning * into q;
  else
    update booking.quiet_discount_rules set label = q.label, label_en = q.label_en, product_ids = q.product_ids, hours_before = q.hours_before,
           percent = q.percent, valid_from = q.valid_from, valid_to = q.valid_to, active = q.active
     where id = p_id returning * into q;
  end if;
  return jsonb_build_object('ok', true, 'rule', booking._quiet_rule_json(q));
end $f$;

create or replace function booking.admin_quiet_rule_delete(p_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $f$
begin
  perform booking._require_permission('catalog.edit');
  delete from booking.quiet_discount_rules where id = p_id;
  if not found then perform booking._err('not_found', 'Sääntöä ei löydy'); end if;
  return jsonb_build_object('ok', true);
end $f$;

create or replace function booking.admin_quiet_set_enabled(p_enabled boolean)
returns jsonb language plpgsql security definer set search_path = '' as $f$
begin
  perform booking._require_permission('settings.edit');
  if p_enabled is null then perform booking._err('invalid_value', 'Valitse päällä / pois'); end if;
  update booking.settings set value = to_jsonb(p_enabled), updated_by = auth.uid() where key = 'quiet_discounts.enabled';
  if not found then
    insert into booking.settings(key, value, description, is_public, updated_by)
    values ('quiet_discounts.enabled', to_jsonb(p_enabled), 'booking_162: hiljaisten aikojen ale käytössä (true/false). Säännöt: Hallinta → Hiljaiset ajat.', false, auth.uid());
  end if;
  return jsonb_build_object('ok', true, 'enabled', p_enabled);
end $f$;

-- Esikatselu hallintaan: tarjoukset seuraaville päiville myös kun kytkin on pois (enabled kertoo näkyvätkö ne asiakkaille).
create or replace function booking.admin_quiet_preview(p_from date default null, p_days integer default 7)
returns jsonb language plpgsql stable security definer set search_path = '' as $f$
declare v_from date := coalesce(p_from, (now() at time zone booking._tz())::date); v_days int := least(greatest(coalesce(p_days, 7), 1), 15);
begin
  perform booking._require_staff();
  return jsonb_build_object(
    'enabled', coalesce((booking._setting('quiet_discounts.enabled', 'false'::jsonb) #>> '{}')::boolean, false),
    'from', v_from, 'to', v_from + v_days - 1,
    'offers', coalesce((select jsonb_agg(to_jsonb(o) order by o.starts_at, o.rule_id) from booking._quiet_offers(v_from, v_from + v_days - 1, null, false) o), '[]'::jsonb));
end $f$;

-- ---------------------------------------------------------------- julkinen
-- Verkkokaupan / etusivun / viikkonäkymän tarjoukset. [] kun kytkin pois. Enintään 15 päivää kerralla.
create or replace function booking.public_quiet_offers(p_from date, p_to date, p_audience text default 'consumer')
returns jsonb language plpgsql stable security definer set search_path = '' as $f$
declare
  v_audience text := case when lower(btrim(coalesce(p_audience, ''))) = 'business' then 'business' else 'consumer' end;
  v_from date; v_to date;
begin
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 14 then
    perform booking._err('bad_range', 'Virheellinen päiväväli (enintään 15 päivää)');
  end if;
  if not coalesce((booking._setting('quiet_discounts.enabled', 'false'::jsonb) #>> '{}')::boolean, false) then return '[]'::jsonb; end if;
  v_from := greatest(p_from, (now() at time zone booking._tz())::date);
  v_to := p_to;
  if v_from > v_to then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'product_id', o.product_id, 'rule_id', o.rule_id, 'session_date', o.session_date, 'starts_at', o.starts_at, 'ends_at', o.ends_at,
      'label', o.label, 'label_en', o.label_en, 'percent', o.percent, 'base_price', o.base_price, 'discount_amount', o.discount_amount,
      'discounted_price', o.discounted_price, 'price_mode', o.price_mode, 'included_persons', o.included_persons,
      'extra_person_price', o.extra_person_price, 'next_change_at', o.next_change_at) order by o.starts_at, o.rule_id)
    from booking._quiet_offers(v_from, v_to, null, true) o
    join booking.product_config pc on pc.product_id = o.product_id
   where pc.bookable and pc.shop_visible and pc.lifecycle = 'current' and pc.audience = v_audience), '[]'::jsonb);
end $f$;

-- ---------------------------------------------------------------- oikeudet
revoke all on function booking._quiet_offers(date, date, bigint, boolean) from public, anon, authenticated;
revoke all on function booking._quiet_for_rule(bigint, date) from public, anon, authenticated;
revoke all on function booking._quiet_apply(bigint, jsonb) from public, anon, authenticated;
revoke all on function booking._quiet_rule_json(booking.quiet_discount_rules) from public, anon, authenticated;
revoke all on function booking._order_items_quiet_reset_trg() from public, anon, authenticated;
revoke all on function booking.admin_quiet_rules_list() from public, anon;
revoke all on function booking.admin_quiet_rule_upsert(bigint, jsonb) from public, anon;
revoke all on function booking.admin_quiet_rule_delete(bigint) from public, anon;
revoke all on function booking.admin_quiet_set_enabled(boolean) from public, anon;
revoke all on function booking.admin_quiet_preview(date, integer) from public, anon;
grant execute on function booking.admin_quiet_rules_list() to authenticated;
grant execute on function booking.admin_quiet_rule_upsert(bigint, jsonb) to authenticated;
grant execute on function booking.admin_quiet_rule_delete(bigint) to authenticated;
grant execute on function booking.admin_quiet_set_enabled(boolean) to authenticated;
grant execute on function booking.admin_quiet_preview(date, integer) to authenticated;
revoke all on function booking.public_quiet_offers(date, date, text) from public;
grant execute on function booking.public_quiet_offers(date, date, text) to anon, authenticated;
