-- booking_44_giftcards_rpc (17.10.2026) – lahjakortit vaihe 1 (b): RPC:t, lunastus, ALV/kirjanpito-käsittely, ylläpito
-- Edellyttää booking_43_giftcards_schema.
-- Sisältö:
--   1) sisäiset _gc_*-funktiot: koodin generointi (HH + Johkun merkistö, retry UNIQUE-törmäyksessä + estolista), saldo/ledger, myynti, lunastus (kortti FOR UPDATE, ei negatiivista saldoa, ei yli maksamattoman)
--   2) public_*: public_gift_card_packages, public_check_gift_card (rate limit: 10 epäonnistunutta / IP-avain / 10 min), public_apply_gift_card, public_buy_gift_card, public_get_order_gift_cards, public_get_gift_card
--   3) admin_*: admin_create_gift_card, admin_list_gift_cards, admin_get_gift_card, admin_set_gift_card_expiry, admin_adjust_gift_card, admin_deactivate_gift_card, admin_reactivate_gift_card,
--      admin_redeem_gift_card, admin_list_gift_card_packages, admin_update_gift_card_package; gift_cards_housekeeping (cron tunneittain)
--   4) svc_gift_cards_johku_upsert (service_role): Johku-tuonti/synkka
--   5) ALV/kirjanpito: _acct_excluded laajennettu (booking_41): lahjakorttimaksu jonka kortti on accounting_origin='johku' TAI vat_treatment='at_sale' ei tuota kuittia/raporttiriviä/outbox-riviä
--      (ALV on jo kirjattu myynnissä / Johkussa). Johku-lähtöisten korttien lunastus uudessa natiivitilauksessa = lahjakorttimaksu ilman uutta ALV-myyntiä.
--      at_redemption-kortti (avoin kortti oletuksena): myynti 0 % ALV (ennakkomaksu), lunastus = normaali ALV-kuitti (maksutapa Lahjakortti). Konfiguroitavissa kortilla/paketilla (vat_treatment).
--   6) admin_refund: lahjakorttimaksun hyvitys palautuu kortille (ei rahana); lahjakorttien ostomaksu hyvitetään vain kokonaan (kortit mitätöidään, ei jos käytetty)
--   7) _report_json: statistics.gift_cards (additiivinen); admin_list_payments: is_johku käyttää _is_johku_row (ei merkitse lahjakorttimaksuja Johkuksi)
-- Rollback: booking_44_ROLLBACK.sql

-- ============================================================
-- 1) sisäiset apufunktiot (vain service_role / SECURITY DEFINER -kutsut)
-- ============================================================
create or replace function booking._gc_today() returns date language sql stable set search_path to ''
as $$ select (now() at time zone booking._tz())::date $$;

create or replace function booking._gc_flag(p_key text) returns boolean language sql stable security definer set search_path to ''
as $$ select coalesce((booking._setting(p_key, 'false'::jsonb) #>> '{}')::boolean, false) $$;

create or replace function booking._gc_random_code() returns text language plpgsql volatile security definer set search_path to ''
as $$
declare v_cs constant text := '3479ACEFHJKLMNPRTUVWXY'; v_out text := 'HH'; v_bytes bytea; i int; b int;
begin
  while char_length(v_out) < 12 loop
    v_bytes := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
    for i in 0..15 loop
      continue when i in (6, 8);                  -- uuid v4:n kiinteät bitit pois
      b := get_byte(v_bytes, i);
      if b < 242 then                              -- 242 = 11 × 22 -> ei modulo-vinoumaa
        v_out := v_out || substr(v_cs, (b % 22) + 1, 1);
        exit when char_length(v_out) >= 12;
      end if;
    end loop;
  end loop;
  return v_out;
end $$;

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
    'recipient_name', g.recipient_name, 'recipient_email', g.recipient_email, 'greeting', g.greeting, 'locale', g.locale,
    'purchase_order_id', g.purchase_order_id, 'order_no', (select o.order_no from booking.orders o where o.id = g.purchase_order_id),
    'public_token', g.public_token, 'created_at', g.created_at, 'activated_at', g.activated_at, 'last_used_at', g.last_used_at, 'note', g.note)
$$;

-- kortin luonti (koodin generointi: HH + 10 merkkiä Johkun merkistöstä, retry-loop törmäyksessä UNIQUE(code) / estolista)
create or replace function booking._gc_create_card(p_pkg booking.gift_card_packages, p_amount numeric, p_status text, p_order bigint, p_order_item bigint, p_cust bigint,
    p_buyer_name text, p_buyer_email text, p_rname text, p_remail text, p_greeting text, p_locale text, p_valid_months int, p_vat text, p_note text,
    p_ledger_reason text default 'purchase') returns booking.gift_cards
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
                                     vat_treatment, sale_vat_rate, accounting_origin, activated_at, created_by, balance_verified, balance_verified_at, balance_source)
      values (v_code, 'own', p_pkg.kind, p_pkg.kb_product_id, p_amount, case when v_active then p_amount else 0 end,
              case when v_active then v_today end, case when v_active then (v_today + make_interval(months => p_valid_months))::date end,
              p_status, p_order, p_order_item, p_note, 'native', p_pkg.code, p_valid_months, p_cust, p_buyer_name, p_buyer_email, p_rname, p_remail, p_greeting, coalesce(p_locale, 'fi'),
              p_vat, case when p_vat = 'at_sale' then p_pkg.vat_rate else 0 end, 'native', case when v_active then now() end, auth.uid(), true, now(), 'native')
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

-- saldomuutos + ledger (kutsuja ei tarvitse lukita; lukitaan täällä)
create or replace function booking._gc_apply(p_card bigint, p_delta numeric, p_reason text, p_order bigint default null, p_payment bigint default null,
    p_note text default null, p_meta jsonb default null, p_at timestamptz default null) returns numeric
language plpgsql security definer set search_path to ''
as $$
declare g booking.gift_cards; v_bal numeric; v_status text;
begin
  select * into g from booking.gift_cards where id = p_card for update;
  if not found then perform booking._err('gift_card_not_found', 'Korttia ei löydy'); end if;
  v_bal := g.balance + p_delta;
  if v_bal < 0 then perform booking._err('insufficient_balance', format('Kortin saldo (%s €) ei riitä', g.balance)); end if;
  v_status := g.status;
  if g.status in ('active', 'used', 'expired') then
    v_status := case when v_bal = 0 then 'used' when g.valid_to is not null and g.valid_to < booking._gc_today() then 'expired' else 'active' end;
  end if;
  update booking.gift_cards set balance = v_bal, status = v_status, last_used_at = case when p_reason = 'redemption' then now() else last_used_at end where id = p_card;
  insert into booking.gift_card_ledger(gift_card_id, order_id, payment_id, delta, balance_after, reason, at, created_by, note, meta)
  values (p_card, p_order, p_payment, p_delta, v_bal, p_reason, coalesce(p_at, now()), auth.uid(), p_note, p_meta);
  return v_bal;
end $$;

-- ostotilauksen kortit aktivoituvat kun tilaus on maksettu (orders.payment_status -> paid)
create or replace function booking._gc_activate_order(p_order bigint) returns int
language plpgsql security definer set search_path to ''
as $$
declare g booking.gift_cards; v_n int := 0; v_today date := booking._gc_today();
begin
  for g in select * from booking.gift_cards where purchase_order_id = p_order and status = 'pending_payment' order by id for update loop
    update booking.gift_cards set status = 'active', balance = initial_amount, valid_from = v_today, valid_to = (v_today + make_interval(months => g.valid_months))::date,
           activated_at = now(), balance_verified = true, balance_verified_at = now(), balance_source = 'native' where id = g.id;
    insert into booking.gift_card_ledger(gift_card_id, order_id, delta, balance_after, reason, created_by, note)
    values (g.id, p_order, g.initial_amount, g.initial_amount, 'purchase', auth.uid(), 'Ostotilaus maksettu');
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

create or replace function booking._gc_orders_paid_trg() returns trigger language plpgsql security definer set search_path to ''
as $$ begin
  if exists (select 1 from booking.gift_cards where purchase_order_id = new.id and status = 'pending_payment') then perform booking._gc_activate_order(new.id); end if;
  return null;
end $$;
create trigger orders_gc_paid after update of payment_status on booking.orders
  for each row when (new.payment_status = 'paid' and old.payment_status is distinct from 'paid') execute function booking._gc_orders_paid_trg();

create or replace function booking._gc_orders_cancel_trg() returns trigger language plpgsql security definer set search_path to ''
as $$ declare c record; begin
  for c in select id from booking.gift_cards where purchase_order_id = new.id and status = 'pending_payment' for update loop
    update booking.gift_cards set status = 'cancelled' where id = c.id;
    insert into booking.gift_card_ledger(gift_card_id, order_id, delta, balance_after, reason, created_by, note)
    values (c.id, new.id, 0, 0, 'cancel', auth.uid(), 'Ostotilaus ' || new.status || ' ennen maksua');
  end loop;
  return null;
end $$;
create trigger orders_gc_cancel after update of status on booking.orders
  for each row when (new.status in ('cancelled', 'expired') and old.status is distinct from new.status) execute function booking._gc_orders_cancel_trg();

-- kortin mitätöinti hyvityksen yhteydessä (saldo nollataan, ledger cancel_refund)
create or replace function booking._gc_cancel_order_cards(p_order bigint, p_note text) returns int
language plpgsql security definer set search_path to ''
as $$
declare c record; v_n int := 0;
begin
  for c in select id, status, balance from booking.gift_cards where purchase_order_id = p_order and status <> 'cancelled' order by id for update loop
    if c.balance > 0 then perform booking._gc_apply(c.id, -c.balance, 'cancel_refund', p_order, null, p_note); end if;
    update booking.gift_cards set status = 'cancelled' where id = c.id;
    if c.balance = 0 then
      insert into booking.gift_card_ledger(gift_card_id, order_id, delta, balance_after, reason, created_by, note) values (c.id, p_order, 0, 0, 'cancel_refund', auth.uid(), p_note);
    end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- ---------- myynti: tilaus + rivit + kortit (pending_payment tai active) ----------
