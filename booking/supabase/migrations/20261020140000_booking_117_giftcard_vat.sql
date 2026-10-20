-- booking_117_giftcard_vat (20.10.2026)
-- Oma lahjakortti on yksikäyttöinen: ALV 25,5 % kirjataan myynnissä (at_sale).
-- Lunastus ei luo uutta myyntiä eikä toista ALV-kirjausta (_acct_excluded). Tiedoksi-kuitti on booking_119.
-- Maksuton hallintamyöntö: arvonlisäveroa ei kirjata myönnettäessä eikä lunastettaessa (complimentary).
-- Johku-tuonti ei muutu. Uusia oman järjestelmän kortteja ei ole myyty, joten korttirivejä ei siirretä.
-- Rollback: rollbacks/20261020140000_booking_117_ROLLBACK.sql
set local lock_timeout = '5s';

drop trigger if exists gift_card_packages_own_vat on booking.gift_card_packages;
drop function if exists booking._gc_complimentary_vat(text);
delete from booking.settings where key = 'gift_cards.complimentary_vat_treatment';

alter table booking.gift_cards add column if not exists complimentary boolean not null default false;
alter table booking.gift_cards alter column vat_treatment set default 'at_sale';

update booking.gift_card_packages
   set vat_treatment = 'at_sale',
       vat_rate = 25.5;

create or replace function booking.gift_card_packages_own_vat_trg()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.vat_treatment is distinct from 'at_sale' or new.vat_rate is distinct from 25.5 then
    perform booking._err('gift_card_vat_rate', 'Oma lahjakorttipaketti on 25,5 %:n tuote, ja vero kirjataan myynnissä');
  end if;
  return new;
end $$;

create trigger gift_card_packages_own_vat
  before insert or update of vat_treatment, vat_rate on booking.gift_card_packages
  for each row execute function booking.gift_card_packages_own_vat_trg();

create or replace function booking._gc_create_card(p_pkg booking.gift_card_packages, p_amount numeric, p_status text, p_order bigint, p_order_item bigint, p_cust bigint,
    p_buyer_name text, p_buyer_email text, p_rname text, p_remail text, p_greeting text, p_locale text, p_valid_months int, p_vat text, p_note text,
    p_ledger_reason text default 'purchase', p_delivery_to text default 'buyer', p_cover text default null, p_deliver_on date default null, p_deliver_time time default null) returns booking.gift_cards
language plpgsql security definer set search_path to ''
as $$
declare g booking.gift_cards; v_try int := 0; v_code text; v_c text; v_today date := booking._gc_today(); v_active boolean := p_status = 'active';
        v_comp boolean := coalesce(p_ledger_reason, 'purchase') = 'manual_issue';
