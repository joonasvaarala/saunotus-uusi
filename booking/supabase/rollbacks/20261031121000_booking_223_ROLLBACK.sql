-- booking_223 rollback. Palauttaa lahjakortin myyntiveron ja lunastuksen tiedoksi-kuitin.
set local lock_timeout = '5s';

CREATE OR REPLACE FUNCTION booking._acct_excluded(p_order_id bigint, p_payment_id bigint DEFAULT NULL::bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select booking._is_johku_row(p_order_id, p_payment_id)
      or coalesce((select true from booking.payments p join booking.gift_cards g on g.id = p.gift_card_id
                    where p.id = p_payment_id and (g.accounting_origin = 'johku' or g.vat_treatment = 'at_sale')), false)
      or (not booking._gc_flag('voucher_claims.partner_voucher_accounted')
          and coalesce((select true from booking.payments p where p.id = p_payment_id and booking._is_partner_method(p.method)), false))
$function$;

-- booking.admin_set_procountor_settings(jsonb)
CREATE OR REPLACE FUNCTION booking.admin_set_procountor_settings(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  cur booking.integration_config;
  s jsonb; v_mode text; env text; approved text; vat text; prefix text; iban text;
  accounts jsonb; sales jsonb := '{}'::jsonb; clearing jsonb := '{}'::jsonb; rounding text;
  k text; v text;
  rates text[] := array['25.5','13.5','0','14','24','10'];
  methods text[] := array['cash','card_terminal','mobilepay','bank_transfer','invoice','gift_card','partner_voucher','partner_voucher_kokemuskauppa','partner_voucher_offerilla','partner_voucher_elamyslahjat','visma_pay','annual_card','pay_later','other'];
begin
  perform booking._require_permission('settings.edit');
  if p is null or jsonb_typeof(p) <> 'object' then perform booking._err('invalid_setting', 'Asetusten pitää olla objekti'); end if;
  if booking._json_has_secret_key(p) then perform booking._err('secrets_not_allowed', 'Salaisuuksia ei tallenneta asetuksiin'); end if;
  select * into cur from booking.integration_config where key = 'procountor';
  if not found then perform booking._err('not_configured', 'procountor-asetus puuttuu'); end if;
  v_mode := coalesce(nullif(btrim(p->>'mode'), ''), cur.mode);
  if v_mode not in ('off', 'dry_run', 'live') then perform booking._err('invalid_setting', 'Tila on off, dry_run tai live'); end if;
  env := lower(btrim(coalesce(p->>'environment', cur.settings->>'environment', 'pts')));
  if env in ('sandbox', '') then env := 'pts'; end if;
  if env not in ('pts', 'prod') then perform booking._err('invalid_setting', 'Ympäristö on pts tai prod'); end if;
  if p ? 'approved_by' then approved := btrim(coalesce(p->>'approved_by', ''));
  else approved := btrim(coalesce(cur.settings->>'approved_by', '')); end if;
  if approved <> '' and (char_length(approved) < 3 or char_length(approved) > 80 or approved like 'eyJ%') then
    perform booking._err('invalid_setting', 'approved_by on nimi ja päivä, ei tunnusta');
  end if;
  if v_mode = 'live' and approved = '' then perform booking._err('approval_required', 'Yhdistetty tila vaatii approved_by'); end if;
  if p ? 'daily_enabled' and jsonb_typeof(p->'daily_enabled') is distinct from 'boolean' then perform booking._err('invalid_setting', 'daily_enabled on totuusarvo'); end if;
  if p ? 'vat_status' then vat := btrim(coalesce(p->>'vat_status', ''));
  else vat := btrim(coalesce(cur.settings->>'vat_status', '')); end if;
  if vat <> '' and vat !~ '^[0-9]{1,4}$' then perform booking._err('invalid_setting', 'ALV-tila on 1–4 numeroa'); end if;
  prefix := btrim(coalesce(nullif(p->>'api_prefix', ''), cur.settings->>'api_prefix', '/supported/api'));
  if prefix !~ '^/api$|^/latest/api$|^/supported/api$|^/v[0-9]{4}/api$' then perform booking._err('invalid_setting', 'API-etuliite ei kelpaa'); end if;
  if p ? 'bank_account' then iban := upper(regexp_replace(coalesce(p->>'bank_account', ''), '\s', '', 'g'));
  else iban := coalesce(cur.settings->>'bank_account', ''); end if;
  if iban <> '' and iban !~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{10,30}$' then perform booking._err('invalid_setting', 'Tilinumero on IBAN tai tyhjä'); end if;
  accounts := coalesce(p->'accounts', '{}'::jsonb);
  if jsonb_typeof(accounts) <> 'object' then perform booking._err('invalid_setting', 'accounts on objekti'); end if;
  rounding := btrim(coalesce(accounts->>'rounding', ''));
  if rounding <> '' and rounding !~ '^[0-9A-Za-z]{1,20}$' then perform booking._err('invalid_setting', 'Tilinumero ei kelpaa'); end if;
  if accounts ? 'sales_by_vat' then
    if jsonb_typeof(accounts->'sales_by_vat') <> 'object' then perform booking._err('invalid_setting', 'sales_by_vat on objekti'); end if;
    for k, v in select key, btrim(value) from jsonb_each_text(accounts->'sales_by_vat') loop
      if not (k = any (rates)) then perform booking._err('invalid_setting', 'Tuntematon ALV-kanta: ' || k); end if;
      if v <> '' and v !~ '^[0-9A-Za-z]{1,20}$' then perform booking._err('invalid_setting', 'Tilinumero ei kelpaa'); end if;
      if v <> '' then sales := sales || jsonb_build_object(k, v); end if;
    end loop;
  end if;
  if accounts ? 'clearing_by_method' then
    if jsonb_typeof(accounts->'clearing_by_method') <> 'object' then perform booking._err('invalid_setting', 'clearing_by_method on objekti'); end if;
    for k, v in select key, btrim(value) from jsonb_each_text(accounts->'clearing_by_method') loop
      if not (k = any (methods)) then perform booking._err('invalid_setting', 'Tuntematon maksutapa: ' || k); end if;
      if v <> '' and v !~ '^[0-9A-Za-z]{1,20}$' then perform booking._err('invalid_setting', 'Tilinumero ei kelpaa'); end if;
      if v <> '' then clearing := clearing || jsonb_build_object(k, v); end if;
    end loop;
  end if;
  if v_mode = 'live' and (vat !~ '^[0-9]{1,4}$' or sales = '{}'::jsonb or clearing = '{}'::jsonb) then
    perform booking._err('live_incomplete', 'Yhdistetty tila vaatii ALV-tilan, vähintään yhden myyntitilin ja maksutavan tilin');
  end if;
  s := coalesce(cur.settings, '{}'::jsonb)
    || jsonb_build_object(
         'environment', env,
         'daily_enabled', case when p ? 'daily_enabled' then (p->>'daily_enabled')::boolean else coalesce((cur.settings->>'daily_enabled')::boolean, false) end,
         'api_prefix', prefix,
         'vat_status', vat,
         'approved_by', nullif(approved, ''),
         'bank_account', nullif(iban, ''),
         'accounts', jsonb_build_object('rounding', nullif(rounding, ''), 'sales_by_vat', sales, 'clearing_by_method', clearing));
  s := jsonb_strip_nulls(s);
  update booking.integration_config
     set mode = v_mode, settings = s, updated_by = auth.uid()
   where key = 'procountor';
  return booking.admin_get_procountor_settings();
end $function$;

CREATE OR REPLACE FUNCTION booking.payments_paid_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_info boolean;
begin
  v_info := exists (
    select 1 from booking.gift_cards g
     where g.id = new.gift_card_id
       and new.method = 'gift_card'
       and g.accounting_origin = 'native'
       and g.source is distinct from 'johku'
       and g.vat_treatment = 'at_sale'
       and g.complimentary = false
       and not booking._is_johku_row(new.order_id, new.id));
  if booking._acct_excluded(new.order_id, new.id) then
    if v_info and not exists (select 1 from booking.orders o where o.id = new.order_id and o.status = 'pending') then
      perform booking._alloc_payment_lines(new.id);
      perform booking._issue_giftcard_info_receipt(new.id);
    end if;
    return null;
  end if;
  perform booking._alloc_payment_lines(new.id);
  if new.method = 'gift_card' and exists (select 1 from booking.orders o where o.id = new.order_id and o.status = 'pending') then return null; end if;
  perform booking._on_payment_paid(new.id);
  return null;
end $function$;

CREATE OR REPLACE FUNCTION booking.orders_confirmed_mail_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pid bigint;
begin
  if new.external_source is not null then return null; end if;
  -- booking_176: kumppanilahjakorttivaraus (voucher_claims) → ei erillistä tilausvahvistusta; voucher_claim_received on ainoa varausvahvistus
  if not booking._vc_partner_order(new.id) then
    if booking._enqueue_email('order_confirmation', new.id, null, null, 'order_confirmation:' || new.id) then
      update booking.email_outbox set next_attempt_at = now() + interval '45 seconds' where dedupe_key = 'order_confirmation:' || new.id;
    end if;
  end if;
  for pid in select p.id from booking.payments p
              join booking.gift_cards g on g.id = p.gift_card_id
              where p.order_id = new.id and p.method = 'gift_card' and p.status in ('paid', 'partially_refunded')
                and not exists (select 1 from booking.receipts rc where rc.payment_id = p.id and rc.kind = 'receipt')
                and g.accounting_origin = 'native' and g.source is distinct from 'johku'
                and g.vat_treatment = 'at_sale' and g.complimentary = false
                and not booking._is_johku_row(new.id, p.id)
              order by p.id loop
    perform booking._issue_giftcard_info_receipt(pid);
  end loop;
  for pid in select p.id from booking.payments p
              where p.order_id = new.id and p.method = 'gift_card' and p.status in ('paid', 'partially_refunded')
                and not exists (select 1 from booking.receipts rc where rc.payment_id = p.id and rc.kind = 'receipt')
                and not booking._acct_excluded(new.id, p.id)
              order by p.id loop
    perform booking._on_payment_paid(pid);
  end loop;
  return null;
end $function$;

create or replace function booking._on_payment_paid(p_payment_id bigint) returns void language plpgsql security definer set search_path = '' as $$
declare v_id bigint; v_order bigint;
begin
  v_id := booking._issue_receipt(p_payment_id);
  if v_id is not null then
    select order_id into v_order from booking.payments where id = p_payment_id;
    perform booking._enqueue_email('receipt', v_order, v_id, p_payment_id, 'receipt:' || v_id);
  end if;
end $$;

create or replace function booking._on_refund_done(p_refund_id bigint) returns void language plpgsql security definer set search_path = '' as $$
declare v_id bigint; v_order bigint; v_pay bigint;
begin
  v_id := booking._issue_refund_receipt(p_refund_id);
  if v_id is not null then
    select order_id, payment_id into v_order, v_pay from booking.refunds where id = p_refund_id;
    perform booking._enqueue_email('refund_receipt', v_order, v_id, v_pay, 'receipt:' || v_id);
  end if;
end $$;

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
  if booking._order_invoice_locked(o.id) then perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.'); end if;
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

create or replace function booking._gc_sell(p_items jsonb, p_cust bigint, p_channel text, p_locale text, p_buyer_name text, p_buyer_email text,
    p_status text, p_vat_override text default null, p_valid_months int default null, p_default_rname text default null, p_default_remail text default null,
    p_default_greeting text default null, p_default_delivery_to text default null, p_default_cover text default null, p_default_deliver_on text default null, p_default_deliver_time text default null) returns jsonb
language plpgsql security definer set search_path to ''
as $$
declare
  it jsonb; pkg booking.gift_card_packages; v_qty int; v_amt numeric; v_n int := 0; v_total numeric := 0; v_max int := (booking._setting('gift_cards.max_cards_per_order', '10'::jsonb) #>> '{}')::int;
  v_order booking.orders; v_oi bigint; v_vat text; v_rate numeric; i int; g booking.gift_cards; v_cards jsonb := '[]'::jsonb;
  v_rn text; v_re text; v_gr text; v_name text; v_months int; v_locale text := coalesce(nullif(p_locale, ''), 'fi');
  v_lines jsonb := '[]'::jsonb; v_dl jsonb; v_quote jsonb; v_persons int;
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
      v_quote := booking._gc_quote(pkg, it);
      v_amt := (v_quote ->> 'amount')::numeric;
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
    if pkg.is_open then
      v_amt := (it ->> 'amount')::numeric; v_persons := null;
    else
      v_quote := booking._gc_quote(pkg, it);
      v_amt := (v_quote ->> 'amount')::numeric;
      v_persons := (v_quote ->> 'persons')::int;
    end if;
    v_vat := 'at_sale';
    v_rate := 25.5;
    v_months := coalesce(p_valid_months, pkg.valid_months);
    v_name := case when pkg.is_open then pkg.name || ' ' || trim(trailing '.' from trim(trailing '0' from to_char(v_amt, 'FM99990.00'))) || ' €' else pkg.name end;
    insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
    values (v_order.id, pkg.kb_product_id, v_name, 'gift_card', v_qty, v_amt, v_amt * v_qty, v_rate,
            jsonb_strip_nulls(jsonb_build_object('gift_card_package', pkg.code, 'vat_treatment', v_vat, 'persons', v_persons))) returning id into v_oi;
    v_rn := nullif(btrim(coalesce(it ->> 'recipient_name', p_default_rname, '')), '');
    v_re := nullif(lower(btrim(coalesce(it ->> 'recipient_email', p_default_remail, ''))), '');
    v_gr := nullif(btrim(regexp_replace(coalesce(it ->> 'greeting', p_default_greeting, ''), '[\x00-\x09\x0b\x0c\x0e-\x1f\x7f]', '', 'g')), '');
    v_dl := booking._gc_delivery_resolve(coalesce(it ->> 'delivery_to', p_default_delivery_to), v_re, coalesce(it ->> 'cover_message', p_default_cover),
              coalesce(it ->> 'deliver_on', p_default_deliver_on), coalesce(it ->> 'deliver_time', p_default_deliver_time), coalesce(p_valid_months, pkg.valid_months));
    for i in 1..v_qty loop
      g := booking._gc_create_card(pkg, v_amt, 'pending_payment', v_order.id, v_oi, p_cust,
                                   p_buyer_name, p_buyer_email, v_rn, v_re, v_gr, v_locale, v_months, v_vat, null,
                                   p_delivery_to := v_dl ->> 'delivery_to', p_cover := v_dl ->> 'cover_message', p_deliver_on := (v_dl ->> 'deliver_on')::date, p_deliver_time := (v_dl ->> 'deliver_time')::time);
      if v_persons is not null then update booking.gift_cards set persons = v_persons where id = g.id; end if;
      if v_qty = 1 then update booking.order_items set gift_card_id = g.id where id = v_oi; end if;
      v_cards := v_cards || jsonb_strip_nulls(jsonb_build_object('id', g.id, 'public_token', g.public_token, 'package_code', pkg.code, 'package_name', pkg.name, 'amount', v_amt, 'persons', v_persons, 'status', g.status,
                                               'vat_treatment', v_vat, 'recipient_name', v_rn, 'delivery_to', g.delivery_to, 'deliver_on', g.deliver_on, 'deliver_time', to_char(g.deliver_time, 'HH24:MI')));
    end loop;
    v_lines := v_lines || jsonb_strip_nulls(jsonb_build_object('order_item_id', v_oi, 'package', pkg.code, 'quantity', v_qty, 'unit', v_amt, 'persons', v_persons, 'vat_rate', v_rate, 'vat_treatment', v_vat));
  end loop;
  update booking.orders set total_gross = v_total where id = v_order.id;
  return jsonb_build_object('order_id', v_order.id, 'order_no', v_order.order_no, 'public_token', v_order.public_token, 'total', v_total, 'cards', v_cards, 'lines', v_lines);
end $$;

CREATE OR REPLACE FUNCTION booking._procountor_daily_build(p_date date, p_report jsonb, p_settings jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_receipts int := coalesce((p_report #>> '{totals,receipts}')::int, 0);
  v_refunds int := coalesce((p_report #>> '{totals,refund_receipts}')::int, 0);
  v_rounding numeric := round(coalesce((p_report #>> '{totals,rounding}')::numeric, 0), 2);
  v_unreceipted int := coalesce((p_report #>> '{unreceipted,payments}')::int, 0);
  v_vat_sum numeric := 0;
  v_method_sum numeric := 0;
  v_missing text[] := '{}';
  v_tx jsonb := '[]'::jsonb;
  v_first boolean := true;
  v_status int;
  v_acct text;
  v_method text;
  r record;
begin
  if v_receipts = 0 and v_refunds = 0 then
    if v_unreceipted > 0 then
      return jsonb_build_object('empty', false, 'ready', false, 'missing', jsonb_build_array('unreceipted'), 'request', null);
    end if;
    return jsonb_build_object('empty', true, 'ready', true, 'missing', '[]'::jsonb, 'request', null);
  end if;

  select coalesce(round(sum((e ->> 'gross')::numeric), 2), 0) into v_vat_sum
    from jsonb_array_elements(coalesce(p_report -> 'by_vat', '[]'::jsonb)) e;
  select coalesce(round(sum(coalesce((e ->> 'gross')::numeric, 0) + coalesce((e ->> 'refunds')::numeric, 0)), 2), 0) into v_method_sum
    from jsonb_array_elements(coalesce(p_report -> 'by_method', '[]'::jsonb)) e;
  if abs(v_vat_sum - v_method_sum) > 0.05 then
    v_missing := array_append(v_missing, 'imbalance');
  end if;
  if v_unreceipted > 0 then
    v_missing := array_append(v_missing, 'unreceipted');
  end if;

  if coalesce(p_settings ->> 'vat_status', '') ~ '^[0-9]{1,4}$' then
    v_status := (p_settings ->> 'vat_status')::int;
  else
    v_missing := array_append(v_missing, 'vat_status');
  end if;

  for r in
    select coalesce(e ->> 'method', '') as method,
           round(coalesce((e ->> 'gross')::numeric, 0) + coalesce((e ->> 'refunds')::numeric, 0), 2) as net_gross
      from jsonb_array_elements(coalesce(p_report -> 'by_method', '[]'::jsonb)) e
     order by 1
  loop
    if r.net_gross = 0 then continue; end if;
    v_method := nullif(r.method, '');
    v_acct := nullif(btrim(coalesce(p_settings #>> array['accounts', 'clearing_by_method', coalesce(v_method, '')], '')), '');
    -- booking_173: myyjäkohtainen kumppanilahjakortti ilman omaa tiliä → vanha yhteinen partner_voucher-tili (siirtymä)
    if v_acct is null and booking._is_partner_method(v_method) then
      v_acct := nullif(btrim(coalesce(p_settings #>> array['accounts', 'clearing_by_method', 'partner_voucher'], '')), '');
    end if;
    if v_acct is null or v_acct !~ '^[0-9A-Za-z]{1,20}$' then
      v_missing := array_append(v_missing, 'clearing:' || coalesce(v_method, 'null'));
      v_acct := null;
    end if;
    v_tx := v_tx || jsonb_build_array(jsonb_build_object(
      'transactionType', case when v_first then 'REVERSING_ENTRY' else 'ENTRY' end,
      'account', v_acct,
      'accountingValue', r.net_gross,
      'vatPercent', 0,
      'description', 'Maksutapa ' || coalesce(v_method, '?')));
    v_first := false;
  end loop;

  if v_rounding <> 0 then
    v_acct := nullif(btrim(coalesce(p_settings #>> '{accounts,rounding}', '')), '');
    if v_acct is null or v_acct !~ '^[0-9A-Za-z]{1,20}$' then
      v_missing := array_append(v_missing, 'rounding');
      v_acct := null;
    end if;
    v_tx := v_tx || jsonb_build_array(jsonb_build_object(
      'transactionType', case when v_first then 'REVERSING_ENTRY' else 'ENTRY' end,
      'account', v_acct,
      'accountingValue', round(-v_rounding, 2),
      'vatPercent', 0,
      'description', 'Käteispyöristys'));
    v_first := false;
  end if;

  for r in
    select (e ->> 'rate')::numeric as rate, round((e ->> 'net')::numeric, 2) as net
      from jsonb_array_elements(coalesce(p_report -> 'by_vat', '[]'::jsonb)) e
     where round(coalesce((e ->> 'net')::numeric, 0), 2) <> 0
     order by 1
  loop
    v_acct := nullif(btrim(coalesce(p_settings #>> array['accounts', 'sales_by_vat', trim_scale(r.rate)::text], '')), '');
    if v_acct is null or v_acct !~ '^[0-9A-Za-z]{1,20}$' then
      v_missing := array_append(v_missing, 'sales:' || trim_scale(r.rate)::text);
      v_acct := null;
    end if;
    -- Myyntirivi on aina ENTRY. REVERSING_ENTRY sallii vain vatPercent 0 (Procountor Transaction).
    v_tx := v_tx || jsonb_build_array(jsonb_build_object(
      'transactionType', 'ENTRY',
      'account', v_acct,
      'accountingValue', round(-r.net, 2),
      'vatPercent', r.rate,
      'description', 'Myynti ALV ' || trim_scale(r.rate)::text));
  end loop;

  if jsonb_array_length(v_tx) = 0 then
    v_missing := array_append(v_missing, 'no_lines');
  end if;

  return jsonb_build_object(
    'empty', false,
    'ready', cardinality(v_missing) = 0,
    'missing', to_jsonb(v_missing),
    'request', jsonb_build_object(
      'type', 'JOURNAL',
      'status', 'UNFINISHED',
      'name', 'Saunotus ' || to_char(p_date, 'YYYY-MM-DD'),
      'receiptDate', to_char(p_date, 'YYYY-MM-DD'),
      'vatType', 'SALES',
      'vatStatus', v_status,
      'transactions', v_tx));
end $function$;