create or replace function booking._gc_sell(p_items jsonb, p_cust bigint, p_channel text, p_locale text, p_buyer_name text, p_buyer_email text,
    p_status text, p_vat_override text default null, p_valid_months int default null, p_default_rname text default null, p_default_remail text default null,
    p_default_greeting text default null) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare
  it jsonb; pkg booking.gift_card_packages; v_qty int; v_amt numeric; v_n int := 0; v_total numeric := 0; v_max int := (booking._setting('gift_cards.max_cards_per_order', '10'::jsonb) #>> '{}')::int;
  v_order booking.orders; v_oi bigint; v_vat text; v_rate numeric; i int; g booking.gift_cards; v_cards jsonb := '[]'::jsonb;
  v_rn text; v_re text; v_gr text; v_name text; v_months int; v_locale text := coalesce(nullif(p_locale, ''), 'fi');
  v_lines jsonb := '[]'::jsonb;
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
    for i in 1..v_qty loop
      g := booking._gc_create_card(pkg, v_amt, 'pending_payment', v_order.id, v_oi, p_cust,
                                   p_buyer_name, p_buyer_email, v_rn, v_re, v_gr, v_locale, v_months, v_vat, null);
      if v_qty = 1 then update booking.order_items set gift_card_id = g.id where id = v_oi; end if;
      v_cards := v_cards || jsonb_build_object('id', g.id, 'public_token', g.public_token, 'package_code', pkg.code, 'package_name', pkg.name, 'amount', v_amt, 'status', g.status,
                                               'vat_treatment', v_vat, 'recipient_name', v_rn);
    end loop;
    v_lines := v_lines || jsonb_build_object('order_item_id', v_oi, 'package', pkg.code, 'quantity', v_qty, 'unit', v_amt, 'vat_rate', v_rate, 'vat_treatment', v_vat);
  end loop;
  update booking.orders set total_gross = v_total where id = v_order.id;
  return jsonb_build_object('order_id', v_order.id, 'order_no', v_order.order_no, 'public_token', v_order.public_token, 'total', v_total, 'cards', v_cards, 'lines', v_lines);
end $$;

-- ---------- lunastus (yhteinen: admin + julkinen) ----------
create or replace function booking._gc_redeem(p_order_id bigint, p_card_id bigint, p_amount numeric, p_note text, p_public boolean default false) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare o booking.orders; g booking.gift_cards; v_unpaid numeric; v_amt numeric; v_id bigint; rc record; v_excl boolean; v_left numeric; v_card booking.gift_cards;
begin
  if not booking._gc_flag('gift_cards.redeem_enabled') then perform booking._err('redeem_disabled', 'Lahjakorttien lunastus ei ole vielä käytössä'); end if;
  select * into o from booking.orders where id = p_order_id for update;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if o.external_source is not null or o.status not in ('pending', 'confirmed', 'completed') or (p_public and o.status = 'completed') then
    perform booking._err('order_not_editable', 'Tilaukselle ei voi kirjata maksua');
  end if;
  if exists (select 1 from booking.order_items oi where oi.order_id = o.id and oi.kind = 'gift_card') then
    perform booking._err('gift_card_not_allowed', 'Lahjakortilla ei voi ostaa lahjakorttia');
  end if;
  select * into g from booking.gift_cards where id = p_card_id for update;
  if not found then perform booking._err('gift_card_not_found', 'Korttia ei löydy'); end if;
  if g.source = 'johku' and not booking._gc_flag('gift_cards.johku_cards_redeemable') then
    perform booking._err('johku_cards_closed', 'Johku-lähtöisten korttien lunastus ei ole vielä käytössä (kortit lunastetaan toistaiseksi Johkussa)');
  end if;
  if g.status in ('cancelled', 'pending_payment', 'pending_verification') then perform booking._err('gift_card_inactive', 'Kortti ei ole käytettävissä'); end if;
  if g.status = 'expired' or (g.valid_to is not null and g.valid_to < booking._gc_today()) then perform booking._err('gift_card_expired', 'Kortin voimassaolo on päättynyt'); end if;
  if g.status = 'used' or g.balance <= 0 then perform booking._err('gift_card_empty', 'Kortin saldo on käytetty'); end if;
  if not g.balance_verified then perform booking._err('gift_card_inactive', 'Kortin saldoa ei ole vahvistettu'); end if;
  v_unpaid := case when o.status = 'pending' then greatest(o.total_gross - (booking._order_balance(o.id) ->> 'net_paid')::numeric, 0) else (booking._order_balance(o.id) ->> 'unpaid')::numeric end;
  if v_unpaid <= 0 then perform booking._err('nothing_to_pay', 'Tilauksella ei ole maksettavaa'); end if;
  v_amt := coalesce(p_amount, least(g.balance, v_unpaid));
  if v_amt is null or v_amt <= 0 or v_amt <> round(v_amt, 2) then perform booking._err('invalid_amount', 'Virheellinen summa'); end if;
  if v_amt > g.balance + 0.004 then perform booking._err('insufficient_balance', format('Kortin saldo on %s €', g.balance)); end if;
  if v_amt > v_unpaid + 0.004 then perform booking._err('amount_exceeds_unpaid', format('Summa ylittää maksamattoman osuuden (%s €)', v_unpaid)); end if;
  -- rivittömät paikkaajat ja avoimet linkit peruutetaan (kuten admin_record_payment); linkki luodaan tarvittaessa uudelleen jäännökselle
  update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'korvattu lahjakorttimaksulla')
   where order_id = o.id and status = 'pending' and external_source is null
     and ((provider = 'manual' and not exists (select 1 from booking.payment_lines pl where pl.payment_id = payments.id)) or provider <> 'manual');
  insert into booking.payments(order_id, method, provider, status, amount, gift_card_id, note, created_by)
  values (o.id, 'gift_card', 'manual', 'pending', v_amt, g.id, nullif(concat_ws(' | ', 'Lahjakortti …' || right(g.code, 4), p_note), ''), auth.uid()) returning id into v_id;
  perform booking._alloc_payment_lines(v_id);
  update booking.payments set status = 'paid', paid_at = now() where id = v_id;       -- trigger: kuitti vain jos ALV kirjautuu lunastuksessa (ks. _acct_excluded)
  perform booking._gc_apply(g.id, -v_amt, 'redemption', o.id, v_id, p_note);
  select * into v_card from booking.gift_cards where id = g.id;
  if v_card.single_order and v_card.balance > 0 then
    perform booking._gc_apply(g.id, -v_card.balance, 'single_order_forfeit', o.id, v_id, 'Kertakäyttökortti: jäännös ei käytettävissä');
    select * into v_card from booking.gift_cards where id = g.id;
  end if;
  perform booking._sync_placeholder(o.id);
  perform booking._refresh_order_payment(o.id);
  update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = o.id and status = 'pending';
  update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()) where id = o.id and status = 'pending';
  v_excl := booking._acct_excluded(o.id, v_id);
  select receipt_no, id into rc from booking.receipts where payment_id = v_id and kind = 'receipt';
  return jsonb_build_object('ok', true, 'payment_id', v_id, 'amount', v_amt, 'order_id', o.id, 'balance', booking._order_balance(o.id),
    'gift_card', jsonb_build_object('id', v_card.id, 'code_last4', right(v_card.code, 4), 'balance', v_card.balance, 'status', v_card.status, 'valid_to', v_card.valid_to),
    'receipt_id', rc.id, 'receipt_no', rc.receipt_no, 'accounted', not v_excl);
end $$;