begin
  if p_vat is null or p_vat not in ('at_sale', 'at_redemption') then
    perform booking._err('invalid_param', 'Virheellinen ALV-käsittely');
  end if;
  if p_vat = 'at_redemption' then
    perform booking._err('gift_card_vat_rate', 'Lahjakortilla voi maksaa vain tuotteita, joiden arvonlisävero on 25,5 %');
  end if;
  loop
    v_try := v_try + 1;
    if v_try > 30 then perform booking._err('code_generation_failed', 'Koodin luonti epäonnistui, yritä uudelleen'); end if;
    v_code := booking._gc_random_code();
    if exists (select 1 from booking.gift_card_blocked_codes b where b.code_sha256 = encode(sha256(convert_to(v_code, 'UTF8')), 'hex')) then continue; end if;
    begin
      insert into booking.gift_cards(code, issuer, kind, product_id, initial_amount, balance, valid_from, valid_to, status, purchase_order_id, purchase_order_item_id, note, source,
                                     package_code, valid_months, buyer_customer_id, buyer_name, buyer_email, recipient_name, recipient_email, greeting, locale,
                                     vat_treatment, sale_vat_rate, accounting_origin, complimentary, activated_at, created_by, balance_verified, balance_verified_at, balance_source, delivery_to, cover_message, deliver_on, deliver_time)
      values (v_code, 'own', p_pkg.kind, p_pkg.kb_product_id, p_amount, case when v_active then p_amount else 0 end,
              case when v_active then v_today end, case when v_active then (v_today + make_interval(months => p_valid_months))::date end,
              p_status, p_order, p_order_item, p_note, 'native', p_pkg.code, p_valid_months, p_cust, p_buyer_name, p_buyer_email, p_rname, p_remail, p_greeting, coalesce(p_locale, 'fi'),
              'at_sale', case when v_comp then 0 else 25.5 end, 'native', v_comp, case when v_active then now() end, auth.uid(), true, now(), 'native', coalesce(p_delivery_to, 'buyer'), p_cover, p_deliver_on, p_deliver_time)
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
  if p_vat_override is not null and p_vat_override <> 'at_sale' then
    perform booking._err('gift_card_vat_rate', 'Lahjakortilla voi maksaa vain tuotteita, joiden arvonlisävero on 25,5 %');
  end if;
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
  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, created_by)
  values (p_cust, case when p_status = 'confirmed' then 'confirmed' else 'pending' end, 'unpaid', 0, p_channel, v_locale, auth.uid()) returning * into v_order;
  if p_status = 'confirmed' then update booking.orders set confirmed_at = now() where id = v_order.id; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    select * into pkg from booking.gift_card_packages where code = it ->> 'package';
    v_qty := case when it ? 'quantity' and jsonb_typeof(it -> 'quantity') <> 'null' then (it ->> 'quantity')::int else 1 end;
    v_amt := case when pkg.is_open then (it ->> 'amount')::numeric else pkg.price end;
    v_vat := 'at_sale';
    v_rate := 25.5;
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
    if p_vat_treatment is not null and p_vat_treatment <> 'at_sale' then perform booking._err('gift_card_vat_rate', 'Lahjakortilla voi maksaa vain tuotteita, joiden arvonlisävero on 25,5 %'); end if;
    v_res := booking._gc_sell(jsonb_build_array(jsonb_build_object('package', p_package, 'amount', p_amount, 'quantity', p_quantity)), v_cust, p_channel, p_locale, v_bname, v_bemail,
                              'confirmed', 'at_sale', p_valid_months, p_recipient_name, p_recipient_email, p_greeting, p_delivery_to, p_cover_message, p_deliver_on, p_deliver_time);
    v_oid := (v_res ->> 'order_id')::bigint;
    if p_payment_method in ('pay_later', 'invoice') then
      insert into booking.payments(order_id, method, provider, status, amount, note, created_by) values (v_oid, p_payment_method, 'manual', 'pending', (v_res ->> 'total')::numeric, p_note, auth.uid());
    else
      v_rec := booking.admin_record_payment(v_oid, p_payment_method, (v_res ->> 'total')::numeric, p_note);
    end if;
    select array_agg((c ->> 'id')::bigint order by (c ->> 'id')::bigint) into v_ids from jsonb_array_elements(v_res -> 'cards') c;
    select coalesce(jsonb_agg(booking._gc_card_json(x, true) order by x.id), '[]'::jsonb) into v_cards from booking.gift_cards x where x.id = any (v_ids);
    return jsonb_build_object('ok', true, 'order_id', v_oid, 'order_no', v_res -> 'order_no', 'total', v_res -> 'total', 'cards', v_cards,
                              'payment', v_rec, 'paid', v_rec is not null);
  end if;
  -- Maksuton myöntö: ei tilausta, ei arvonlisäveroa myönnössä eikä lunastuksessa.
  if nullif(btrim(coalesce(p_note, '')), '') is null or char_length(btrim(p_note)) < 3 then perform booking._err('invalid_param', 'Anna maksuttoman kortin syy (p_note)'); end if;
  if p_vat_treatment is not null and p_vat_treatment <> 'at_sale' then perform booking._err('gift_card_vat_rate', 'Lahjakortilla voi maksaa vain tuotteita, joiden arvonlisävero on 25,5 %'); end if;
  select * into pkg from booking.gift_card_packages where code = p_package;
  if not found then perform booking._err('invalid_package', 'Tuntematon lahjakorttipaketti'); end if;
  if pkg.is_open then
    if p_amount is null or p_amount <> round(p_amount, 2) or p_amount < pkg.min_amount or p_amount > pkg.max_amount then perform booking._err('invalid_amount', format('Summa %s–%s €', pkg.min_amount, pkg.max_amount)); end if;
    v_amt := p_amount;
  else
    if p_amount is not null and p_amount <> pkg.price then perform booking._err('invalid_amount', 'Paketin hinta on kiinteä'); end if;
    v_amt := pkg.price;
  end if;
  v_vat := 'at_sale';
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
    'vat_treatment', g.vat_treatment, 'sale_vat_rate', g.sale_vat_rate, 'accounting_origin', g.accounting_origin, 'complimentary', g.complimentary, 'single_order', g.single_order,
    'buyer_customer_id', g.buyer_customer_id, 'buyer_name', g.buyer_name, 'buyer_email', g.buyer_email,
    'recipient_name', g.recipient_name, 'recipient_email', g.recipient_email, 'greeting', g.greeting, 'locale', g.locale,
    'purchase_order_id', g.purchase_order_id, 'order_no', (select o.order_no from booking.orders o where o.id = g.purchase_order_id),
    'public_token', g.public_token, 'created_at', g.created_at, 'activated_at', g.activated_at, 'last_used_at', g.last_used_at, 'note', g.note)
