-- booking_173 ROLLBACK: palauttaa korvatut funktiot tuotannon määrittelyihin (md5 alla, vasen sarake), poistaa uudet funktiot, triggerin,
-- myyjäkohtaiset maksutavat ja Procountorin kolme uutta tiliavainta. Aja yhdessä transaktiossa (psql -1).
-- Jo kirjatut myyjäkohtaiset maksut siirretään takaisin maksutavalle partner_voucher (summa, tila ja muistiinpano ennallaan; ilmoitus kertoo määrän).
-- Poistaa myös asetuksen voucher_claims.redeem_urls ja hallinnan uudet RPC:t. Lunastuspyyntöjen tilat ja maksut jäävät (lunastetut pysyvät lunastettuina).
-- Kiitoskauppa palaa valintoihin (_vc_sources tuotannon määrittely).
--   booking._vc_guess(text): d1f3d6bcc0779ea2f87b1fef28dfdfe1 -> 3f33a0425eb0fa346ba617659b7b729d
--   booking._vc_sources(): 7e673c0f8d2a0cb8a49d2ddc98e14c47 -> a1e85bd09bb916228984a4e667207bc5
--   booking.public_submit_voucher_claim(uuid,text,text,bigint): 215ea958ea7678094ad350045ad13665 -> de84e5ce9b1062111c4248e7c582fdb8
--   booking.public_update_voucher_claim_code(uuid,bigint,text,text): fbd67b7fea7ae4fa2349e0099d1748b1 -> 778fb281381aa026ed3e8afd49431ef6
--   booking._vc_pay(booking.orders,booking.voucher_claims,numeric): 5166766dabf18f04ea4dae2c6174881b -> 3c24fd721b0e8bc6f1bdfb8a800c5a0e
--   booking._acct_excluded(bigint,bigint): ca22a722ac7ae9cab1afaef84b9bc216 -> 4cbe97dbc038d5839453cf90f30525a5
--   booking.admin_set_procountor_settings(jsonb): 69142339b6acc7069ae4b559dfc6c75b -> 0b67b832a42a1f85fca071a3dc4ac471
--   booking._procountor_daily_build(date,jsonb,jsonb): c480c6ed3bf001d5ef568fb5678726cc -> f3e26f0ea30ab0e7a15f18c61aaf661e
set local lock_timeout = '5s';


do $g$
declare v text; ok boolean := true; msg text := '';
begin
  v := md5(pg_get_functiondef('booking._vc_guess(text)'::regprocedure));
  if v not in ('d1f3d6bcc0779ea2f87b1fef28dfdfe1', '3f33a0425eb0fa346ba617659b7b729d') then ok := false; msg := msg || ' _vc_guess=' || v; end if;
  v := md5(pg_get_functiondef('booking._vc_sources()'::regprocedure));
  if v not in ('7e673c0f8d2a0cb8a49d2ddc98e14c47', 'a1e85bd09bb916228984a4e667207bc5') then ok := false; msg := msg || ' _vc_sources=' || v; end if;
  v := md5(pg_get_functiondef('booking.public_submit_voucher_claim(uuid,text,text,bigint)'::regprocedure));
  if v not in ('215ea958ea7678094ad350045ad13665', 'de84e5ce9b1062111c4248e7c582fdb8') then ok := false; msg := msg || ' public_submit_voucher_claim=' || v; end if;
  v := md5(pg_get_functiondef('booking.public_update_voucher_claim_code(uuid,bigint,text,text)'::regprocedure));
  if v not in ('fbd67b7fea7ae4fa2349e0099d1748b1', '778fb281381aa026ed3e8afd49431ef6') then ok := false; msg := msg || ' public_update_voucher_claim_code=' || v; end if;
  v := md5(pg_get_functiondef('booking._vc_pay(booking.orders,booking.voucher_claims,numeric)'::regprocedure));
  if v not in ('5166766dabf18f04ea4dae2c6174881b', '3c24fd721b0e8bc6f1bdfb8a800c5a0e') then ok := false; msg := msg || ' _vc_pay=' || v; end if;
  v := md5(pg_get_functiondef('booking._acct_excluded(bigint,bigint)'::regprocedure));
  if v not in ('ca22a722ac7ae9cab1afaef84b9bc216', '4cbe97dbc038d5839453cf90f30525a5') then ok := false; msg := msg || ' _acct_excluded=' || v; end if;
  v := md5(pg_get_functiondef('booking.admin_set_procountor_settings(jsonb)'::regprocedure));
  if v not in ('69142339b6acc7069ae4b559dfc6c75b', '0b67b832a42a1f85fca071a3dc4ac471') then ok := false; msg := msg || ' admin_set_procountor_settings=' || v; end if;
  v := md5(pg_get_functiondef('booking._procountor_daily_build(date,jsonb,jsonb)'::regprocedure));
  if v not in ('c480c6ed3bf001d5ef568fb5678726cc', 'f3e26f0ea30ab0e7a15f18c61aaf661e') then ok := false; msg := msg || ' _procountor_daily_build=' || v; end if;
  if not ok then raise exception 'booking_173 rollback: funktioiden md5 ei ole booking_173:n eikä tuotannon (%); mitään ei muutettu', msg; end if;
