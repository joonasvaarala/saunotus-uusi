-- ============================================================
-- booking_46_giftcards_delivery: lahjakortin toimitusvalinta (ostajalle / suoraan saajalle), saateteksti (vain sähköpostiin), ajastettu toimitus
--  * gift_cards: delivery_to ('buyer'|'recipient'), cover_message (<=1000, ei PDF:ssä), deliver_on (+deliver_time, Europe/Helsinki; null = heti), delivered_at
--  * public_buy_gift_card / admin_create_gift_card: uudet parametrit (p_delivery_to, p_cover_message, p_deliver_on, p_deliver_time; myös rivikohtaisesti items[]), validointi _gc_delivery_resolve
--  * ajastus: email_outbox.next_attempt_at (jo olemassa; email_outbox_claim kunnioittaa sitä, cron 1 min); saajan viesti ajastetaan, ostajan vahvistus lähtee heti maksun jälkeen
--  * email_outbox_mark: sent -> gift_cards.delivered_at; claim: toimituskentät + cover_message (vain saajan viesti)
--  * additiivinen: vanhat kutsut (ilman uusia parametreja) toimivat: delivery_to oletuksena 'recipient' jos saajan sähköposti annettu, muuten 'buyer'
-- Rollback: booking_46_ROLLBACK.sql
-- ============================================================

-- ---------- 1) gift_cards: toimitusvalinta ----------
alter table booking.gift_cards
  add column delivery_to   text    not null default 'buyer',
  add column cover_message text,
  add column deliver_on    date,
  add column deliver_time  time,
  add column delivered_at  timestamptz;
-- jo myönnetyt natiivikortit joilla on saajan sähköposti: toimitus saajalle (sama käytös kuin booking_45:ssä)
update booking.gift_cards set delivery_to = 'recipient' where source = 'native' and recipient_email is not null;
alter table booking.gift_cards add constraint gift_cards_delivery_to_check check (delivery_to in ('buyer', 'recipient'));
alter table booking.gift_cards add constraint gift_cards_cover_message_check check (cover_message is null or char_length(cover_message) <= 1000);
alter table booking.gift_cards add constraint gift_cards_delivery_consistency check (delivery_to = 'recipient' or (cover_message is null and deliver_on is null and deliver_time is null));
alter table booking.gift_cards add constraint gift_cards_delivery_recipient_email check (delivery_to <> 'recipient' or recipient_email is not null);
alter table booking.gift_cards add constraint gift_cards_deliver_time_needs_date check (deliver_time is null or deliver_on is not null);
comment on column booking.gift_cards.delivery_to is 'buyer = kortti PDF-linkkeineen ostajalle; recipient = suoraan saajalle (recipient_email pakollinen)';
comment on column booking.gift_cards.cover_message is 'Saateteksti sähköpostiin (ei näy kortti-PDF:ssä), max 1000 merkkiä; vain delivery_to=recipient';
comment on column booking.gift_cards.deliver_on is 'Ajastettu toimituspäivä (Europe/Helsinki); null = heti maksun jälkeen; kellonaika deliver_time, oletus 09:00';
comment on column booking.gift_cards.delivered_at is 'Milloin kortti-sähköposti lähetettiin oikeasti (email_outbox_mark sent); dry_run ei aseta';

-- ---------- 2) apufunktiot ----------

-- ajastus: seuraava lähetysaika (null = heti). Pelkkä päivä = klo 09:00 Helsingin aikaa; pelkkä tämä päivä = heti.
create or replace function booking._gc_deliver_ts(p_on date, p_time time) returns timestamptz
language plpgsql stable security definer set search_path to ''
as $$
declare v_ts timestamptz;
begin
  if p_on is null then return null; end if;
  if p_time is null and p_on <= booking._gc_today() then return null; end if;
  v_ts := ((p_on + coalesce(p_time, time '09:00'))::timestamp) at time zone booking._tz();
  return case when v_ts > now() then v_ts end;
end $$;

-- toimitusvalinnan validointi + normalisointi. Palauttaa {delivery_to, cover_message, deliver_on, deliver_time}. Virheet BK001: invalid_delivery_to, recipient_email_required,
-- invalid_cover_message, invalid_deliver_on, invalid_deliver_time, deliver_on_past, deliver_on_too_far. delivery_to=null -> 'recipient' jos saajan sähköposti annettu, muuten 'buyer'.
create or replace function booking._gc_delivery_resolve(p_to text, p_remail text, p_cover text, p_on text, p_time text, p_months int) returns jsonb
language plpgsql stable security definer set search_path to ''
as $$
declare
  v_to text := lower(nullif(btrim(coalesce(p_to, '')), '')); v_cover text; v_on date; v_t time; v_today date := booking._gc_today(); v_max date;
  v_on_txt text := nullif(btrim(coalesce(p_on, '')), ''); v_time_txt text := nullif(btrim(coalesce(p_time, '')), ''); m text[]; v_ts timestamptz;