-- ---------- rate limit: epäonnistuneet yritykset (ei koodeja lokiin) ----------
create or replace function booking._gc_rl_blocked() returns boolean language plpgsql security definer set search_path to ''
as $$
declare v_ip text := coalesce(booking._client_ip(), 'unknown');
        v_max int := (booking._setting('gift_cards.rl_check_fail_per_10min', '10'::jsonb) #>> '{}')::int;
        v_glob int := (booking._setting('gift_cards.rl_global_fail_per_10min', '200'::jsonb) #>> '{}')::int;
begin
  if (select count(*) from booking.gift_card_check_log where ip_key = v_ip and outcome = 'invalid' and at > now() - interval '10 minutes') >= v_max
     or (select count(*) from booking.gift_card_check_log where outcome = 'invalid' and at > now() - interval '10 minutes') >= v_glob
     or not booking._rate_limit('gcreq:' || v_ip, 60, interval '10 minutes') then
    insert into booking.gift_card_check_log(ip_key, outcome) values (v_ip, 'blocked');
    return true;
  end if;
  return false;
end $$;
create or replace function booking._gc_log(p_outcome text) returns void language sql security definer set search_path to ''
as $$ insert into booking.gift_card_check_log(ip_key, outcome) values (coalesce(booking._client_ip(), 'unknown'), p_outcome) $$;

-- ---------- ALV / kirjanpito: Johku-lähtöinen tai ALV myynnissä kirjattu lahjakorttimaksu ei tuota uutta liikevaihtoa/ALV:tä ----------
create or replace function booking._is_johku_row(p_order_id bigint, p_payment_id bigint default null) returns boolean
 language sql stable security definer set search_path to ''
as $$
  select coalesce((select true from booking.orders o
                    where o.id = coalesce(p_order_id, (select p.order_id from booking.payments p where p.id = p_payment_id))
                      and (o.external_source is not null or o.johku_order_no is not null or o.source_channel = 'johku_import')), false)
      or coalesce((select true from booking.payments p where p.id = p_payment_id and p.external_source is not null), false)
$$;
create or replace function booking._acct_excluded(p_order_id bigint, p_payment_id bigint default null) returns boolean
 language sql stable security definer set search_path to ''
as $$
  select booking._is_johku_row(p_order_id, p_payment_id)
      or coalesce((select true from booking.payments p join booking.gift_cards g on g.id = p.gift_card_id
                    where p.id = p_payment_id and (g.accounting_origin = 'johku' or g.vat_treatment = 'at_sale')), false)
$$;
comment on function booking._acct_excluded(bigint, bigint) is 'true = ei kuitteihin/kirjanpitoraportteihin/outboxiin: Johku-lähtöinen tilaus/maksu TAI lahjakorttimaksu jonka ALV on jo kirjattu (accounting_origin=johku tai vat_treatment=at_sale) (booking_41 + booking_44)';

-- ============================================================
-- 2) julkiset RPC:t (anon + authenticated)
-- ============================================================
create or replace function booking.public_gift_card_packages() returns jsonb
language sql stable security definer set search_path to ''
as $$
  select jsonb_build_object('ok', true, 'sale_enabled', booking._gc_flag('gift_cards.sale_enabled'), 'redeem_enabled', booking._gc_flag('gift_cards.redeem_enabled'),
    'max_cards_per_order', (booking._setting('gift_cards.max_cards_per_order', '10'::jsonb) #>> '{}')::int, 'currency', 'EUR',
    'packages', coalesce((select jsonb_agg(jsonb_build_object('code', p.code, 'name', p.name, 'name_en', p.name_en, 'description', p.description, 'description_en', p.description_en,
        'kind', p.kind, 'is_open', p.is_open, 'price', p.price, 'min_amount', p.min_amount, 'max_amount', p.max_amount, 'persons', p.persons, 'vat_rate', p.vat_rate,
        'valid_months', p.valid_months, 'items', p.items) order by p.sort_order, p.code) from booking.gift_card_packages p where p.active), '[]'::jsonb))
$$;

create or replace function booking.public_check_gift_card(p_code text) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare g booking.gift_cards; v_norm text := booking.gift_code_norm(p_code); v_eff text; v_red boolean; v_why text;
begin
  if booking._gc_rl_blocked() then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_norm !~ '^[A-Z0-9]{12}$' then
    perform booking._gc_log('invalid');
    return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', 'Koodia ei löydy tai se ei ole käytettävissä');
  end if;
  select * into g from booking.gift_cards where code = v_norm;
  if not found or g.status in ('cancelled', 'pending_payment') then
    perform booking._gc_log('invalid');
    return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', 'Koodia ei löydy tai se ei ole käytettävissä');
  end if;
  perform booking._gc_log('ok');
  v_eff := case when g.status = 'active' and g.valid_to is not null and g.valid_to < booking._gc_today() then 'expired' else g.status end;
  v_why := case when not booking._gc_flag('gift_cards.redeem_enabled') then 'redeem_disabled'
                when g.source = 'johku' and not booking._gc_flag('gift_cards.johku_cards_redeemable') then 'johku_cards_closed'
                when v_eff = 'expired' then 'expired' when v_eff = 'used' or g.balance <= 0 then 'empty'
                when v_eff = 'pending_verification' or not g.balance_verified then 'verification_pending' end;
  v_red := v_why is null and v_eff = 'active';
  return jsonb_build_object('ok', true, 'code', booking.gift_code_fmt(g.code), 'type', g.kind, 'package_code', g.package_code,
    'package_name', (select p.name from booking.gift_card_packages p where p.code = g.package_code), 'status', v_eff,
    'initial_amount', g.initial_amount, 'balance', g.balance, 'currency', g.currency, 'valid_to', g.valid_to, 'redeemable', v_red, 'not_redeemable_reason', v_why,
    'balance_verified', g.balance_verified);
end $$;

create or replace function booking.public_apply_gift_card(p_token uuid, p_code text, p_amount numeric default null) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare o booking.orders; g booking.gift_cards; v_norm text := booking.gift_code_norm(p_code); v_res jsonb; v_detail text; v_msg text;
begin
  if booking._gc_rl_blocked() then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then
    perform booking._gc_log('invalid');
    return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Tilausta ei löydy');
  end if;
  select * into g from booking.gift_cards where code = v_norm and v_norm ~ '^[A-Z0-9]{12}$';
  if not found or g.status in ('cancelled', 'pending_payment') then
    perform booking._gc_log('invalid');
    return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', 'Koodia ei löydy tai se ei ole käytettävissä');
  end if;
  begin
    v_res := booking._gc_redeem(o.id, g.id, p_amount, 'Verkkokauppa', true);
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
    perform booking._gc_log('ok');
    return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;
  perform booking._gc_log('ok');
  return jsonb_build_object('ok', true, 'amount', v_res -> 'amount', 'balance', v_res -> 'balance', 'gift_card', (v_res -> 'gift_card') - 'id', 'payment_id', v_res -> 'payment_id');
end $$;

create or replace function booking.public_buy_gift_card(p_items jsonb, p_name text, p_email text, p_phone text, p_marketing_consent boolean default false,
    p_locale text default 'fi', p_recipient_name text default null, p_recipient_email text default null, p_greeting text default null) returns jsonb
language plpgsql security definer set search_path to ''
as $$
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
    v_res := booking._gc_sell(p_items, v_cust, 'web', p_locale, v_name, v_email, v_status, null, null, p_recipient_name, p_recipient_email, p_greeting);
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

-- ostajan tilaussivu: tilauksen kortit (ei koodeja)
create or replace function booking.public_get_order_gift_cards(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path to ''
as $$
declare o booking.orders;
begin
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Tilausta ei löydy'); end if;
  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'payment_status', o.payment_status, 'cards', coalesce((
    select jsonb_agg(jsonb_build_object('token', g.public_token, 'package_code', g.package_code, 'package_name', (select p.name from booking.gift_card_packages p where p.code = g.package_code),
      'amount', g.initial_amount, 'status', g.status, 'valid_to', g.valid_to, 'recipient_name', g.recipient_name, 'ready', g.status in ('active', 'used', 'expired')) order by g.id)
      from booking.gift_cards g where g.purchase_order_id = o.id), '[]'::jsonb));
end $$;

-- kortin sisältö PDF:lle / saajan sivulle (token = gift_cards.public_token; koodi vain maksetulle kortille)
create or replace function booking.public_get_gift_card(p_public_token uuid) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare g booking.gift_cards; v_ip text := coalesce(booking._client_ip(), 'unknown');
begin
  if not booking._rate_limit('gcget:' || v_ip, 60, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  select * into g from booking.gift_cards where public_token = p_public_token and p_public_token is not null;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'Korttia ei löydy'); end if;
  if g.status not in ('active', 'used', 'expired') then return jsonb_build_object('ok', false, 'code', 'not_ready', 'message', 'Kortti aktivoituu kun tilaus on maksettu'); end if;
  return jsonb_build_object('ok', true, 'code', booking.gift_code_fmt(g.code), 'status', case when g.status = 'active' and g.valid_to < booking._gc_today() then 'expired' else g.status end,
    'kind', g.kind, 'package_code', g.package_code,
    'package', (select jsonb_build_object('name', p.name, 'name_en', p.name_en, 'description', p.description, 'description_en', p.description_en, 'persons', p.persons, 'items', p.items)
                  from booking.gift_card_packages p where p.code = g.package_code),
    'initial_amount', g.initial_amount, 'balance', g.balance, 'currency', g.currency, 'valid_from', g.valid_from, 'valid_to', g.valid_to, 'recipient_name', g.recipient_name,
    'greeting', g.greeting, 'buyer_name', g.buyer_name, 'locale', g.locale, 'issued_at', coalesce(g.activated_at, g.created_at), 'source', g.source,
    'seller', booking._seller());
end $$;

-- ============================================================
-- 3) hallinta-RPC:t (authenticated + booking.staff)
-- ============================================================
create or replace function booking._gc_find(p_id bigint, p_code text) returns booking.gift_cards
language plpgsql stable security definer set search_path to ''
as $$
declare g booking.gift_cards;
begin
  if p_id is not null then select * into g from booking.gift_cards where id = p_id;
  elsif p_code is not null then select * into g from booking.gift_cards where code = booking.gift_code_norm(p_code);
  else perform booking._err('invalid_param', 'Anna p_id tai p_code'); end if;
  if g.id is null then perform booking._err('not_found', 'Korttia ei löydy'); end if;
  return g;
end $$;

create or replace function booking.admin_list_gift_card_packages() returns jsonb
language plpgsql stable security definer set search_path to ''
as $$
begin
  if not booking.is_staff() then perform booking._err('forbidden', 'Ei oikeuksia'); end if;
  return jsonb_build_object('packages', coalesce((select jsonb_agg(to_jsonb(p) - 'created_at' order by p.sort_order, p.code) from booking.gift_card_packages p), '[]'::jsonb),
    'settings', jsonb_build_object('redeem_enabled', booking._gc_flag('gift_cards.redeem_enabled'), 'johku_cards_redeemable', booking._gc_flag('gift_cards.johku_cards_redeemable'),
                                   'sale_enabled', booking._gc_flag('gift_cards.sale_enabled')));
end $$;

create or replace function booking.admin_update_gift_card_package(p_code text, p_changes jsonb) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare p booking.gift_card_packages; k text; v jsonb;
begin
  perform booking._require_permission('catalog.edit');
  select * into p from booking.gift_card_packages where code = p_code for update;
  if not found then perform booking._err('not_found', 'Pakettia ei löydy'); end if;
  if p_changes is null or jsonb_typeof(p_changes) <> 'object' or p_changes = '{}'::jsonb then perform booking._err('invalid_param', 'Anna muutokset'); end if;
  for k, v in select * from jsonb_each(p_changes) loop
    if k not in ('name', 'name_en', 'description', 'description_en', 'price', 'min_amount', 'max_amount', 'vat_rate', 'vat_treatment', 'valid_months', 'active', 'sort_order') then
      perform booking._err('invalid_param', 'Kenttää ei voi muuttaa: ' || k);
    end if;
  end loop;
  if p_changes ? 'vat_rate' and not exists (select 1 from booking.vat_rates r where r.rate = (p_changes ->> 'vat_rate')::numeric and r.active) then perform booking._err('invalid_vat', 'ALV-kanta ei ole käytössä'); end if;
  if p_changes ? 'vat_treatment' and (p_changes ->> 'vat_treatment') not in ('at_sale', 'at_redemption') then perform booking._err('invalid_param', 'Virheellinen vat_treatment'); end if;
  begin
    update booking.gift_card_packages set
      name = coalesce(p_changes ->> 'name', name), name_en = case when p_changes ? 'name_en' then p_changes ->> 'name_en' else name_en end,
      description = case when p_changes ? 'description' then p_changes ->> 'description' else description end,
      description_en = case when p_changes ? 'description_en' then p_changes ->> 'description_en' else description_en end,
      price = case when p_changes ? 'price' and not is_open then (p_changes ->> 'price')::numeric else price end,
      min_amount = case when p_changes ? 'min_amount' and is_open then (p_changes ->> 'min_amount')::numeric else min_amount end,
      max_amount = case when p_changes ? 'max_amount' and is_open then (p_changes ->> 'max_amount')::numeric else max_amount end,
      vat_rate = coalesce((p_changes ->> 'vat_rate')::numeric, vat_rate), vat_treatment = coalesce(p_changes ->> 'vat_treatment', vat_treatment),
      valid_months = coalesce((p_changes ->> 'valid_months')::int, valid_months), active = coalesce((p_changes ->> 'active')::boolean, active),
      sort_order = coalesce((p_changes ->> 'sort_order')::int, sort_order)
     where code = p_code returning * into p;
  exception when check_violation or invalid_text_representation or numeric_value_out_of_range then
    perform booking._err('invalid_param', 'Virheellinen arvo');
  end;
  return jsonb_build_object('ok', true, 'package', to_jsonb(p) - 'created_at', 'applies', 'new_sales_only');
end $$;

create or replace function booking.admin_list_gift_cards(p_search text default null, p_status text default null, p_source text default null, p_kind text default null,
    p_package text default null, p_vat_treatment text default null, p_unverified boolean default null, p_expiring_days int default null, p_has_balance boolean default null,
    p_sort text default 'created_desc', p_limit int default 50, p_offset int default 0) returns jsonb
language plpgsql stable security definer set search_path to ''
as $$
declare v_s text := nullif(btrim(coalesce(p_search, '')), ''); v_norm text; v_res jsonb; v_today date := booking._gc_today(); v_lim int := least(greatest(coalesce(p_limit, 50), 1), 200); v_off int := greatest(coalesce(p_offset, 0), 0);
begin
  if not booking.is_staff() then perform booking._err('forbidden', 'Ei oikeuksia'); end if;
  if coalesce(p_sort, 'created_desc') not in ('created_desc', 'created_asc', 'valid_to_asc', 'valid_to_desc', 'balance_desc', 'balance_asc', 'initial_desc', 'initial_asc') then perform booking._err('invalid_sort', 'Tuntematon lajittelu'); end if;
  if p_status is not null and p_status not in ('active', 'used', 'expired', 'cancelled', 'pending_verification', 'pending_payment') then perform booking._err('invalid_param', 'Virheellinen tila'); end if;
  v_norm := booking.gift_code_norm(v_s);
  with f as (
    select g.* from booking.gift_cards g
     where (v_s is null or (char_length(v_norm) >= 4 and g.code like '%' || v_norm || '%')
            or g.buyer_name ilike '%' || v_s || '%' or g.buyer_email ilike '%' || v_s || '%' or g.recipient_name ilike '%' || v_s || '%' or g.recipient_email ilike '%' || v_s || '%'
            or (v_s ~ '^\d{1,10}$' and exists (select 1 from booking.orders o where o.id = g.purchase_order_id and (o.order_no = v_s::bigint or o.johku_order_no = v_s::bigint))))
       and (p_status is null or case when p_status = 'expired' then (g.status = 'expired' or (g.status = 'active' and g.valid_to < v_today)) when p_status = 'active' then g.status = 'active' and (g.valid_to is null or g.valid_to >= v_today) else g.status = p_status end)
       and (p_source is null or g.source = p_source) and (p_kind is null or g.kind = p_kind) and (p_package is null or g.package_code = p_package)
       and (p_vat_treatment is null or g.vat_treatment = p_vat_treatment) and (p_unverified is null or g.balance_verified = not p_unverified)
       and (p_expiring_days is null or (g.status = 'active' and g.valid_to between v_today and v_today + p_expiring_days))
       and (p_has_balance is null or (g.balance > 0) = p_has_balance)
  ), s as (
    select count(*) c, coalesce(sum(balance), 0) sb, coalesce(sum(initial_amount), 0) si,
           coalesce(sum(balance) filter (where status = 'active' and (valid_to is null or valid_to >= v_today)), 0) sr from f
  ), r as (
    select f.*, row_number() over (order by
        (case when p_sort = 'valid_to_asc' then f.valid_to end) asc nulls last, (case when p_sort = 'valid_to_desc' then f.valid_to end) desc nulls last,
        (case when p_sort = 'balance_desc' then f.balance end) desc, (case when p_sort = 'balance_asc' then f.balance end) asc,
        (case when p_sort = 'initial_desc' then f.initial_amount end) desc, (case when p_sort = 'initial_asc' then f.initial_amount end) asc,
        (case when p_sort = 'created_asc' then f.created_at end) asc, f.created_at desc, f.id desc) rn from f
  )
  select jsonb_build_object('total', s.c, 'sum_balance', s.sb, 'sum_initial', s.si, 'sum_balance_redeemable', s.sr,
      'rows', coalesce((select jsonb_agg(booking._gc_card_json(g2, true) order by r.rn) from r join booking.gift_cards g2 on g2.id = r.id where r.rn > v_off and r.rn <= v_off + v_lim), '[]'::jsonb))
    into v_res from s;
  return v_res;
end $$;

create or replace function booking.admin_get_gift_card(p_id bigint default null, p_code text default null) returns jsonb
language plpgsql stable security definer set search_path to ''
as $$
declare g booking.gift_cards; o booking.orders;
begin
  if not booking.is_staff() then perform booking._err('forbidden', 'Ei oikeuksia'); end if;
  g := booking._gc_find(p_id, p_code);
  select * into o from booking.orders where id = g.purchase_order_id;
  return jsonb_build_object('ok', true, 'card', booking._gc_card_json(g, true),
    'ledger', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'at', l.at, 'delta', l.delta, 'balance_after', l.balance_after, 'reason', l.reason, 'order_id', l.order_id,
        'order_no', (select x.order_no from booking.orders x where x.id = l.order_id), 'payment_id', l.payment_id, 'note', l.note, 'old_valid_to', l.old_valid_to, 'new_valid_to', l.new_valid_to,
        'meta', l.meta, 'created_by', l.created_by) order by l.at, l.id) from booking.gift_card_ledger l where l.gift_card_id = g.id), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('payment_id', p.id, 'order_id', p.order_id, 'order_no', x.order_no, 'amount', p.amount, 'refunded_amount', p.refunded_amount,
        'status', p.status, 'paid_at', p.paid_at, 'accounted', not booking._acct_excluded(p.order_id, p.id)) order by p.id)
        from booking.payments p join booking.orders x on x.id = p.order_id where p.gift_card_id = g.id), '[]'::jsonb),
    'expiry_log', coalesce((select jsonb_agg(jsonb_build_object('at', l.at, 'old_valid_to', l.old_valid_to, 'new_valid_to', l.new_valid_to, 'note', l.note, 'by', l.created_by) order by l.at, l.id)
        from booking.gift_card_ledger l where l.gift_card_id = g.id and l.reason = 'expiry_change'), '[]'::jsonb),
    'purchase_order', case when o.id is not null then jsonb_build_object('order_id', o.id, 'order_no', o.order_no, 'johku_order_no', o.johku_order_no, 'status', o.status, 'payment_status', o.payment_status, 'total', o.total_gross) end,
    'ledger_consistent', coalesce((select l.balance_after from booking.gift_card_ledger l where l.gift_card_id = g.id order by l.at desc, l.id desc limit 1), 0) = g.balance
                         or not exists (select 1 from booking.gift_card_ledger l where l.gift_card_id = g.id));