$$;

-- Oma kortti (myös maksuton) maksaa vain 25,5 %:n rivit. Johku-kortin kohdistus ei muutu.
CREATE OR REPLACE FUNCTION booking._gc_redeem(p_order_id bigint, p_card_id bigint, p_amount numeric, p_note text, p_public boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o booking.orders; g booking.gift_cards; v_unpaid numeric; v_amt numeric; v_id bigint; rc record; v_excl boolean; v_card booking.gift_cards; v_rest numeric; v_confirmed boolean := false;
        v_own boolean; v_ok numeric; v_left numeric; v_use numeric; ur record;
begin
  if not booking._gc_flag('gift_cards.redeem_enabled') then perform booking._err('redeem_disabled', 'Lahjakorttien lunastus ei ole vielä käytössä'); end if;
  select * into o from booking.orders where id = p_order_id for update;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if p_public and o.status = 'expired' then perform booking._err('order_expired', 'Varaus on vanhentunut – tee uusi varaus'); end if;
  if p_public and o.status = 'pending' and o.hold_kind = 'preliminary' then perform booking._err('order_preliminary', 'Alustava varaus: maksu pyydetään vahvistuksen jälkeen'); end if;
  if p_public and o.status = 'pending' and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now())
     and not booking._order_mp_inflight(o.id) then
    perform booking._err('order_expired', 'Varaus on vanhentunut – tee uusi varaus');
  end if;
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
  v_own := g.source is distinct from 'johku' and g.accounting_origin is distinct from 'johku';
  if v_own then
    select coalesce(sum(u.remaining) filter (where abs(coalesce(u.vat_rate, 0) - 25.5) < 0.001 and u.remaining > 0.004), 0)
      into v_ok from booking._order_uncovered(o.id, false) u;
    if v_amt > v_ok + 0.004 then
      perform booking._err('gift_card_vat_rate', 'Lahjakortilla voi maksaa vain tuotteita, joiden arvonlisävero on 25,5 %');
    end if;
  end if;
  update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'korvattu lahjakorttimaksulla')
   where order_id = o.id and status = 'pending' and external_source is null
     and ((provider = 'manual' and not exists (select 1 from booking.payment_lines pl where pl.payment_id = payments.id)) or provider <> 'manual');
  insert into booking.payments(order_id, method, provider, status, amount, gift_card_id, note, created_by)
  values (o.id, 'gift_card', 'manual', 'pending', v_amt, g.id, nullif(concat_ws(' | ', 'Lahjakortti …' || right(g.code, 4), p_note), ''), auth.uid()) returning id into v_id;
  if v_own then
    v_left := v_amt;
    if abs(v_ok - v_amt) < 0.005 then
      insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
      select v_id, u.item_id, u.description, u.kind, u.quantity, u.remaining, u.vat_rate
        from booking._order_uncovered(o.id, false) u
       where abs(coalesce(u.vat_rate, 0) - 25.5) < 0.001 and u.remaining > 0.004;
    else
      for ur in select * from booking._order_uncovered(o.id, false) u where abs(coalesce(u.vat_rate, 0) - 25.5) < 0.001 and u.remaining > 0.004 loop
        exit when v_left <= 0.004;
        v_use := least(ur.remaining, v_left);
        insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
        values (v_id, ur.item_id, ur.description, ur.kind, case when v_use = ur.remaining then ur.quantity else 1 end, v_use, ur.vat_rate);
        v_left := v_left - v_use;
      end loop;
    end if;
  else
    perform booking._alloc_payment_lines(v_id);
  end if;
  update booking.payments set status = 'paid', paid_at = now() where id = v_id;       -- trigger: tiedoksi-kuitti vain maksetulle omalle at_sale-kortille, ei kirjanpitoon
  perform booking._gc_apply(g.id, -v_amt, 'redemption', o.id, v_id, p_note);
  select * into v_card from booking.gift_cards where id = g.id;
  if v_card.single_order and v_card.balance > 0 then
    perform booking._gc_apply(g.id, -v_card.balance, 'single_order_forfeit', o.id, v_id, 'Kertakäyttökortti: jäännös ei käytettävissä');
    select * into v_card from booking.gift_cards where id = g.id;
  end if;
  perform booking._sync_placeholder(o.id);
  perform booking._refresh_order_payment(o.id);
  v_rest := greatest(o.total_gross - (booking._order_balance(o.id) ->> 'net_paid')::numeric, 0);
  if o.status = 'pending' and v_rest <= 0.004 then
    update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = o.id and status = 'pending';
    update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()) where id = o.id and status = 'pending';
    v_confirmed := true;
  end if;
  v_excl := booking._acct_excluded(o.id, v_id);
  select receipt_no, id into rc from booking.receipts where payment_id = v_id and kind = 'receipt';
  return jsonb_build_object('ok', true, 'payment_id', v_id, 'amount', v_amt, 'order_id', o.id, 'balance', booking._order_balance(o.id),
    'gift_card', jsonb_build_object('id', v_card.id, 'code_last4', right(v_card.code, 4), 'balance', v_card.balance, 'status', v_card.status, 'valid_to', v_card.valid_to),
    'receipt_id', rc.id, 'receipt_no', rc.receipt_no, 'accounted', not v_excl,
    'confirmed', v_confirmed, 'remaining', v_rest, 'order_status', (select status from booking.orders where id = o.id));
end $function$;

revoke all on function booking.gift_card_packages_own_vat_trg() from public, anon, authenticated;
grant execute on function booking.gift_card_packages_own_vat_trg() to service_role;

comment on function booking.gift_card_packages_own_vat_trg() is 'Oma lahjakorttipaketti on at_sale ja ALV 25,5 %. Johku-korttirivejä tämä ei koske. booking_117.';
comment on column booking.gift_cards.complimentary is 'Maksuton hallintamyöntö: arvonlisäveroa ei kirjata myönnössä eikä lunastuksessa. booking_117.';