begin
  if v_to is null then v_to := case when p_remail is not null then 'recipient' else 'buyer' end; end if;
  if v_to not in ('buyer', 'recipient') then perform booking._err('invalid_delivery_to', 'Toimitustapa: buyer (ostajalle) tai recipient (saajalle)'); end if;
  if v_to = 'buyer' then   -- saateteksti ja ajastus koskevat vain suoraa toimitusta saajalle; ohitetaan
    return jsonb_build_object('delivery_to', 'buyer', 'cover_message', null, 'deliver_on', null, 'deliver_time', null);
  end if;
  if p_remail is null then perform booking._err('recipient_email_required', 'Anna saajan sähköpostiosoite kun lahjakortti lähetetään suoraan saajalle'); end if;
  v_cover := nullif(btrim(regexp_replace(replace(coalesce(p_cover, ''), E'\r\n', E'\n'), '[\x00-\x09\x0b-\x1f\x7f]', '', 'g')), '');
  if v_cover is not null and char_length(v_cover) > 1000 then perform booking._err('invalid_cover_message', 'Saateteksti on liian pitkä (max 1000 merkkiä)'); end if;
  if v_on_txt is not null then
    m := regexp_match(v_on_txt, '^(\d{4}-\d{2}-\d{2})(?:[T ](\d{2}:\d{2}))?$');
    if m is null then perform booking._err('invalid_deliver_on', 'Anna ajankohta muodossa VVVV-KK-PP (+ valinnaisesti HH:MM)'); end if;
    begin v_on := m[1]::date; exception when others then perform booking._err('invalid_deliver_on', 'Virheellinen päivämäärä'); end;
    if m[2] is not null then v_time_txt := coalesce(v_time_txt, m[2]); end if;
  elsif v_time_txt is not null then
    perform booking._err('invalid_deliver_on', 'Anna myös toimituspäivä (kellonaika ilman päivää)');
  end if;
  if v_time_txt is not null then
    if v_time_txt !~ '^([01]\d|2[0-3]):[0-5]\d$' then perform booking._err('invalid_deliver_time', 'Kellonaika muodossa HH:MM'); end if;
    v_t := v_time_txt::time;
  end if;
  if v_on is not null then
    if v_on < v_today then perform booking._err('deliver_on_past', 'Toimituspäivä ei voi olla menneisyydessä'); end if;
    if v_t is not null then
      v_ts := ((v_on + v_t)::timestamp) at time zone booking._tz();
      if v_ts < now() - interval '5 minutes' then perform booking._err('deliver_on_past', 'Toimitusaika ei voi olla menneisyydessä'); end if;
    end if;
    v_max := (v_today + make_interval(months => least(12, p_months)))::date;
    if v_on > v_max then perform booking._err('deliver_on_too_far', format('Toimituspäivä voi olla enintään %s kk päässä (viimeistään %s)', least(12, p_months), to_char(v_max, 'FMDD.FMMM.YYYY'))); end if;
    if v_on = v_today and v_t is null then v_on := null; end if;   -- tänään ilman kellonaikaa = heti
  end if;
  return jsonb_build_object('delivery_to', 'recipient', 'cover_message', v_cover, 'deliver_on', v_on, 'deliver_time', v_t);
end $$;

-- ---------- 3) funktiot ----------
drop function if exists booking._gc_create_card(booking.gift_card_packages, numeric, text, bigint, bigint, bigint, text, text, text, text, text, text, integer, text, text, text);
drop function if exists booking._gc_sell(jsonb, bigint, text, text, text, text, text, text, integer, text, text, text);
drop function if exists booking.public_buy_gift_card(jsonb, text, text, text, boolean, text, text, text, text);
drop function if exists booking.admin_create_gift_card(text, numeric, integer, jsonb, text, text, text, text, text, integer, text, text, text);
drop function if exists booking._gc_enqueue_email(text, bigint, bigint[], text, text, text, text);
create or replace function booking._gc_card_json(g booking.gift_cards, p_admin boolean default true) returns jsonb
language sql stable security definer set search_path to ''
as $$
  select jsonb_build_object(
    'id', g.id, 'code', case when p_admin then booking.gift_code_fmt(g.code) end, 'code_last4', right(g.code, 4),
    'source', g.source, 'issuer', g.issuer, 'kind', g.kind, 'package_code', g.package_code,
    'package_name', (select p.name from booking.gift_card_packages p where p.code = g.package_code), 'product_id', g.product_id,
    'initial_amount', g.initial_amount, 'balance', g.balance, 'currency', g.currency, 'status', g.status,
    'effective_status', case when g.status = 'active' and g.valid_to is not null and g.valid_to < booking._gc_today() then 'expired' else g.status end,
    'valid_from', g.valid_from, 'valid_to', g.valid_to, 'balance_verified', g.balance_verified, 'balance_source', g.balance_source,
    'vat_treatment', g.vat_treatment, 'sale_vat_rate', g.sale_vat_rate, 'accounting_origin', g.accounting_origin, 'single_order', g.single_order,
    'buyer_customer_id', g.buyer_customer_id, 'buyer_name', g.buyer_name, 'buyer_email', g.buyer_email,
    'recipient_name', g.recipient_name, 'recipient_email', g.recipient_email, 'greeting', g.greeting, 'delivery_to', g.delivery_to, 'cover_message', g.cover_message, 'deliver_on', g.deliver_on, 'deliver_time', to_char(g.deliver_time, 'HH24:MI'), 'delivered_at', g.delivered_at, 'locale', g.locale,
    'purchase_order_id', g.purchase_order_id, 'order_no', (select o.order_no from booking.orders o where o.id = g.purchase_order_id),
    'public_token', g.public_token, 'created_at', g.created_at, 'activated_at', g.activated_at, 'last_used_at', g.last_used_at, 'note', g.note)
$$;
create or replace function booking._gc_create_card(p_pkg booking.gift_card_packages, p_amount numeric, p_status text, p_order bigint, p_order_item bigint, p_cust bigint,
    p_buyer_name text, p_buyer_email text, p_rname text, p_remail text, p_greeting text, p_locale text, p_valid_months int, p_vat text, p_note text,
    p_ledger_reason text default 'purchase', p_delivery_to text default 'buyer', p_cover text default null, p_deliver_on date default null, p_deliver_time time default null) returns booking.gift_cards