end $g$;

-- booking._vc_guess(text) (tuotanto, md5 d1f3d6bcc0779ea2f87b1fef28dfdfe1)
CREATE OR REPLACE FUNCTION booking._vc_guess(p_norm text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select case
    when p_norm ~ '^KK[0-9]{5}[A-Z]{6}$' then jsonb_build_object('source', 'kokemuskauppa', 'confidence', 'high')
    when p_norm ~ '^OK[0-9]{5}[A-Z]{3}$' then jsonb_build_object('source', 'offerilla', 'confidence', 'high')
    when p_norm ~ '^[A-Z0-9]{12}$' and p_norm ~ '[^3479ACEFHJKLMNPRTUVWXY]' then jsonb_build_object('source', 'elamyslahjat', 'confidence', 'medium')
    else jsonb_build_object('source', null, 'confidence', null) end $function$;

-- booking._vc_sources() (tuotanto, md5 7e673c0f8d2a0cb8a49d2ddc98e14c47)
CREATE OR REPLACE FUNCTION booking._vc_sources()
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select '[{"code":"elamyslahjat","label":"Elämyslahjat","label_en":"Elämyslahjat"},{"code":"kokemuskauppa","label":"Kokemuskauppa","label_en":"Kokemuskauppa"},{"code":"kiitoskauppa","label":"Kiitoskauppa","label_en":"Kiitoskauppa"},{"code":"offerilla","label":"Offerilla","label_en":"Offerilla"}]'::jsonb $function$;

-- booking.public_submit_voucher_claim(uuid,text,text,bigint) (tuotanto, md5 215ea958ea7678094ad350045ad13665)
CREATE OR REPLACE FUNCTION booking.public_submit_voucher_claim(p_token uuid, p_code text, p_source text, p_order_item_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o booking.orders; v_norm text := booking.gift_code_norm(p_code); v_src text := lower(btrim(coalesce(p_source, ''))); c booking.voucher_claims; ex booking.voucher_claims; cu booking.customers;
        v_guess jsonb; v_unpaid numeric; v_n int; v_max int; v_res bigint; v_detail text; v_msg text;
begin
  if booking._gc_rl_blocked() then return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen'); end if;
  if not booking._gc_flag('voucher_claims.enabled') then return jsonb_build_object('ok', false, 'code', 'voucher_claims_disabled', 'message', 'Kumppanilahjakorttien lunastus verkossa ei ole vielä käytössä'); end if;
  if p_token is null or not booking._order_rl('vcsub', p_token, 30, 10) then return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen'); end if;
  begin
    select * into o from booking.orders where public_token = p_token for update;
    if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
    if v_src not in ('elamyslahjat', 'kokemuskauppa', 'kiitoskauppa', 'offerilla') then perform booking._err('invalid_source', 'Valitse lahjakortin myyjä (Elämyslahjat, Kokemuskauppa, Kiitoskauppa tai Offerilla)'); end if;
    if v_norm !~ '^[A-Z0-9]{6,24}$' then perform booking._err('invalid_code', 'Tarkista koodi'); end if;
    if o.external_source is not null or o.status not in ('pending', 'confirmed') then perform booking._err('order_not_editable', 'Tilaukselle ei voi kirjata maksua'); end if;
    if o.status = 'pending' and not exists (select 1 from booking.reservations r where r.order_id = o.id and r.status = 'pending' and r.hold_expires_at > now()) then perform booking._err('order_expired', 'Varaus on vanhentunut'); end if;
    if exists (select 1 from booking.order_items oi where oi.order_id = o.id and oi.kind = 'gift_card') then perform booking._err('gift_card_not_allowed', 'Lahjakortilla ei voi ostaa lahjakorttia'); end if;
    if exists (select 1 from booking.gift_cards g where g.code = v_norm and g.status not in ('cancelled', 'pending_payment')) then perform booking._err('use_own_card', 'Koodi on oma lahjakortti: käytä lahjakortin lunastusta'); end if;
    if p_order_item_id is not null and not exists (select 1 from booking.order_items oi where oi.id = p_order_item_id and oi.order_id = o.id) then perform booking._err('invalid_item', 'Tilausriviä ei löydy'); end if;
    v_unpaid := case when o.status = 'pending' then greatest(o.total_gross - (booking._order_balance(o.id) ->> 'net_paid')::numeric, 0) else (booking._order_balance(o.id) ->> 'unpaid')::numeric end;
    if v_unpaid <= 0 then perform booking._err('nothing_to_pay', 'Tilauksella ei ole maksettavaa'); end if;
    -- sama koodi jo aktiivisena tällä tilauksella -> idempotentti; muulla tilauksella tai jo lunastettu -> virhe
    select * into ex from booking.voucher_claims where code = v_norm and status in ('open', 'processing', 'redeemed') limit 1;
    if found then
      if ex.order_id = o.id and ex.status in ('open', 'processing') then
        perform booking._gc_log('ok');
        return jsonb_build_object('ok', true, 'already', true, 'claim_no', ex.id, 'status', 'open', 'source', ex.source, 'source_label', booking._vc_source_label(ex.source), 'code_masked', booking._vc_mask(ex.code), 'hold_until', null);
      end if;
      perform booking._err('code_already_claimed', 'Tämä koodi on jo käytössä toisella varauksella');
    end if;
    select count(*) into v_n from booking.voucher_claims where order_id = o.id and status in ('open', 'processing', 'problem');
    v_max := coalesce((booking._setting('voucher_claims.max_per_order', '10'::jsonb) #>> '{}')::int, 10);
    if v_n >= v_max then perform booking._err('too_many_claims', 'Liian monta lahjakoodia tilauksella'); end if;
    -- ongelmatilassa oleva pyyntö korvataan uudella koodilla/lähteellä
    update booking.voucher_claims set status = 'cancelled', resolved_at = now(), resolved_by = 'customer', notes = concat_ws(E'\n', notes, to_char(now() at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI') || ' customer: korvattu uudella koodilla')
     where order_id = o.id and status = 'problem' and order_item_id is not distinct from p_order_item_id;
    v_guess := booking._vc_guess(v_norm);
    select * into cu from booking.customers where id = o.customer_id;
    select r.id into v_res from booking.reservations r where r.order_id = o.id and r.status in ('pending', 'confirmed') and r.hidden_at is null order by r.starts_at limit 1;
    insert into booking.voucher_claims(order_id, reservation_id, order_item_id, code, source, source_suggested, customer_name, customer_email, customer_phone, locale)
    values (o.id, v_res, p_order_item_id, v_norm, v_src, v_guess ->> 'source', cu.name, cu.email, cu.phone, case when o.locale in ('fi', 'en', 'sv') then o.locale else 'fi' end) returning * into c;
    perform booking._vc_keep_reserved(o.id);   -- booking_48: varaus ei vanhene pyynnön vuoksi (odottava varaus vahvistetaan, maksamaton saldo jää)
    perform booking._enqueue_email('voucher_claim_received', o.id, null, null, 'vcrecv:' || c.id, jsonb_build_object('claim_id', c.id));
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
    if v_detail in ('invalid_code', 'invalid_source', 'not_found') then perform booking._gc_log('invalid'); end if;
    return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;
  perform booking._gc_log('ok');
  return jsonb_build_object('ok', true, 'claim_no', c.id, 'status', 'open', 'source', c.source, 'source_label', booking._vc_source_label(c.source), 'code_masked', booking._vc_mask(c.code),
    'hold_until', null, 'source_mismatch', (c.source_suggested is not null and c.source_suggested <> c.source));
end $function$;

-- booking.public_update_voucher_claim_code(uuid,bigint,text,text) (tuotanto, md5 fbd67b7fea7ae4fa2349e0099d1748b1)
CREATE OR REPLACE FUNCTION booking.public_update_voucher_claim_code(p_token uuid, p_claim_id bigint, p_code text, p_source text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o booking.orders; c booking.voucher_claims; v_norm text := booking.gift_code_norm(p_code); v_src text; v_guess jsonb; v_detail text; v_msg text; v_old text;
begin
  if booking._gc_rl_blocked() then return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen'); end if;
  if p_token is null or not booking._order_rl('vcupd', p_token, 20, 10) then return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen'); end if;
  if not booking._gc_flag('voucher_claims.enabled') then return jsonb_build_object('ok', false, 'code', 'voucher_claims_disabled', 'message', 'Kumppanilahjakorttien lunastus verkossa ei ole vielä käytössä'); end if;
  begin
    select * into o from booking.orders where public_token = p_token for update;
    if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
    select * into c from booking.voucher_claims where id = p_claim_id and order_id = o.id for update;
    if not found then perform booking._err('not_found', 'Lunastuspyyntöä ei löydy'); end if;
    if o.external_source is not null or o.status not in ('pending', 'confirmed') then perform booking._err('order_not_editable', 'Tilaukselle ei voi kirjata maksua'); end if;
    if c.status = 'processing' then perform booking._err('busy', 'Lahjakorttia tarkistetaan juuri nyt – yritä hetken kuluttua uudelleen'); end if;
    if c.status not in ('open', 'problem') then perform booking._err('claim_not_editable', 'Tätä lahjakoodia ei voi enää muuttaa'); end if;
    v_src := lower(btrim(coalesce(nullif(btrim(p_source), ''), c.source)));
    if v_src not in ('elamyslahjat', 'kokemuskauppa', 'kiitoskauppa', 'offerilla') then perform booking._err('invalid_source', 'Valitse lahjakortin myyjä (Elämyslahjat, Kokemuskauppa, Kiitoskauppa tai Offerilla)'); end if;
    if v_norm !~ '^[A-Z0-9]{6,24}$' then perform booking._err('invalid_code', 'Tarkista koodi'); end if;
    if v_norm = c.code and v_src = c.source then perform booking._err('unchanged', 'Koodi ja myyjä ovat samat kuin aiemmin'); end if;
    if exists (select 1 from booking.gift_cards g where g.code = v_norm and g.status not in ('cancelled', 'pending_payment')) then perform booking._err('use_own_card', 'Koodi on oma lahjakortti: käytä lahjakortin lunastusta'); end if;
    if exists (select 1 from booking.voucher_claims x where x.code = v_norm and x.id <> c.id and x.status in ('open', 'processing', 'redeemed')) then perform booking._err('code_already_claimed', 'Tämä koodi on jo käytössä toisella varauksella'); end if;
    v_old := booking._vc_mask(c.code);
    v_guess := booking._vc_guess(v_norm);
    update booking.voucher_claims set code = v_norm, source = v_src, source_suggested = v_guess ->> 'source', status = 'open', problem_code = null, problem_notified_at = null,
           resolved_at = null, resolved_by = null, attempts = 0, last_checked_at = null, hold_until = null,
           notes = concat_ws(E'\n', notes, to_char(now() at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI') || ' customer: koodi korjattu (' || v_old || ' → ' || booking._vc_mask(v_norm) || ', ' || v_src || '), pyyntö avattu uudelleen')
     where id = c.id returning * into c;
    perform booking._vc_keep_reserved(o.id);
  exception
    when unique_violation then perform booking._gc_log('invalid'); return jsonb_build_object('ok', false, 'code', 'code_already_claimed', 'message', 'Tämä koodi on jo käytössä toisella varauksella');
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      if v_detail in ('invalid_code', 'invalid_source', 'not_found') then perform booking._gc_log('invalid'); end if;
      return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;
  perform booking._gc_log('ok');
  return jsonb_build_object('ok', true, 'claim_no', c.id, 'status', 'open', 'public_status', 'received', 'source', c.source, 'source_label', booking._vc_source_label(c.source), 'code_masked', booking._vc_mask(c.code),
    'source_mismatch', (c.source_suggested is not null and c.source_suggested <> c.source));
end $function$;

-- booking._vc_pay(booking.orders,booking.voucher_claims,numeric) (tuotanto, md5 5166766dabf18f04ea4dae2c6174881b)
CREATE OR REPLACE FUNCTION booking._vc_pay(o booking.orders, c booking.voucher_claims, p_value numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_unpaid numeric; v_amt numeric; v_id bigint; v_it record; v_note text;
begin
  if p_value is not null and (p_value < 0 or p_value <> round(p_value, 2)) then perform booking._err('invalid_amount', 'Virheellinen summa'); end if;
  v_unpaid := case when o.status = 'pending' then greatest(o.total_gross - (booking._order_balance(o.id) ->> 'net_paid')::numeric, 0) else (booking._order_balance(o.id) ->> 'unpaid')::numeric end;
  if c.order_item_id is not null then
    select * into v_it from booking._order_uncovered(o.id, false) u where u.item_id = c.order_item_id;
    v_unpaid := least(v_unpaid, coalesce(v_it.remaining, 0));
  end if;
  v_amt := least(coalesce(p_value, v_unpaid), v_unpaid);
  if v_amt <= 0 then return jsonb_build_object('payment_id', null, 'amount', 0); end if;
  v_note := concat_ws(' | ', 'Kumppanin lahjakortti (' || booking._vc_source_label(c.source) || ') ' || booking._vc_mask(c.code), 'pyyntö #' || c.id, c.partner_ref);
  update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'korvattu kumppanilahjakorttimaksulla')
   where order_id = o.id and status = 'pending' and external_source is null
     and ((provider = 'manual' and not exists (select 1 from booking.payment_lines pl where pl.payment_id = payments.id)) or provider <> 'manual');
  insert into booking.payments(order_id, method, provider, status, amount, note, created_by)
  values (o.id, 'partner_voucher', 'manual', 'pending', v_amt, v_note, auth.uid()) returning id into v_id;
  if c.order_item_id is not null then
    insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
    values (v_id, v_it.item_id, v_it.description, v_it.kind, case when v_amt = v_it.remaining then v_it.quantity else 1 end, v_amt, v_it.vat_rate);
  else
    perform booking._alloc_payment_lines(v_id);
  end if;
  update booking.payments set status = 'paid', paid_at = now() where id = v_id;      -- _acct_excluded: ei kuittia / kassaraporttia (oletus)
  perform booking._sync_placeholder(o.id);
  perform booking._refresh_order_payment(o.id);
  update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = o.id and status = 'pending';
  update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()) where id = o.id and status = 'pending';
  return jsonb_build_object('payment_id', v_id, 'amount', v_amt);
end $function$;

-- booking._acct_excluded(bigint,bigint) (tuotanto, md5 ca22a722ac7ae9cab1afaef84b9bc216)
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
          and coalesce((select true from booking.payments p where p.id = p_payment_id and p.method = 'partner_voucher'), false))
$function$;

-- booking.admin_set_procountor_settings(jsonb) (tuotanto, md5 69142339b6acc7069ae4b559dfc6c75b)
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
  methods text[] := array['cash','card_terminal','mobilepay','bank_transfer','invoice','gift_card','partner_voucher','visma_pay','annual_card','pay_later','other'];
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

-- booking._procountor_daily_build(date,jsonb,jsonb) (tuotanto, md5 c480c6ed3bf001d5ef568fb5678726cc)
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

drop trigger if exists payment_methods_partner_sync on booking.payment_methods;
drop function if exists booking._pm_partner_sync();
drop function if exists booking.admin_set_voucher_claim_source(bigint, text);
drop function if exists booking.admin_set_voucher_redeem_urls(jsonb);
drop function if exists booking.admin_mark_voucher_claim_redeemed(bigint, numeric, text, text);
drop function if exists booking.svc_mark_voucher_claim_redeemed(bigint, numeric, text, text);
drop function if exists booking._vc_mark_redeemed(bigint, numeric, text, text, text);
drop function if exists booking.admin_order_voucher_claims(bigint);
drop function if exists booking.admin_unredeemed_voucher_claims(text, integer);
drop function if exists booking._vc_admin_row(booking.voucher_claims);
drop function if exists booking._vc_redeem_url(text);
delete from booking.settings where key = 'voucher_claims.redeem_urls';

do $r$
declare n int;
begin
  update booking.payments set method = 'partner_voucher'
   where method in ('partner_voucher_kokemuskauppa', 'partner_voucher_offerilla', 'partner_voucher_elamyslahjat');
  get diagnostics n = row_count;
  raise notice 'booking_173 rollback: % myyjäkohtaista maksua siirretty maksutavalle partner_voucher', n;
end $r$;
delete from booking.payment_methods where code in ('partner_voucher_kokemuskauppa', 'partner_voucher_offerilla', 'partner_voucher_elamyslahjat');

update booking.integration_config c
   set settings = jsonb_set(c.settings, '{accounts,clearing_by_method}',
         (c.settings #> '{accounts,clearing_by_method}') - 'partner_voucher_kokemuskauppa' - 'partner_voucher_offerilla' - 'partner_voucher_elamyslahjat')
 where c.key = 'procountor' and jsonb_typeof(c.settings #> '{accounts,clearing_by_method}') = 'object'
   and (c.settings #> '{accounts,clearing_by_method}') ?| array['partner_voucher_kokemuskauppa', 'partner_voucher_offerilla', 'partner_voucher_elamyslahjat'];

drop function if exists booking._vc_method(text);
drop function if exists booking._is_partner_method(text);