end $$;

create or replace function booking.admin_create_gift_card(p_package text, p_amount numeric default null, p_quantity int default 1, p_buyer jsonb default null,
    p_recipient_name text default null, p_recipient_email text default null, p_greeting text default null, p_payment_method text default null,
    p_vat_treatment text default null, p_valid_months int default null, p_locale text default 'fi', p_note text default null, p_channel text default 'admin') returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare
  v_cust bigint; v_bname text; v_bemail text; v_res jsonb; v_rec jsonb; v_oid bigint; v_ids bigint[]; pkg booking.gift_card_packages; v_i int; g booking.gift_cards;
  v_rn text; v_re text; v_gr text; v_vat text; v_months int; v_cards jsonb := '[]'::jsonb; v_max int := (booking._setting('gift_cards.max_cards_per_order', '10'::jsonb) #>> '{}')::int; v_amt numeric;
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
                              'confirmed', p_vat_treatment, p_valid_months, p_recipient_name, p_recipient_email, p_greeting);
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
  for v_i in 1..p_quantity loop
    g := booking._gc_create_card(pkg, v_amt, 'active', null, null, v_cust, v_bname, v_bemail, v_rn, v_re, v_gr, p_locale, v_months, v_vat, btrim(p_note), 'manual_issue');
    v_cards := v_cards || booking._gc_card_json(g, true);
  end loop;
  return jsonb_build_object('ok', true, 'order_id', null, 'total', 0, 'cards', v_cards, 'paid', false, 'complimentary', true);
end $$;

create or replace function booking.admin_set_gift_card_expiry(p_id bigint, p_valid_to date, p_note text default null) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare g booking.gift_cards; v_status text; v_today date := booking._gc_today();
begin
  perform booking._require_permission('giftcards.manage');
  if p_valid_to is null or p_valid_to > v_today + interval '5 years' or p_valid_to < date '2020-01-01' then perform booking._err('invalid_date', 'Virheellinen päivämäärä'); end if;
  select * into g from booking.gift_cards where id = p_id for update;
  if not found then perform booking._err('not_found', 'Korttia ei löydy'); end if;
  if g.status in ('cancelled', 'pending_payment') then perform booking._err('gift_card_inactive', 'Mitätöidyn / maksamattoman kortin voimassaoloa ei voi muuttaa'); end if;
  if g.valid_to is not distinct from p_valid_to then perform booking._err('invalid_param', 'Voimassaolo on jo tämä'); end if;
  v_status := g.status;
  if g.status in ('active', 'used', 'expired') then
    v_status := case when g.balance = 0 then 'used' when p_valid_to < v_today then 'expired' else 'active' end;
  end if;
  update booking.gift_cards set valid_to = p_valid_to, status = v_status where id = g.id;
  insert into booking.gift_card_ledger(gift_card_id, delta, balance_after, reason, created_by, note, old_valid_to, new_valid_to)
  values (g.id, 0, g.balance, 'expiry_change', auth.uid(), nullif(btrim(coalesce(p_note, '')), ''), g.valid_to, p_valid_to);
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'gift_cards', g.id::text, 'ADMIN_SET_GIFT_CARD_EXPIRY', jsonb_build_object('valid_to', g.valid_to, 'status', g.status), jsonb_build_object('valid_to', p_valid_to, 'status', v_status, 'note', p_note));
  select * into g from booking.gift_cards where id = g.id;
  return jsonb_build_object('ok', true, 'card', booking._gc_card_json(g, true));
end $$;