language plpgsql security definer set search_path to ''
as $$
declare g booking.gift_cards; v_try int := 0; v_code text; v_c text; v_today date := booking._gc_today(); v_active boolean := p_status = 'active';
begin
  loop
    v_try := v_try + 1;
    if v_try > 30 then perform booking._err('code_generation_failed', 'Koodin luonti epäonnistui, yritä uudelleen'); end if;
    v_code := booking._gc_random_code();
    if exists (select 1 from booking.gift_card_blocked_codes b where b.code_sha256 = encode(sha256(convert_to(v_code, 'UTF8')), 'hex')) then continue; end if;
    begin
      insert into booking.gift_cards(code, issuer, kind, product_id, initial_amount, balance, valid_from, valid_to, status, purchase_order_id, purchase_order_item_id, note, source,
                                     package_code, valid_months, buyer_customer_id, buyer_name, buyer_email, recipient_name, recipient_email, greeting, locale,
                                     vat_treatment, sale_vat_rate, accounting_origin, activated_at, created_by, balance_verified, balance_verified_at, balance_source, delivery_to, cover_message, deliver_on, deliver_time)
      values (v_code, 'own', p_pkg.kind, p_pkg.kb_product_id, p_amount, case when v_active then p_amount else 0 end,
              case when v_active then v_today end, case when v_active then (v_today + make_interval(months => p_valid_months))::date end,
              p_status, p_order, p_order_item, p_note, 'native', p_pkg.code, p_valid_months, p_cust, p_buyer_name, p_buyer_email, p_rname, p_remail, p_greeting, coalesce(p_locale, 'fi'),
              p_vat, case when p_vat = 'at_sale' then p_pkg.vat_rate else 0 end, 'native', case when v_active then now() end, auth.uid(), true, now(), 'native', coalesce(p_delivery_to, 'buyer'), p_cover, p_deliver_on, p_deliver_time)
      returning * into g;
      exit;
    exception when unique_violation then
      get stacked diagnostics v_c = constraint_name;
      if v_c is distinct from 'gift_cards_code_key' then raise; end if;
    end;
  end loop;
  if v_active then
    insert into booking.gift_card_ledger(gift_card_id, order_id, delta, balance_after, reason, created_by, note)
    values (g.id, p_order, p_amount, p_amount, p_ledger_reason, auth.uid(), p_note);
  end if;
  return g;
end $$;
create or replace function booking._gc_sell(p_items jsonb, p_cust bigint, p_channel text, p_locale text, p_buyer_name text, p_buyer_email text,
    p_status text, p_vat_override text default null, p_valid_months int default null, p_default_rname text default null, p_default_remail text default null,
    p_default_greeting text default null, p_default_delivery_to text default null, p_default_cover text default null, p_default_deliver_on text default null, p_default_deliver_time text default null) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare
  it jsonb; pkg booking.gift_card_packages; v_qty int; v_amt numeric; v_n int := 0; v_total numeric := 0; v_max int := (booking._setting('gift_cards.max_cards_per_order', '10'::jsonb) #>> '{}')::int;
  v_order booking.orders; v_oi bigint; v_vat text; v_rate numeric; i int; g booking.gift_cards; v_cards jsonb := '[]'::jsonb;
  v_rn text; v_re text; v_gr text; v_name text; v_months int; v_locale text := coalesce(nullif(p_locale, ''), 'fi');
  v_lines jsonb := '[]'::jsonb; v_dl jsonb;
begin
  if v_locale not in ('fi', 'en', 'sv') then perform booking._err('invalid_param', 'Virheellinen kieli'); end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 10 then
    perform booking._err('invalid_items', 'Anna 1–10 riviä: [{"package":"open","amount":50,"quantity":1}]');
  end if;
  if p_vat_override is not null and p_vat_override not in ('at_sale', 'at_redemption') then perform booking._err('invalid_param', 'Virheellinen ALV-käsittely'); end if;
  -- 1. validointi
  for it in select * from jsonb_array_elements(p_items) loop
    if jsonb_typeof(it) <> 'object' then perform booking._err('invalid_items', 'Rivi virheellinen'); end if;
    select * into pkg from booking.gift_card_packages where code = it ->> 'package';
    if not found then perform booking._err('invalid_package', 'Tuntematon lahjakorttipaketti'); end if;
    if not pkg.active then perform booking._err('package_inactive', 'Paketti ei ole myynnissä'); end if;
    v_qty := case when it ? 'quantity' and jsonb_typeof(it -> 'quantity') <> 'null' then
                 case when (it ->> 'quantity') ~ '^\d{1,2}$' then (it ->> 'quantity')::int else null end else 1 end;
    if v_qty is null or v_qty < 1 or v_qty > v_max then perform booking._err('invalid_quantity', format('Määrä 1–%s', v_max)); end if;
    if pkg.is_open then
      if coalesce(it ->> 'amount', '') !~ '^\d{1,5}(\.\d{1,2})?$' then perform booking._err('invalid_amount', 'Anna kortin summa'); end if;
      v_amt := (it ->> 'amount')::numeric;
      if v_amt < pkg.min_amount or v_amt > pkg.max_amount then perform booking._err('invalid_amount', format('Summa %s–%s €', pkg.min_amount, pkg.max_amount)); end if;
    else
      if it ? 'amount' and jsonb_typeof(it -> 'amount') <> 'null' and (it ->> 'amount') !~ '^\d{1,5}(\.\d{1,2})?$' then perform booking._err('invalid_amount', 'Virheellinen summa'); end if;
      if it ? 'amount' and jsonb_typeof(it -> 'amount') <> 'null' and (it ->> 'amount')::numeric <> pkg.price then perform booking._err('invalid_amount', 'Paketin hinta on kiinteä'); end if;
      v_amt := pkg.price;
    end if;
    v_rn := nullif(btrim(coalesce(it ->> 'recipient_name', p_default_rname, '')), '');
    v_re := nullif(lower(btrim(coalesce(it ->> 'recipient_email', p_default_remail, ''))), '');
    v_gr := nullif(btrim(regexp_replace(coalesce(it ->> 'greeting', p_default_greeting, ''), '[\x00-\x09\x0b\x0c\x0e-\x1f\x7f]', '', 'g')), '');
    if v_rn is not null and char_length(v_rn) > 120 then perform booking._err('invalid_name', 'Saajan nimi on liian pitkä (max 120)'); end if;
    if v_re is not null and (char_length(v_re) > 200 or not booking._valid_email(v_re)) then perform booking._err('invalid_email', 'Tarkista saajan sähköpostiosoite'); end if;
    if v_gr is not null and char_length(v_gr) > 300 then perform booking._err('invalid_greeting', 'Tervehdys on liian pitkä (max 300 merkkiä)'); end if;
    v_dl := booking._gc_delivery_resolve(coalesce(it ->> 'delivery_to', p_default_delivery_to), v_re, coalesce(it ->> 'cover_message', p_default_cover),
              coalesce(it ->> 'deliver_on', p_default_deliver_on), coalesce(it ->> 'deliver_time', p_default_deliver_time), coalesce(p_valid_months, pkg.valid_months));
    v_n := v_n + v_qty;
    v_total := v_total + coalesce(v_amt, 0) * v_qty;
    v_amt := null;
  end loop;
  if v_n > v_max then perform booking._err('too_many_cards', format('Enintään %s korttia / tilaus', v_max)); end if;
  -- 2. tilaus
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, created_by)
  values (p_cust, case when p_status = 'confirmed' then 'confirmed' else 'pending' end, 'unpaid', 0, p_channel, v_locale, auth.uid()) returning * into v_order;
  if p_status = 'confirmed' then update booking.orders set confirmed_at = now() where id = v_order.id; end if;
  -- 3. rivit + kortit
  for it in select * from jsonb_array_elements(p_items) loop
    select * into pkg from booking.gift_card_packages where code = it ->> 'package';
    v_qty := case when it ? 'quantity' and jsonb_typeof(it -> 'quantity') <> 'null' then (it ->> 'quantity')::int else 1 end;
    v_amt := case when pkg.is_open then (it ->> 'amount')::numeric else pkg.price end;
    v_vat := coalesce(p_vat_override, pkg.vat_treatment);
    v_rate := case when v_vat = 'at_sale' then pkg.vat_rate else 0 end;
    v_months := coalesce(p_valid_months, pkg.valid_months);
    v_name := case when pkg.is_open then pkg.name || ' ' || trim(trailing '.' from trim(trailing '0' from to_char(v_amt, 'FM99990.00'))) || ' €' else pkg.name end;
    insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
    values (v_order.id, pkg.kb_product_id, v_name, 'gift_card', v_qty, v_amt, v_amt * v_qty, v_rate,
            jsonb_build_object('gift_card_package', pkg.code, 'vat_treatment', v_vat)) returning id into v_oi;
    v_rn := nullif(btrim(coalesce(it ->> 'recipient_name', p_default_rname, '')), '');
    v_re := nullif(lower(btrim(coalesce(it ->> 'recipient_email', p_default_remail, ''))), '');
    v_gr := nullif(btrim(regexp_replace(coalesce(it ->> 'greeting', p_default_greeting, ''), '[\x00-\x09\x0b\x0c\x0e-\x1f\x7f]', '', 'g')), '');
    v_dl := booking._gc_delivery_resolve(coalesce(it ->> 'delivery_to', p_default_delivery_to), v_re, coalesce(it ->> 'cover_message', p_default_cover),
              coalesce(it ->> 'deliver_on', p_default_deliver_on), coalesce(it ->> 'deliver_time', p_default_deliver_time), coalesce(p_valid_months, pkg.valid_months));
    for i in 1..v_qty loop
      g := booking._gc_create_card(pkg, v_amt, 'pending_payment', v_order.id, v_oi, p_cust,
                                   p_buyer_name, p_buyer_email, v_rn, v_re, v_gr, v_locale, v_months, v_vat, null,
                                   p_delivery_to := v_dl ->> 'delivery_to', p_cover := v_dl ->> 'cover_message', p_deliver_on := (v_dl ->> 'deliver_on')::date, p_deliver_time := (v_dl ->> 'deliver_time')::time);
      if v_qty = 1 then update booking.order_items set gift_card_id = g.id where id = v_oi; end if;
      v_cards := v_cards || jsonb_build_object('id', g.id, 'public_token', g.public_token, 'package_code', pkg.code, 'package_name', pkg.name, 'amount', v_amt, 'status', g.status,
                                               'vat_treatment', v_vat, 'recipient_name', v_rn, 'delivery_to', g.delivery_to, 'deliver_on', g.deliver_on, 'deliver_time', to_char(g.deliver_time, 'HH24:MI'));
    end loop;
    v_lines := v_lines || jsonb_build_object('order_item_id', v_oi, 'package', pkg.code, 'quantity', v_qty, 'unit', v_amt, 'vat_rate', v_rate, 'vat_treatment', v_vat);
  end loop;
  update booking.orders set total_gross = v_total where id = v_order.id;
  return jsonb_build_object('order_id', v_order.id, 'order_no', v_order.order_no, 'public_token', v_order.public_token, 'total', v_total, 'cards', v_cards, 'lines', v_lines);