create or replace function booking.admin_adjust_gift_card(p_id bigint, p_delta numeric, p_reason text, p_mark_verified boolean default false) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare g booking.gift_cards;
begin
  perform booking._require_permission('giftcards.admin');
  if p_delta is null or p_delta = 0 or p_delta <> round(p_delta, 2) or abs(p_delta) > 100000 then perform booking._err('invalid_amount', 'Virheellinen summa'); end if;
  if p_reason is null or char_length(btrim(p_reason)) < 3 or char_length(p_reason) > 500 then perform booking._err('invalid_param', 'Anna syy (3–500 merkkiä)'); end if;
  select * into g from booking.gift_cards where id = p_id for update;
  if not found then perform booking._err('not_found', 'Korttia ei löydy'); end if;
  if g.status in ('cancelled', 'pending_payment') then perform booking._err('gift_card_inactive', 'Mitätöidyn / maksamattoman kortin saldoa ei voi muuttaa'); end if;
  if g.balance + p_delta < 0 then perform booking._err('balance_below_zero', format('Saldo (%s €) ei voi laskea alle nollan', g.balance)); end if;
  perform booking._gc_apply(g.id, p_delta, 'adjust', null, null, btrim(p_reason));
  if p_mark_verified and not g.balance_verified then
    update booking.gift_cards set balance_verified = true, balance_verified_at = now(), balance_source = 'admin_adjust',
           status = case when status = 'pending_verification' then (case when balance = 0 then 'used' when valid_to is not null and valid_to < booking._gc_today() then 'expired' else 'active' end) else status end
     where id = g.id;
  end if;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'gift_cards', g.id::text, 'ADMIN_ADJUST_GIFT_CARD', jsonb_build_object('balance', g.balance), jsonb_build_object('delta', p_delta, 'reason', p_reason));
  select * into g from booking.gift_cards where id = g.id;
  return jsonb_build_object('ok', true, 'card', booking._gc_card_json(g, true));
end $$;

create or replace function booking.admin_deactivate_gift_card(p_id bigint, p_reason text) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare g booking.gift_cards;
begin
  perform booking._require_permission('giftcards.admin');
  if p_reason is null or char_length(btrim(p_reason)) < 3 or char_length(p_reason) > 500 then perform booking._err('invalid_param', 'Anna syy (3–500 merkkiä)'); end if;
  select * into g from booking.gift_cards where id = p_id for update;
  if not found then perform booking._err('not_found', 'Korttia ei löydy'); end if;
  if g.status = 'cancelled' then perform booking._err('invalid_param', 'Kortti on jo mitätöity'); end if;
  update booking.gift_cards set status = 'cancelled' where id = g.id;
  insert into booking.gift_card_ledger(gift_card_id, delta, balance_after, reason, created_by, note) values (g.id, 0, g.balance, 'cancel', auth.uid(), btrim(p_reason));
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'gift_cards', g.id::text, 'ADMIN_DEACTIVATE_GIFT_CARD', jsonb_build_object('status', g.status), jsonb_build_object('status', 'cancelled', 'reason', p_reason));
  select * into g from booking.gift_cards where id = g.id;
  return jsonb_build_object('ok', true, 'card', booking._gc_card_json(g, true));
end $$;

create or replace function booking.admin_reactivate_gift_card(p_id bigint, p_reason text) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare g booking.gift_cards; v_status text;
begin
  perform booking._require_permission('giftcards.admin');
  if p_reason is null or char_length(btrim(p_reason)) < 3 or char_length(p_reason) > 500 then perform booking._err('invalid_param', 'Anna syy (3–500 merkkiä)'); end if;
  select * into g from booking.gift_cards where id = p_id for update;
  if not found then perform booking._err('not_found', 'Korttia ei löydy'); end if;
  if g.status <> 'cancelled' then perform booking._err('invalid_param', 'Vain mitätöidyn kortin voi aktivoida uudelleen'); end if;
  if g.source = 'native' and not exists (select 1 from booking.gift_card_ledger l where l.gift_card_id = g.id and l.reason in ('purchase', 'manual_issue')) then
    perform booking._err('gift_card_not_paid', 'Kortti ei ole koskaan aktivoitunut (ostoa ei ole maksettu)');
  end if;
  v_status := case when g.balance = 0 then 'used' when g.valid_to is not null and g.valid_to < booking._gc_today() then 'expired' else 'active' end;
  update booking.gift_cards set status = v_status where id = g.id;
  insert into booking.gift_card_ledger(gift_card_id, delta, balance_after, reason, created_by, note) values (g.id, 0, g.balance, 'reactivate', auth.uid(), btrim(p_reason));
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'gift_cards', g.id::text, 'ADMIN_REACTIVATE_GIFT_CARD', jsonb_build_object('status', 'cancelled'), jsonb_build_object('status', v_status, 'reason', p_reason));
  select * into g from booking.gift_cards where id = g.id;
  return jsonb_build_object('ok', true, 'card', booking._gc_card_json(g, true));
end $$;