end $$;
create or replace function booking.public_buy_gift_card(p_items jsonb, p_name text, p_email text, p_phone text, p_marketing_consent boolean DEFAULT false, p_locale text DEFAULT 'fi'::text, p_recipient_name text DEFAULT NULL::text, p_recipient_email text DEFAULT NULL::text, p_greeting text DEFAULT NULL::text, p_delivery_to text DEFAULT NULL::text, p_cover_message text DEFAULT NULL::text, p_deliver_on text DEFAULT NULL::text, p_deliver_time text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $$
declare
  v_mode text := booking._setting('public_payment_mode', '"pay_later"'::jsonb) #>> '{}';
  v_ip text := booking._client_ip(); v_email text := lower(btrim(coalesce(p_email, ''))); v_name text := btrim(coalesce(p_name, '')); v_phone text := btrim(coalesce(p_phone, ''));
  v_cust bigint; v_res jsonb; v_status text; v_detail text; v_msg text;
begin
  if not booking._gc_flag('gift_cards.sale_enabled') then
    return jsonb_build_object('ok', false, 'code', 'sale_disabled', 'message', 'Lahjakorttien verkkomyynti ei ole vielä käytössä');
  end if;
  if v_ip is not null and not booking._rate_limit('gcbuy:ip:' || v_ip, (booking._setting('gift_cards.rl_buy_per_10min', '6'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_email <> '' and not booking._rate_limit('gcbuy:email:' || v_email, 4, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if char_length(v_name) < 2 or char_length(v_name) > 120 then return jsonb_build_object('ok', false, 'code', 'invalid_name', 'message', 'Anna nimi'); end if;
  if not booking._valid_email(v_email) then return jsonb_build_object('ok', false, 'code', 'invalid_email', 'message', 'Tarkista sähköpostiosoite'); end if;
  if v_phone !~ '^[0-9+()\- ]{6,30}$' then return jsonb_build_object('ok', false, 'code', 'invalid_phone', 'message', 'Tarkista puhelinnumero'); end if;
  v_status := case when v_mode = 'pay_later' then 'confirmed' else 'pending' end;
  begin
    v_cust := booking._upsert_customer(v_name, v_email, v_phone, p_marketing_consent, 'web_gift_card', p_locale, (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    v_res := booking._gc_sell(p_items, v_cust, 'web', p_locale, v_name, v_email, v_status, null, null, p_recipient_name, p_recipient_email, p_greeting, p_delivery_to, p_cover_message, p_deliver_on, p_deliver_time);
    insert into booking.payments(order_id, method, provider, status, amount)
    values ((v_res ->> 'order_id')::bigint, case when v_mode = 'pay_later' then 'pay_later' else 'visma_pay' end, case when v_mode = 'pay_later' then 'manual' else 'visma_pay' end,
            'pending', (v_res ->> 'total')::numeric);
    update booking.orders set payment_status = case when v_mode = 'pay_later' then 'unpaid' else 'pending' end where id = (v_res ->> 'order_id')::bigint;
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
    return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;
  return jsonb_build_object('ok', true, 'order_no', v_res -> 'order_no', 'token', v_res -> 'public_token', 'status', v_status, 'total', v_res -> 'total',
    'payment_mode', v_mode, 'payment_url', null, 'cards', (select coalesce(jsonb_agg(c - 'id'), '[]'::jsonb) from jsonb_array_elements(v_res -> 'cards') c),
    'note', 'Kortit aktivoituvat ja koodit toimitetaan kun tilaus on maksettu');
end $$;
create or replace function booking.admin_create_gift_card(p_package text, p_amount numeric DEFAULT NULL::numeric, p_quantity integer DEFAULT 1, p_buyer jsonb DEFAULT NULL::jsonb, p_recipient_name text DEFAULT NULL::text, p_recipient_email text DEFAULT NULL::text, p_greeting text DEFAULT NULL::text, p_payment_method text DEFAULT NULL::text, p_vat_treatment text DEFAULT NULL::text, p_valid_months integer DEFAULT NULL::integer, p_locale text DEFAULT 'fi'::text, p_note text DEFAULT NULL::text, p_channel text DEFAULT 'admin'::text, p_delivery_to text DEFAULT NULL::text, p_cover_message text DEFAULT NULL::text, p_deliver_on text DEFAULT NULL::text, p_deliver_time text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $$
declare
  v_cust bigint; v_bname text; v_bemail text; v_res jsonb; v_rec jsonb; v_oid bigint; v_ids bigint[]; pkg booking.gift_card_packages; v_i int; g booking.gift_cards;
  v_rn text; v_re text; v_gr text; v_vat text; v_months int; v_cards jsonb := '[]'::jsonb; v_max int := (booking._setting('gift_cards.max_cards_per_order', '10'::jsonb) #>> '{}')::int; v_amt numeric; v_dl jsonb;
begin
  perform booking._require_permission('giftcards.manage');
  if p_payment_method is not null then perform booking._require_permission('payments.manage'); end if;
  if p_channel not in ('admin', 'phone', 'email', 'walk_in', 'other') then perform booking._err('invalid_param', 'Virheellinen kanava'); end if;
  if p_valid_months is not null and (p_valid_months < 1 or p_valid_months > 36) then perform booking._err('invalid_param', 'Voimassaolo 1–36 kk'); end if;
  if p_quantity is null or p_quantity < 1 or p_quantity > v_max then perform booking._err('invalid_quantity', format('Määrä 1–%s', v_max)); end if;
  -- ostaja
  if p_buyer is not null then
    if p_buyer ? 'customer_id' and coalesce(p_buyer ->> 'customer_id', '') ~ '^\d{1,18}$' then
      select id, name, email into v_cust, v_bname, v_bemail from booking.customers where id = (p_buyer ->> 'customer_id')::bigint;
      if v_cust is null then perform booking._err('not_found', 'Asiakasta ei löydy'); end if;
    elsif nullif(btrim(coalesce(p_buyer ->> 'name', '')), '') is not null then
      v_bname := btrim(p_buyer ->> 'name'); v_bemail := nullif(lower(btrim(coalesce(p_buyer ->> 'email', ''))), '');
      if char_length(v_bname) > 120 then perform booking._err('invalid_name', 'Nimi on liian pitkä'); end if;
      if v_bemail is not null then
        if not booking._valid_email(v_bemail) then perform booking._err('invalid_email', 'Tarkista sähköpostiosoite'); end if;
        v_cust := booking._upsert_customer(v_bname, v_bemail, nullif(btrim(coalesce(p_buyer ->> 'phone', '')), ''), false, 'admin_gift_card', p_locale);
      end if;
    end if;
  end if;
  if p_payment_method is not null then
    -- myynti: tilaus + (maksettu | pay_later) -> kortit aktivoituvat kun tilaus on maksettu
    v_res := booking._gc_sell(jsonb_build_array(jsonb_build_object('package', p_package, 'amount', p_amount, 'quantity', p_quantity)), v_cust, p_channel, p_locale, v_bname, v_bemail,
                              'confirmed', p_vat_treatment, p_valid_months, p_recipient_name, p_recipient_email, p_greeting, p_delivery_to, p_cover_message, p_deliver_on, p_deliver_time);
    v_oid := (v_res ->> 'order_id')::bigint;
    if p_payment_method in ('pay_later', 'invoice') then      -- ei vielä maksettu: kortit aktivoituvat kun maksu kirjataan (admin_record_payment)
      insert into booking.payments(order_id, method, provider, status, amount, note, created_by) values (v_oid, p_payment_method, 'manual', 'pending', (v_res ->> 'total')::numeric, p_note, auth.uid());
    else
      v_rec := booking.admin_record_payment(v_oid, p_payment_method, (v_res ->> 'total')::numeric, p_note);
    end if;
    select array_agg((c ->> 'id')::bigint order by (c ->> 'id')::bigint) into v_ids from jsonb_array_elements(v_res -> 'cards') c;
    select coalesce(jsonb_agg(booking._gc_card_json(x, true) order by x.id), '[]'::jsonb) into v_cards from booking.gift_cards x where x.id = any (v_ids);
    return jsonb_build_object('ok', true, 'order_id', v_oid, 'order_no', v_res -> 'order_no', 'total', v_res -> 'total', 'cards', v_cards,
                              'payment', v_rec, 'paid', v_rec is not null);
  end if;
  -- maksuton myöntö (hyvitys/hyvä tahto): ei tilausta, kortti aktiivinen heti; ALV-käsittely oletuksena at_sale (ei uutta liikevaihtoa lunastuksessa)
  if nullif(btrim(coalesce(p_note, '')), '') is null or char_length(btrim(p_note)) < 3 then perform booking._err('invalid_param', 'Anna maksuttoman kortin syy (p_note)'); end if;
  select * into pkg from booking.gift_card_packages where code = p_package;
  if not found then perform booking._err('invalid_package', 'Tuntematon lahjakorttipaketti'); end if;
  if pkg.is_open then
    if p_amount is null or p_amount <> round(p_amount, 2) or p_amount < pkg.min_amount or p_amount > pkg.max_amount then perform booking._err('invalid_amount', format('Summa %s–%s €', pkg.min_amount, pkg.max_amount)); end if;
    v_amt := p_amount;
  else
    if p_amount is not null and p_amount <> pkg.price then perform booking._err('invalid_amount', 'Paketin hinta on kiinteä'); end if;
    v_amt := pkg.price;
  end if;
  v_vat := coalesce(p_vat_treatment, 'at_sale');
  if v_vat not in ('at_sale', 'at_redemption') then perform booking._err('invalid_param', 'Virheellinen ALV-käsittely'); end if;
  v_rn := nullif(btrim(coalesce(p_recipient_name, '')), ''); v_re := nullif(lower(btrim(coalesce(p_recipient_email, ''))), '');
  v_gr := nullif(btrim(regexp_replace(coalesce(p_greeting, ''), '[\x00-\x09\x0b\x0c\x0e-\x1f\x7f]', '', 'g')), '');
  if v_rn is not null and char_length(v_rn) > 120 then perform booking._err('invalid_name', 'Saajan nimi on liian pitkä'); end if;
  if v_re is not null and not booking._valid_email(v_re) then perform booking._err('invalid_email', 'Tarkista saajan sähköpostiosoite'); end if;
  if v_gr is not null and char_length(v_gr) > 300 then perform booking._err('invalid_greeting', 'Tervehdys on liian pitkä (max 300 merkkiä)'); end if;
  v_months := coalesce(p_valid_months, pkg.valid_months);
  v_dl := booking._gc_delivery_resolve(p_delivery_to, v_re, p_cover_message, p_deliver_on, p_deliver_time, v_months);
  for v_i in 1..p_quantity loop
    g := booking._gc_create_card(pkg, v_amt, 'active', null, null, v_cust, v_bname, v_bemail, v_rn, v_re, v_gr, p_locale, v_months, v_vat, btrim(p_note), 'manual_issue',
                                   p_delivery_to := v_dl ->> 'delivery_to', p_cover := v_dl ->> 'cover_message', p_deliver_on := (v_dl ->> 'deliver_on')::date, p_deliver_time := (v_dl ->> 'deliver_time')::time);
    v_cards := v_cards || booking._gc_card_json(g, true);
  end loop;
  return jsonb_build_object('ok', true, 'order_id', null, 'total', 0, 'cards', v_cards, 'paid', false, 'complimentary', true);
end $$;
create or replace function booking.public_get_order_gift_cards(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path to ''
as $$
declare o booking.orders;
begin
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Tilausta ei löydy'); end if;
  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'payment_status', o.payment_status, 'cards', coalesce((
    select jsonb_agg(jsonb_build_object('token', g.public_token, 'package_code', g.package_code, 'package_name', (select p.name from booking.gift_card_packages p where p.code = g.package_code),
      'amount', g.initial_amount, 'status', g.status, 'valid_to', g.valid_to, 'recipient_name', g.recipient_name, 'delivery_to', g.delivery_to, 'deliver_on', g.deliver_on, 'deliver_time', to_char(g.deliver_time, 'HH24:MI'), 'delivered_at', g.delivered_at, 'ready', g.status in ('active', 'used', 'expired')) order by g.id)
      from booking.gift_cards g where g.purchase_order_id = o.id), '[]'::jsonb));
end $$;
create or replace function booking._gc_enqueue_email(p_kind text, p_order bigint, p_card_ids bigint[], p_to text, p_to_name text, p_locale text, p_dedupe text, p_send_at timestamptz default null) returns boolean
language plpgsql security definer set search_path to ''
as $$
declare v_mode text; v_n int;
begin
  if p_to is null or not booking._valid_email(lower(btrim(p_to))) or coalesce(cardinality(p_card_ids), 0) = 0 then return false; end if;
  select mode into v_mode from booking.integration_config where key = 'resend';
  insert into booking.email_outbox(kind, order_id, locale, dedupe_key, status, next_attempt_at, payload)
  values (p_kind, p_order, case when p_locale in ('fi', 'en', 'sv') then p_locale else 'fi' end, p_dedupe, case when coalesce(v_mode, 'off') = 'off' then 'skipped' else 'pending' end, coalesce(p_send_at, now()),
          jsonb_build_object('card_ids', to_jsonb(p_card_ids), 'to_email', lower(btrim(p_to)), 'to_name', nullif(btrim(coalesce(p_to_name, '')), '')))
  on conflict (dedupe_key) do nothing;
  get diagnostics v_n = row_count;
  return v_n > 0;
end $$;
create or replace function booking._gc_activate_order(p_order bigint) returns int
language plpgsql security definer set search_path to ''
as $$
declare g booking.gift_cards; v_n int := 0; v_today date := booking._gc_today(); v_ids bigint[] := '{}'; v_first booking.gift_cards;
begin
  for g in select * from booking.gift_cards where purchase_order_id = p_order and status = 'pending_payment' order by id for update loop
    update booking.gift_cards set status = 'active', balance = initial_amount, valid_from = v_today, valid_to = (v_today + make_interval(months => g.valid_months))::date,
           activated_at = now(), balance_verified = true, balance_verified_at = now(), balance_source = 'native' where id = g.id;
    insert into booking.gift_card_ledger(gift_card_id, order_id, delta, balance_after, reason, created_by, note)
    values (g.id, p_order, g.initial_amount, g.initial_amount, 'purchase', auth.uid(), 'Ostotilaus maksettu');
    v_n := v_n + 1; v_ids := v_ids || g.id;
    if v_first.id is null then v_first := g; end if;
    if g.delivery_to = 'recipient' and g.recipient_email is not null then
      perform booking._gc_enqueue_email('gift_card_recipient', null, array[g.id], g.recipient_email, g.recipient_name, g.locale, 'gcrecip:' || g.id, booking._gc_deliver_ts(g.deliver_on, g.deliver_time));
    end if;
  end loop;
  if v_n > 0 then
    perform booking._gc_enqueue_email('gift_card_buyer', p_order, v_ids, coalesce(v_first.buyer_email, (select c.email from booking.orders o join booking.customers c on c.id = o.customer_id where o.id = p_order)),
                                      coalesce(v_first.buyer_name, (select c.name from booking.orders o join booking.customers c on c.id = o.customer_id where o.id = p_order)), v_first.locale, 'gcbuyer:' || p_order);
  end if;
  return v_n;
end $$;
create or replace function booking._gc_issue_email_trg() returns trigger language plpgsql security definer set search_path to ''
as $$ begin
  if new.delivery_to = 'recipient' and new.recipient_email is not null then
    perform booking._gc_enqueue_email('gift_card_recipient', null, array[new.id], new.recipient_email, new.recipient_name, new.locale, 'gcrecip:' || new.id, booking._gc_deliver_ts(new.deliver_on, new.deliver_time));
  end if;
  if new.buyer_email is not null then
    perform booking._gc_enqueue_email('gift_card_buyer', null, array[new.id], new.buyer_email, new.buyer_name, new.locale, 'gcbuyer:card:' || new.id);
  end if;
  return null;
end $$;
CREATE OR REPLACE FUNCTION booking.email_outbox_claim(p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_ids bigint[]; v_site text := coalesce(booking._setting('site_base_url') #>> '{}', ''); v_op text := coalesce(booking._setting('order_page_path') #>> '{}', '/tilaus/');
        v_pp text := coalesce(booking._setting('payment_link_path') #>> '{}', '/maksa/'); v_res jsonb;
begin
  update booking.email_outbox set status = 'pending', locked_at = null where status = 'sending' and locked_at < now() - interval '10 minutes';
  select coalesce(array_agg(id), '{}') into v_ids from (
    select id from booking.email_outbox where status in ('pending','failed') and next_attempt_at <= now() order by id limit greatest(least(coalesce(p_limit, 20), 50), 1) for update skip locked) q;
  update booking.email_outbox set status = 'sending', locked_at = now(), attempts = attempts + 1 where id = any (v_ids);
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id, 'kind', e.kind, 'locale', e.locale, 'attempts', e.attempts, 'max_attempts', e.max_attempts, 'to', coalesce(nullif(e.payload ->> 'to_email', ''), c.email), 'to_name', coalesce(nullif(e.payload ->> 'to_name', ''), c.name),
      'order', case when o.id is null or e.kind = 'gift_card_recipient' then null else jsonb_build_object('order_no', o.order_no, 'order_url', v_site || v_op || '?t=' || o.public_token, 'total', o.total_gross, 'status', o.status,
          'items', coalesce((select jsonb_agg(jsonb_build_object('name', i.product_name, 'quantity', i.quantity, 'line_total', i.line_total_gross, 'vat_rate', i.vat_rate, 'kind', i.kind) order by i.id) from booking.order_items i where i.order_id = o.id), '[]'::jsonb),
          'reservations', coalesce((select jsonb_agg(jsonb_build_object('product_name', it.product_name, 'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'status', r.status) order by r.starts_at)
              from booking.reservations r left join booking.order_items it on it.id = r.order_item_id where r.order_id = o.id), '[]'::jsonb)) end,
      'gift_cards', case when e.kind like 'gift_card\_%' then (select coalesce(jsonb_agg(jsonb_build_object('public_token', g.public_token, 'package_code', g.package_code, 'package_name', pk.name, 'package_name_en', pk.name_en,
            'kind', g.kind, 'amount', g.initial_amount, 'valid_to', g.valid_to, 'recipient_name', g.recipient_name, 'greeting', g.greeting, 'buyer_name', g.buyer_name, 'persons', pk.persons,
            'locale', g.locale, 'status', g.status, 'delivery_to', g.delivery_to, 'deliver_on', g.deliver_on, 'deliver_time', to_char(g.deliver_time, 'HH24:MI'),
            'deliver_at', booking._gc_deliver_ts(g.deliver_on, g.deliver_time), 'delivered_at', g.delivered_at,
            'recipient_email', case when e.kind = 'gift_card_buyer' then g.recipient_email end, 'cover_message', case when e.kind = 'gift_card_recipient' then g.cover_message end) order by g.id), '[]'::jsonb)
          from booking.gift_cards g left join booking.gift_card_packages pk on pk.code = g.package_code
         where g.id in (select (x)::bigint from jsonb_array_elements_text(coalesce(e.payload -> 'card_ids', '[]'::jsonb)) x)) end,
      'receipt', case when rc.id is null then null else jsonb_build_object('id', rc.id, 'receipt_no', rc.receipt_no, 'kind', rc.kind, 'text_body', rc.text_body, 'public_token', rc.public_token, 'total', rc.total_gross, 'issued_at', rc.issued_at) end,
      'payment', case when p.id is null then null else jsonb_build_object('id', p.id, 'amount', p.amount, 'link_url', case when p.provider <> 'manual' and p.status = 'pending' then v_site || v_pp || '?p=' || p.link_token end,
          'link_expires_at', p.link_expires_at) end) order by e.id), '[]'::jsonb)
    into v_res
    from booking.email_outbox e left join booking.orders o on o.id = e.order_id left join booking.customers c on c.id = o.customer_id
    left join booking.receipts rc on rc.id = e.receipt_id left join booking.payments p on p.id = e.payment_id
   where e.id = any (v_ids);
  return v_res;
end $function$;
create or replace function booking.email_outbox_mark(p_id bigint, p_result text, p_provider_id text DEFAULT NULL::text, p_error text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $$
declare e booking.email_outbox;
begin
  if p_result not in ('sent','dry_run','failed','skipped') then perform booking._err('invalid_param', 'p_result'); end if;
  select * into e from booking.email_outbox where id = p_id for update;
  if not found then perform booking._err('not_found', 'Viestiä ei löydy'); end if;
  if p_result = 'sent' then
    update booking.email_outbox set status = 'sent', sent_at = now(), provider_id = p_provider_id, last_error = null, locked_at = null where id = p_id;
    if e.receipt_id is not null then update booking.receipts set sent_at = now() where id = e.receipt_id and sent_at is null; end if;
    if e.kind = 'payment_link' and e.payment_id is not null then update booking.payments set link_sent_at = now() where id = e.payment_id; end if;
    -- lahjakortti toimitettu: saajalle (delivery_to='recipient') tai ostajalle (delivery_to='buyer')
    if e.kind in ('gift_card_recipient', 'gift_card_buyer') then
      update booking.gift_cards g set delivered_at = now()
       where g.delivered_at is null and g.id in (select (x)::bigint from jsonb_array_elements_text(coalesce(e.payload -> 'card_ids', '[]'::jsonb)) x)
         and g.delivery_to = case when e.kind = 'gift_card_recipient' then 'recipient' else 'buyer' end;
    end if;
  elsif p_result = 'failed' then
    update booking.email_outbox set status = case when attempts >= max_attempts then 'dead' else 'failed' end, last_error = left(p_error, 500), locked_at = null,
           next_attempt_at = now() + make_interval(mins => attempts * attempts) where id = p_id;
  else
    update booking.email_outbox set status = p_result, last_error = left(p_error, 500), locked_at = null where id = p_id;
  end if;
end $$;

revoke all on function booking._gc_deliver_ts(date, time) from public, anon, authenticated;
revoke all on function booking._gc_delivery_resolve(text, text, text, text, text, int) from public, anon, authenticated;
revoke all on function booking._gc_create_card(booking.gift_card_packages, numeric, text, bigint, bigint, bigint, text, text, text, text, text, text, integer, text, text, text, text, text, date, time) from public, anon, authenticated;
revoke all on function booking._gc_sell(jsonb, bigint, text, text, text, text, text, text, integer, text, text, text, text, text, text, text) from public, anon, authenticated;
revoke all on function booking._gc_enqueue_email(text, bigint, bigint[], text, text, text, text, timestamptz) from public, anon, authenticated;
grant execute on function booking._gc_create_card(booking.gift_card_packages, numeric, text, bigint, bigint, bigint, text, text, text, text, text, text, integer, text, text, text, text, text, date, time) to service_role;
grant execute on function booking._gc_sell(jsonb, bigint, text, text, text, text, text, text, integer, text, text, text, text, text, text, text) to service_role;
grant execute on function booking._gc_deliver_ts(date, time) to service_role;
grant execute on function booking._gc_delivery_resolve(text, text, text, text, text, int) to service_role;
revoke all on function booking.public_buy_gift_card(jsonb, text, text, text, boolean, text, text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function booking.public_buy_gift_card(jsonb, text, text, text, boolean, text, text, text, text, text, text, text, text) to service_role, anon, authenticated;
revoke all on function booking.admin_create_gift_card(text, numeric, integer, jsonb, text, text, text, text, text, integer, text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function booking.admin_create_gift_card(text, numeric, integer, jsonb, text, text, text, text, text, integer, text, text, text, text, text, text, text) to service_role, authenticated;