create or replace function booking.admin_redeem_gift_card(p_order_id bigint, p_code text, p_amount numeric default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare g booking.gift_cards; v_norm text := booking.gift_code_norm(p_code);
begin
  perform booking._require_permission('payments.manage');
  if v_norm !~ '^[A-Z0-9]{12}$' then perform booking._err('gift_card_not_found', 'Koodia ei löydy (12 merkkiä, viivat valinnaisia)'); end if;
  select * into g from booking.gift_cards where code = v_norm;
  if not found then perform booking._err('gift_card_not_found', 'Koodia ei löydy'); end if;
  return booking._gc_redeem(p_order_id, g.id, p_amount, nullif(btrim(coalesce(p_note, '')), ''), false);
end $$;

-- ---------- ylläpito: vanheneminen, vanhentuneet verkkomaksua odottavat ostot, lokin siivous ----------
create or replace function booking.gift_cards_housekeeping() returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare v_exp int; v_stale int; v_log int; c record;
begin
  update booking.gift_cards set status = 'expired' where status = 'active' and valid_to is not null and valid_to < booking._gc_today() and balance > 0;
  get diagnostics v_exp = row_count;
  v_stale := 0;
  for c in select o.id from booking.orders o where o.status = 'pending' and o.payment_status in ('unpaid', 'pending') and o.created_at < now() - interval '2 hours'
              and exists (select 1 from booking.gift_cards g where g.purchase_order_id = o.id and g.status = 'pending_payment')
              and not exists (select 1 from booking.reservations r where r.order_id = o.id) loop
    update booking.orders set status = 'expired' where id = c.id;     -- trigger peruu kortit
    update booking.payments set status = 'cancelled' where order_id = c.id and status = 'pending';
    v_stale := v_stale + 1;
  end loop;
  delete from booking.gift_card_check_log where at < now() - interval '2 days';
  get diagnostics v_log = row_count;
  return jsonb_build_object('expired_cards', v_exp, 'expired_orders', v_stale, 'log_rows_deleted', v_log);
end $$;

-- ============================================================
-- 6) muutetut olemassa olevat funktiot (booking_44)
-- ============================================================
CREATE OR REPLACE FUNCTION booking.admin_refund(p_payment_id bigint, p_amount numeric, p_reason text, p_lines jsonb DEFAULT NULL::jsonb, p_manual_done boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pay booking.payments; o booking.orders; v_cap numeric; v_mode text; v_online boolean; v_id bigint; l jsonb; v_pl booking.payment_lines; v_sum numeric := 0; v_full boolean;
        r record; v_total_cap numeric; v_alloc numeric; v_left numeric; v_alloc_json jsonb := '[]'::jsonb; v_status text; rc record; v_n int; v_i int := 0;
        v_gc_sale boolean := false;
begin
  perform booking._require_permission('payments.refund');
  select * into pay from booking.payments where id = p_payment_id for update;
  if not found then perform booking._err('not_found', 'Maksua ei löydy'); end if;
  select * into o from booking.orders where id = pay.order_id for update;
  if o.external_source is not null or pay.external_source is not null then perform booking._err('order_not_editable', 'Johku-historian maksuja ei voi hyvittää tässä'); end if;
  if pay.status = 'refunded' then perform booking._err('already_refunded', 'Maksu on jo hyvitetty kokonaan'); end if;
  if pay.status not in ('paid','partially_refunded') then perform booking._err('refund_not_allowed', 'Vain maksettu maksu voidaan hyvittää'); end if;
  if p_reason is null or char_length(btrim(p_reason)) < 3 or char_length(p_reason) > 500 then perform booking._err('invalid_param', 'Anna hyvityksen syy (3–500 merkkiä)'); end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then perform booking._err('invalid_amount', 'Virheellinen summa'); end if;
  v_cap := pay.amount - pay.refunded_amount - coalesce((select sum(f.amount) from booking.refunds f where f.payment_id = pay.id and f.status in ('requested','processing')), 0);
  if p_amount > v_cap + 0.004 then perform booking._err('amount_exceeds_refundable', format('Hyvitettävissä enintään %s €', v_cap)); end if;
  v_online := pay.provider <> 'manual';
  select mode into v_mode from booking.integration_config where key = replace(pay.provider, '_', '');
  if v_online and coalesce(v_mode, 'off') = 'off' then
    if not p_manual_done then perform booking._err('refund_not_allowed', 'Verkkomaksun hyvitys ei ole vielä käytössä – hyvitä Visman portaalissa ja kirjaa käsin (vain admin)'); end if;
    if booking.current_staff_role() is distinct from 'admin' then perform booking._err('forbidden', 'Käsinkirjaus verkkomaksulle vaatii admin-roolin'); end if;
  end if;
  v_full := abs(p_amount - v_cap) < 0.005 and pay.refunded_amount = 0;
  -- lahjakortit (booking_44): lahjakorttien ostomaksu hyvitetään vain kokonaan ja vain käyttämättömille korteille (kortit mitätöidään)
  if exists (select 1 from booking.payment_lines pl join booking.order_items oi on oi.id = pl.order_item_id where pl.payment_id = pay.id and oi.kind = 'gift_card')
     and exists (select 1 from booking.gift_cards gc where gc.purchase_order_id = pay.order_id and gc.status <> 'cancelled') then
    if not v_full then perform booking._err('gift_card_refund_full_only', 'Lahjakorttien ostomaksu hyvitetään kokonaan (kortit mitätöidään)'); end if;
    if exists (select 1 from booking.gift_cards gc where gc.purchase_order_id = pay.order_id and gc.status not in ('cancelled', 'pending_payment') and gc.balance < gc.initial_amount) then
      perform booking._err('gift_card_in_use', 'Kortilla on jo käyttöä: ostoa ei voi hyvittää kokonaan (mitätöi kortti hallinnassa ja hyvitä tarvittaessa käsin)');
    end if;
    v_gc_sale := true;
  end if;

  -- rivijako
  if p_lines is not null then
    if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then perform booking._err('invalid_items', 'p_lines väärässä muodossa'); end if;
    for l in select * from jsonb_array_elements(p_lines) loop
      if coalesce(l ->> 'payment_line_id', '') !~ '^\d{1,18}$' or coalesce(l ->> 'amount', '') !~ '^\d{1,6}(\.\d{1,2})?$' then perform booking._err('invalid_items', 'Rivi virheellinen'); end if;
      select * into v_pl from booking.payment_lines where id = (l ->> 'payment_line_id')::bigint and payment_id = pay.id;
      if not found then perform booking._err('item_not_found', 'Maksun riviä ei löydy'); end if;
      if (l ->> 'amount')::numeric <= 0 or (l ->> 'amount')::numeric > v_pl.amount_gross - v_pl.refunded_gross + 0.004 then perform booking._err('amount_exceeds_refundable', 'Rivin hyvitys ylittää hyvitettävissä olevan'); end if;
      v_alloc_json := v_alloc_json || jsonb_build_object('payment_line_id', v_pl.id, 'amount', (l ->> 'amount')::numeric);
      v_sum := v_sum + (l ->> 'amount')::numeric;
    end loop;
    if abs(v_sum - p_amount) > 0.004 then perform booking._err('invalid_items', 'Rivien summa ei vastaa hyvityksen summaa'); end if;
  elsif v_full then
    select coalesce(jsonb_agg(jsonb_build_object('payment_line_id', id, 'amount', amount_gross - refunded_gross) order by id), '[]'::jsonb) into v_alloc_json
      from booking.payment_lines where payment_id = pay.id and amount_gross - refunded_gross <> 0;
  else   -- suhteessa positiivisten rivien hyvitettävään osuuteen
    select coalesce(sum(amount_gross - refunded_gross), 0) into v_total_cap from booking.payment_lines where payment_id = pay.id and amount_gross - refunded_gross > 0;
    if v_total_cap < p_amount - 0.004 then perform booking._err('invalid_items', 'Anna rivijako (p_lines)'); end if;
    v_left := p_amount; select count(*) into v_n from booking.payment_lines where payment_id = pay.id and amount_gross - refunded_gross > 0;
    for r in select id, amount_gross - refunded_gross as cap from booking.payment_lines where payment_id = pay.id and amount_gross - refunded_gross > 0 order by id loop
      v_i := v_i + 1;
      v_alloc := case when v_i = v_n then v_left else least(round(p_amount * r.cap / v_total_cap, 2), r.cap) end;
      v_alloc := least(v_alloc, r.cap, v_left);
      if v_alloc > 0 then v_alloc_json := v_alloc_json || jsonb_build_object('payment_line_id', r.id, 'amount', v_alloc); v_left := v_left - v_alloc; end if;
    end loop;
    if v_left > 0.004 then perform booking._err('invalid_items', 'Anna rivijako (p_lines)'); end if;
  end if;

  v_status := case when v_online and coalesce(v_mode, 'off') <> 'off' then 'requested' else 'done' end;
  insert into booking.refunds(payment_id, order_id, amount, reason, status, provider, provider_status, lines, created_by, done_at)
  values (pay.id, pay.order_id, p_amount, btrim(p_reason), v_status, case when v_online and v_status = 'requested' then pay.provider else 'manual' end,
          case when v_online and v_status = 'done' then 'manual_done' end, v_alloc_json, auth.uid(), case when v_status = 'done' then now() end) returning id into v_id;
  if v_status = 'done' then
    update booking.payment_lines pl set refunded_gross = pl.refunded_gross + (x ->> 'amount')::numeric
      from jsonb_array_elements(v_alloc_json) x where pl.id = (x ->> 'payment_line_id')::bigint;
    update booking.payments set refunded_amount = refunded_amount + p_amount,
           status = case when refunded_amount + p_amount >= amount then 'refunded' else 'partially_refunded' end where id = pay.id;
    perform booking._sync_placeholder(pay.order_id);
    perform booking._refresh_order_payment(pay.order_id);
    perform booking._on_refund_done(v_id);
    -- lahjakortit (booking_44): ostomaksun hyvitys mitätöi kortit; lahjakorttimaksun hyvitys palautetaan kortille (ei rahana)
    if v_gc_sale then perform booking._gc_cancel_order_cards(pay.order_id, 'Ostomaksu hyvitetty (hyvitys #' || v_id || ')'); end if;
    if pay.gift_card_id is not null then perform booking._gc_apply(pay.gift_card_id, p_amount, 'refund', pay.order_id, pay.id, 'Hyvitys kortille: ' || btrim(p_reason)); end if;
  end if;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'refunds', v_id::text, 'ADMIN_REFUND', null, jsonb_build_object('payment_id', pay.id, 'amount', p_amount, 'reason', p_reason, 'status', v_status));
  select id, receipt_no into rc from booking.receipts where refund_id = v_id;
  return jsonb_build_object('ok', true, 'refund_id', v_id, 'status', v_status, 'balance', booking._order_balance(pay.order_id), 'receipt_id', rc.id, 'receipt_no', rc.receipt_no);
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_list_payments(p_search text DEFAULT NULL::text, p_method text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_sort text DEFAULT 'paid_desc'::text, p_include_placeholders boolean DEFAULT false, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_s text := nullif(btrim(coalesce(p_search, '')), ''); v_num bigint; v_like text; v_total int; v_rows jsonb; v_sp numeric; v_sr numeric; v_spx numeric; v_srx numeric; v_jn int; v_lim int := coalesce(p_limit, 50); v_off int := greatest(coalesce(p_offset, 0), 0);
begin
  perform booking._require_staff();
  if p_sort is null or p_sort not in ('paid_desc','paid_asc','amount_desc','amount_asc','order_no_desc','order_no_asc') then perform booking._err('invalid_sort', 'Tuntematon lajittelu'); end if;
  if v_lim < 1 or v_lim > 200 then perform booking._err('invalid_param', 'p_limit 1–200'); end if;
  if v_s ~ '^\d{1,12}$' then v_num := v_s::bigint; end if;
  if v_s is not null then v_like := '%' || replace(replace(replace(v_s, '\', '\\'), '%', '\%'), '_', '\_') || '%'; end if;
  with base as (
    select p.id, p.order_id, o.order_no, p.method, pm.label as mlabel, p.provider, p.status, p.amount, p.refunded_amount, p.rounding, p.paid_at, p.created_at,
           c.name as cname, (select count(*) from booking.payment_lines pl where pl.payment_id = p.id) as lc,
           rc.receipt_no, rc.public_token as rtoken, coalesce(p.paid_at, p.created_at) as ts, booking._is_johku_row(p.order_id, p.id) as jk
      from booking.payments p join booking.orders o on o.id = p.order_id
      left join booking.customers c on c.id = o.customer_id left join booking.payment_methods pm on pm.code = p.method
      left join lateral (select x.receipt_no, x.public_token from booking.receipts x where x.payment_id = p.id and x.kind = 'receipt' limit 1) rc on true
     where (p_method is null or p.method = p_method) and (p_status is null or p.status = p_status)
       and (p_include_placeholders or not (p.provider = 'manual' and p.status = 'pending' and p.external_source is null
                                           and not exists (select 1 from booking.payment_lines pl where pl.payment_id = p.id)))
       and (p_from is null or (coalesce(p.paid_at, p.created_at) at time zone 'Europe/Helsinki')::date >= p_from)
       and (p_to is null or (coalesce(p.paid_at, p.created_at) at time zone 'Europe/Helsinki')::date <= p_to)
       and (v_s is null or (v_num is not null and (o.order_no = v_num or p.id = v_num)) or rc.receipt_no ilike v_like or (v_num is null and (c.name ilike v_like or c.email ilike v_like)))
  ), page as (
    select b.*, row_number() over (order by
       case when p_sort = 'paid_asc' then b.ts end asc, case when p_sort = 'paid_desc' then b.ts end desc,
       case when p_sort = 'amount_asc' then b.amount end asc, case when p_sort = 'amount_desc' then b.amount end desc,
       case when p_sort = 'order_no_asc' then b.order_no end asc, case when p_sort = 'order_no_desc' then b.order_no end desc, b.id desc) rn from base b)
  select (select count(*) from base),
         (select coalesce(sum(amount) filter (where status in ('paid','partially_refunded','refunded')), 0) from base),
         (select coalesce(sum(refunded_amount), 0) from base),
         (select coalesce(sum(amount) filter (where status in ('paid','partially_refunded','refunded') and not jk), 0) from base),
         (select coalesce(sum(refunded_amount) filter (where not jk), 0) from base),
         (select count(*) from base where jk),
         coalesce(jsonb_agg(jsonb_build_object('payment_id', p.id, 'order_id', p.order_id, 'order_no', p.order_no, 'method', p.method, 'method_label', p.mlabel, 'provider', p.provider,
           'status', p.status, 'amount', p.amount, 'refunded_amount', p.refunded_amount, 'rounding', p.rounding, 'paid_at', p.paid_at, 'created_at', p.created_at,
           'customer_name', p.cname, 'line_count', p.lc, 'receipt_no', p.receipt_no, 'receipt_token', p.rtoken,
           'source', case when p.jk then 'johku' else 'native' end, 'is_johku', p.jk) order by p.rn), '[]'::jsonb)
    into v_total, v_sp, v_sr, v_spx, v_srx, v_jn, v_rows from page p where p.rn > v_off and p.rn <= v_off + v_lim;
  return jsonb_build_object('total', v_total, 'sum_paid', v_sp, 'sum_refunded', v_sr, 'sum_paid_ex_johku', v_spx, 'sum_refunded_ex_johku', v_srx, 'johku_rows', v_jn, 'rows', v_rows);
end $function$;

CREATE OR REPLACE FUNCTION booking._report_json(p_from date, p_to date, p_receipts boolean, p_days boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_res jsonb;
begin
  with jx as (
    select o.payment_status st, coalesce(o.external_meta -> 'johku' ->> 'payment_method', 'unknown') m,
           case when (o.external_meta -> 'johku' ->> 'amount') ~ '^-?\d+(\.\d+)?$' then (o.external_meta -> 'johku' ->> 'amount')::numeric else o.total_gross end amt
      from booking.orders o
     where (o.external_source = 'johku' or o.johku_order_no is not null or o.source_channel = 'johku_import')
       and o.payment_status in ('paid','partially_refunded','refunded')
       and left(o.external_meta -> 'johku' ->> 'paid_at', 10) between to_char(p_from - 1, 'YYYY-MM-DD') and to_char(p_to + 1, 'YYYY-MM-DD')
       and (booking._try_ts(o.external_meta -> 'johku' ->> 'paid_at') at time zone 'Europe/Helsinki')::date between p_from and p_to
  ), rc as (
    select r.id, r.receipt_no, r.kind, r.issued_at, (r.issued_at at time zone 'Europe/Helsinki')::date as d, r.snapshot s, o.order_no,
           r.snapshot -> 'payment' ->> 'method' as method, coalesce(r.snapshot -> 'payment' ->> 'method_label', r.snapshot -> 'payment' ->> 'method') as mlabel,
           r.total_gross as gross, (r.snapshot ->> 'total_net')::numeric as net, (r.snapshot ->> 'total_vat')::numeric as vat, coalesce((r.snapshot ->> 'rounding')::numeric, 0) as rnd
      from booking.receipts r join booking.orders o on o.id = r.order_id
     where (r.issued_at at time zone 'Europe/Helsinki')::date between p_from and p_to
       and not booking._acct_excluded(r.order_id, r.payment_id)   -- Johku ei kirjanpitoraporttiin
  ), tot as (
    select jsonb_build_object('receipts', count(*) filter (where kind = 'receipt'), 'refund_receipts', count(*) filter (where kind = 'refund_receipt'),
             'gross', coalesce(sum(gross) filter (where kind = 'receipt'), 0), 'net', coalesce(sum(net) filter (where kind = 'receipt'), 0), 'vat', coalesce(sum(vat) filter (where kind = 'receipt'), 0),
             'refunds_gross', coalesce(sum(gross) filter (where kind = 'refund_receipt'), 0), 'net_after_refunds', coalesce(sum(gross), 0),
             'vat_after_refunds', coalesce(sum(vat), 0), 'net_ex_vat_after_refunds', coalesce(sum(net), 0), 'rounding', coalesce(sum(rnd), 0)) j from rc
  ), bm as (
    select coalesce(jsonb_agg(jsonb_build_object('method', method, 'label', label, 'payments', pc, 'gross', g, 'refunds', rf, 'rounding', rn) order by method), '[]'::jsonb) j from (
      select method, max(mlabel) label, count(*) filter (where kind = 'receipt') pc, coalesce(sum(gross) filter (where kind = 'receipt'), 0) g,
             coalesce(sum(gross) filter (where kind = 'refund_receipt'), 0) rf, coalesce(sum(rnd), 0) rn from rc group by method) x
  ), bv as (
    select coalesce(jsonb_agg(jsonb_build_object('rate', rate, 'net', n, 'vat', v, 'gross', g) order by rate), '[]'::jsonb) j from (
      select (e ->> 'rate')::numeric rate, sum((e ->> 'net')::numeric) n, sum((e ->> 'vat')::numeric) v, sum((e ->> 'gross')::numeric) g from rc, jsonb_array_elements(rc.s -> 'vat') e group by 1) x
  ), bmv as (
    select coalesce(jsonb_agg(jsonb_build_object('method', method, 'rate', rate, 'net', n, 'vat', v, 'gross', g) order by method, rate), '[]'::jsonb) j from (
      select method, (e ->> 'rate')::numeric rate, sum((e ->> 'net')::numeric) n, sum((e ->> 'vat')::numeric) v, sum((e ->> 'gross')::numeric) g from rc, jsonb_array_elements(rc.s -> 'vat') e group by 1, 2) x
  ), bc as (
    select coalesce(jsonb_agg(jsonb_build_object('category', cat, 'label', booking._category_label(cat), 'rate', rate, 'quantity', q, 'gross', g, 'net', n, 'vat', g - n) order by cat, rate), '[]'::jsonb) j from (
      select l ->> 'category' cat, (l ->> 'vat_rate')::numeric rate, sum((l ->> 'quantity')::int * case when rc.kind = 'refund_receipt' then -1 else 1 end) q,
             sum((l ->> 'line_gross')::numeric) g, sum((l ->> 'line_net')::numeric) n from rc, jsonb_array_elements(rc.s -> 'lines') l group by 1, 2) x
  ), rl as (
    select case when p_receipts then coalesce(jsonb_agg(jsonb_build_object('receipt_no', receipt_no, 'kind', kind, 'issued_at', issued_at, 'order_no', order_no, 'method', method, 'gross', gross, 'net', net, 'vat', vat) order by issued_at, id), '[]'::jsonb) end j from rc
  ), bd as (
    select case when p_days then coalesce(jsonb_agg(jsonb_build_object('date', d, 'receipts', c, 'gross', g, 'vat', v, 'refunds', rf) order by d), '[]'::jsonb) end j from (
      select d, count(*) filter (where kind = 'receipt') c, coalesce(sum(gross) filter (where kind = 'receipt'), 0) g, coalesce(sum(vat), 0) v, coalesce(sum(gross) filter (where kind = 'refund_receipt'), 0) rf from rc group by d) x
  ), js as (
    -- Tilastolohko (EI kirjanpitoon): Johku-tilaukset, joiden Johku-maksupäivä (external_meta.johku.paid_at, Helsingin päivä) osuu jaksolle. Ei kosketa totals/by_*-avaimia.
    select jsonb_build_object('label', 'Johku (ei kirjanpitoon)', 'accounting', false, 'basis', 'johku_paid_at',
             'orders', coalesce(count(*) filter (where st in ('paid','partially_refunded')), 0),
             'gross', coalesce(sum(amt) filter (where st in ('paid','partially_refunded')), 0),
             'refunded_orders', coalesce(count(*) filter (where st = 'refunded'), 0),
             'refunded_gross', coalesce(sum(amt) filter (where st = 'refunded'), 0),
             'by_method', coalesce((select jsonb_agg(jsonb_build_object('method', m, 'orders', c, 'gross', g) order by m)
                                      from (select m2.m, count(*) c, sum(m2.amt) g from jx m2 where m2.st in ('paid','partially_refunded') group by m2.m) mm), '[]'::jsonb)) j
      from jx
  ), gc as (
    -- Lahjakorttitilasto (booking_44): ei kosketa totals/by_*-avaimia. redeemed_* = lahjakorttimaksut jaksolla (maksupäivä Helsinki); sold = jaksolla aktivoituneet omat kortit;
    -- outstanding = aktiivisten korttien saldo raportin luontihetkellä (vastuu): at_redemption = ALV kirjautuu lunastuksessa, at_sale/johku = ALV jo kirjattu.
    select jsonb_build_object('label', 'Lahjakortit', 'accounting', 'redeemed_accounted sisältyy kuitteihin/totals-lukuihin; muut eivät (ALV kirjattu myynnissä tai Johkussa)',
      'redeemed_accounted', (select jsonb_build_object('payments', count(*), 'gross', coalesce(sum(p.amount), 0), 'refunded', coalesce(sum(p.refunded_amount), 0))
          from booking.payments p join booking.gift_cards g on g.id = p.gift_card_id where p.status in ('paid', 'partially_refunded', 'refunded') and g.accounting_origin = 'native' and g.vat_treatment = 'at_redemption'
           and (p.paid_at at time zone 'Europe/Helsinki')::date between p_from and p_to),
      'redeemed_prepaid_at_sale', (select jsonb_build_object('payments', count(*), 'gross', coalesce(sum(p.amount), 0), 'refunded', coalesce(sum(p.refunded_amount), 0))
          from booking.payments p join booking.gift_cards g on g.id = p.gift_card_id where p.status in ('paid', 'partially_refunded', 'refunded') and g.accounting_origin = 'native' and g.vat_treatment = 'at_sale'
           and (p.paid_at at time zone 'Europe/Helsinki')::date between p_from and p_to),
      'redeemed_johku', (select jsonb_build_object('payments', count(*), 'gross', coalesce(sum(p.amount), 0), 'refunded', coalesce(sum(p.refunded_amount), 0))
          from booking.payments p join booking.gift_cards g on g.id = p.gift_card_id where p.status in ('paid', 'partially_refunded', 'refunded') and g.accounting_origin = 'johku'
           and (p.paid_at at time zone 'Europe/Helsinki')::date between p_from and p_to),
      'sold', (select jsonb_build_object('cards', count(*), 'gross', coalesce(sum(g.initial_amount), 0),
                 'at_sale_gross', coalesce(sum(g.initial_amount) filter (where g.vat_treatment = 'at_sale'), 0), 'at_redemption_gross', coalesce(sum(g.initial_amount) filter (where g.vat_treatment = 'at_redemption'), 0))
          from booking.gift_cards g where g.source = 'native' and g.purchase_order_id is not null and g.activated_at is not null and (g.activated_at at time zone 'Europe/Helsinki')::date between p_from and p_to),
      'outstanding', (select coalesce(jsonb_agg(jsonb_build_object('accounting_origin', k.ao, 'vat_treatment', k.vt, 'cards', k.c, 'balance', k.b) order by k.ao, k.vt), '[]'::jsonb)
          from (select g.accounting_origin ao, g.vat_treatment vt, count(*) c, coalesce(sum(g.balance), 0) b from booking.gift_cards g
                 where g.status = 'active' and (g.valid_to is null or g.valid_to >= (now() at time zone 'Europe/Helsinki')::date) group by 1, 2) k)) j
  ), op as (
    select jsonb_build_object('orders', count(*), 'unpaid', coalesce(sum(u), 0)) j from (
      select o.id, greatest(o.total_gross - coalesce((select sum(p.amount - p.refunded_amount) from booking.payments p where p.order_id = o.id and p.status in ('paid','partially_refunded','refunded')), 0), 0) u
        from booking.orders o where not booking._acct_excluded(o.id, null) and o.status = 'confirmed'
         and (select min(r.starts_at at time zone 'Europe/Helsinki')::date from booking.reservations r where r.order_id = o.id and r.status = 'confirmed') between p_from and p_to) y where u > 0
  ), ur as (
    select jsonb_build_object('payments', count(*), 'amount', coalesce(sum(p.amount), 0)) j from booking.payments p
     where not booking._acct_excluded(p.order_id, p.id) and p.status in ('paid','partially_refunded','refunded') and (p.paid_at at time zone 'Europe/Helsinki')::date between p_from and p_to
       and not exists (select 1 from booking.receipts r where r.payment_id = p.id and r.kind = 'receipt')
  )
  select jsonb_build_object('period', jsonb_build_object('from', p_from, 'to', p_to, 'tz', 'Europe/Helsinki'), 'generated_at', now(), 'basis', 'cash (kuitin antamispäivä)',
         'totals', tot.j, 'by_method', bm.j, 'by_vat', bv.j, 'by_method_vat', bmv.j, 'by_category', bc.j, 'open', op.j, 'unreceipted', ur.j, 'statistics', jsonb_build_object('johku', js.j, 'gift_cards', gc.j))
         || case when p_receipts then jsonb_build_object('receipts', rl.j) else '{}'::jsonb end
         || case when p_days then jsonb_build_object('by_day', bd.j) else '{}'::jsonb end
    into v_res from tot, bm, bv, bmv, bc, rl, bd, op, ur, js, gc;
  return v_res;
end $function$;

-- ============================================================
-- 4) Johku-tuonti (vain service_role): booking.svc_gift_cards_johku_upsert(p_rows jsonb)
--    Rivi: {external_id, code, kind, product_id, initial_amount, balance, valid_to, created_at, purchase_order_ext, purchase_item_ext, sale_vat_rate,
--           balance_verified, balance_source, single_order, meta{}, ledger:[{at, delta, reason, note, meta}]}
--    Uusi kortti: source/issuer='johku', accounting_origin='johku', vat_treatment='at_sale' (ALV kirjattu Johkussa -> lunastus ei tuota uutta ALV:tä).
--    Olemassa oleva kortti (external_id): synkataan saldo (ledger johku_sync) ja voimassaolo (ledger expiry_change); koodeja ei koskaan palauteta/lokiteta.
-- ============================================================
create or replace function booking.svc_gift_cards_johku_upsert(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare
  r jsonb; l jsonb; g booking.gift_cards; o booking.orders; v_item bigint; v_cust booking.customers; v_status text; v_bal numeric; v_valid date; v_today date := booking._gc_today();
  v_new int := 0; v_upd int := 0; v_same int := 0; v_olink int := 0; v_ilink int := 0; v_blink int := 0; v_unver int := 0; v_run numeric; v_n int;
  v_st jsonb := '{}'::jsonb; v_delta numeric;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then perform booking._err('invalid_param', 'p_rows: taulukko'); end if;
  perform set_config('booking.skip_audit', 'on', true);
  for r in select * from jsonb_array_elements(p_rows) loop
    v_bal := (r ->> 'balance')::numeric; v_valid := (r ->> 'valid_to')::date;
    select * into g from booking.gift_cards where external_source = 'johku' and external_id = r ->> 'external_id';
    if found then
      -- synkka: saldo ja voimassaolo
      if g.valid_to is distinct from v_valid and v_valid is not null then
        update booking.gift_cards set valid_to = v_valid,
               status = case when status in ('active', 'used', 'expired') then (case when balance = 0 then 'used' when v_valid < v_today then 'expired' else 'active' end) else status end
         where id = g.id;
        insert into booking.gift_card_ledger(gift_card_id, delta, balance_after, reason, note, old_valid_to, new_valid_to) values (g.id, 0, g.balance, 'expiry_change', 'Johku-voimassaolon synkka', g.valid_to, v_valid);
        v_upd := v_upd + 1;
        select * into g from booking.gift_cards where id = g.id;
      end if;
      if g.balance is distinct from v_bal then
        v_delta := v_bal - g.balance;
        update booking.gift_cards set balance = v_bal, balance_verified = coalesce((r ->> 'balance_verified')::boolean, balance_verified), balance_verified_at = now(), balance_source = coalesce(r ->> 'balance_source', balance_source),
               status = case when status in ('active', 'used', 'expired', 'pending_verification') then (case when v_bal = 0 then 'used' when valid_to < v_today then 'expired' when not coalesce((r ->> 'balance_verified')::boolean, balance_verified) then 'pending_verification' else 'active' end) else status end
         where id = g.id;
        insert into booking.gift_card_ledger(gift_card_id, delta, balance_after, reason, note, meta) values (g.id, v_delta, v_bal, 'johku_sync', 'Johku-saldon synkka', jsonb_build_object('previous_balance', g.balance));
        v_upd := v_upd + 1;
      elsif not (r ->> 'balance_verified' is null) and (r ->> 'balance_verified')::boolean and not g.balance_verified then
        update booking.gift_cards set balance_verified = true, balance_verified_at = now(), balance_source = coalesce(r ->> 'balance_source', balance_source),
               status = case when status = 'pending_verification' then (case when balance = 0 then 'used' when valid_to < v_today then 'expired' else 'active' end) else status end where id = g.id;
        v_upd := v_upd + 1;
      else v_same := v_same + 1; end if;
      continue;
    end if;
    o := null; v_item := null; v_cust := null;
    if coalesce(r ->> 'purchase_order_ext', '') <> '' then
      select * into o from booking.orders where external_source = 'johku' and external_id = r ->> 'purchase_order_ext';
      if found then
        v_olink := v_olink + 1;
        if o.customer_id is not null then select * into v_cust from booking.customers where id = o.customer_id; v_blink := v_blink + 1; end if;
        if coalesce(r ->> 'purchase_item_ext', '') <> '' then
          select id into v_item from booking.order_items where order_id = o.id and external_source = 'johku' and external_id = r ->> 'purchase_item_ext';
          if v_item is not null then v_ilink := v_ilink + 1; end if;
        end if;
      end if;
    end if;
    v_status := case when v_bal = 0 then 'used' when v_valid < v_today then 'expired' when not coalesce((r ->> 'balance_verified')::boolean, true) then 'pending_verification' else 'active' end;
    if not coalesce((r ->> 'balance_verified')::boolean, true) then v_unver := v_unver + 1; end if;
    insert into booking.gift_cards(code, issuer, kind, product_id, initial_amount, balance, currency, valid_from, valid_to, status, purchase_order_id, purchase_order_item_id, note,
                                   external_source, external_id, created_at, source, vat_treatment, sale_vat_rate, accounting_origin, balance_verified, balance_verified_at, balance_source,
                                   single_order, activated_at, buyer_customer_id, buyer_name, buyer_email, locale, external_meta)
    values (r ->> 'code', 'johku', coalesce(r ->> 'kind', 'value'), nullif(r ->> 'product_id', '')::bigint, (r ->> 'initial_amount')::numeric, v_bal, 'EUR',
            (to_timestamp((r ->> 'created_unix')::bigint) at time zone booking._tz())::date, v_valid, v_status, o.id, v_item,
            'johku_import 17.10.2026; ' || coalesce(r -> 'meta' ->> 'template', ''), 'johku', r ->> 'external_id', to_timestamp((r ->> 'created_unix')::bigint),
            'johku', 'at_sale', nullif(r ->> 'sale_vat_rate', '')::numeric, 'johku', coalesce((r ->> 'balance_verified')::boolean, true),
            case when coalesce((r ->> 'balance_verified')::boolean, true) then now() end, coalesce(r ->> 'balance_source', 'johku_api'),
            coalesce((r ->> 'single_order')::boolean, false), to_timestamp((r ->> 'created_unix')::bigint), v_cust.id, v_cust.name, v_cust.email, 'fi', r -> 'meta')
    returning * into g;
    -- ledger (aikajärjestyksessä; Python varmistaa ettei saldo mene negatiiviseksi)
    v_run := 0;
    for l in select x from jsonb_array_elements(coalesce(r -> 'ledger', '[]'::jsonb)) x order by (x ->> 'at_unix')::bigint, (x ->> 'seq')::int loop
      v_run := v_run + (l ->> 'delta')::numeric;
      insert into booking.gift_card_ledger(gift_card_id, delta, balance_after, reason, at, note, meta)
      values (g.id, (l ->> 'delta')::numeric, v_run, l ->> 'reason', to_timestamp((l ->> 'at_unix')::bigint), l ->> 'note', l -> 'meta');
    end loop;
    if v_run <> v_bal then raise exception 'ledger-saldo % != kortin saldo % (external_id %)', v_run, v_bal, g.external_id using errcode = 'BK001', detail = 'ledger_mismatch'; end if;
    v_new := v_new + 1;
    v_st := jsonb_set(v_st, array[v_status], to_jsonb(coalesce((v_st ->> v_status)::int, 0) + 1));
  end loop;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (null, 'service_role', 'gift_cards', 'johku_import', 'JOHKU_IMPORT', null, jsonb_build_object('new', v_new, 'updated', v_upd, 'unchanged', v_same, 'order_linked', v_olink, 'item_linked', v_ilink, 'buyer_linked', v_blink, 'unverified', v_unver, 'status', v_st));
  return jsonb_build_object('ok', true, 'new', v_new, 'updated', v_upd, 'unchanged', v_same, 'order_linked', v_olink, 'item_linked', v_ilink, 'buyer_linked', v_blink, 'unverified', v_unver, 'status', v_st);
end $$;

-- ============================================================
-- 5) ajastus + oikeudet
-- ============================================================
do $$ begin
  if not exists (select 1 from cron.job where jobname = 'booking_gift_cards_housekeeping') then
    perform cron.schedule('booking_gift_cards_housekeeping', '7 * * * *', 'select booking.gift_cards_housekeeping()');
  end if;
exception when others then raise notice 'pg_cron-ajastus ohitettu: %', sqlerrm;
end $$;

do $$ declare r record; begin
  for r in select p.oid::regprocedure as f, p.proname from pg_proc p where p.pronamespace = 'booking'::regnamespace
            and (p.proname like '\_gc\_%' or p.proname like 'public\_%gift\_card%' or p.proname like 'admin\_%gift\_card%' or p.proname like 'svc\_gift\_cards%'
                 or p.proname in ('gift_cards_housekeeping', 'gift_code_norm', 'gift_code_fmt', 'gift_cards_norm_trg', 'gift_card_ledger_append_only_trg', 'payments_gift_card_guard_trg',
                                  '_is_johku_row', '_acct_excluded')) loop
    execute format('revoke all on function %s from public, anon, authenticated', r.f);
    execute format('grant execute on function %s to service_role', r.f);
    if r.proname like 'public\_%' then execute format('grant execute on function %s to anon, authenticated', r.f); end if;
    if r.proname like 'admin\_%' then execute format('grant execute on function %s to authenticated', r.f); end if;
  end loop;
end $$;
