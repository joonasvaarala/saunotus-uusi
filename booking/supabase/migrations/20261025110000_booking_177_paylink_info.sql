-- booking_177: maksulinkkisivun yhteenveto ennen maksua (omistaja Joonas 25.10.2026). Uusi julkinen vain luku -RPC booking.public_payment_link_info(uuid) → jsonb.
-- /maksa/?p=<link_token> ja /en/pay/?p= näyttävät ennen painiketta: maksettava summa, tilausnumero, rivit (tuote, pvm, klo Europe/Helsinki), linkin voimassaolo
-- ja selkeän tilan (open / paid / expired / replaced / not_payable / not_found + kieletön syykoodi). Maksun aloitus ennallaan (vismapay-start, link_token).
--   * SECURITY DEFINER, search_path '', anon/authenticated/service_role (PUBLIC ei). Ei muuta tilauksia eikä maksuja; ainoa kirjoitus on yhteinen nopeusrajoitin
--     booking._order_rl('pli', token, rl_order_get_per_10min, rl_order_get_per_10min) kuten public_get_order (IP + token, 10 min).
--   * Vain vähimmäistiedot: EI asiakkaan nimeä, sähköpostia, puhelinta, osoitetta, muistiinpanoja, tilauksen tokenia eikä maksuvälittäjän tunnisteita.
--   * Tuntematon / puuttuva token → aina sama {ok, status: not_found, reason: not_found, can_pay: false} (ei muuta tietoa).
--   * Tilan päättely seuraa vismapay_payment_prepare-funktion linkkihaaraa (sama järjestys); lisäksi korvattu linkki (uudempi Visma-maksu samalla tilauksella)
--     ja muulla tavalla maksettu tilaus tunnistetaan.
--   uusi funktio:
--     booking.public_payment_link_info(uuid): 1fb6153b39daa6f1055c93cac7cb4563
--   riippuvuudet, ei muuteta (tuotanto = vaadittu, luettu sxbofnuisemspgquoxyv 25.10.2026 SELECTillä):
--     booking.vismapay_payment_prepare(uuid,uuid) 703c03c301f5a3008192cdbe65e559e2
--     booking._create_link_payment(bigint,integer,text) 533ac9af831c0c11e1f504e377a17827
--     booking._order_rl(text,uuid,integer,integer) ec6bf13a3694e5bf9034a80123857246
--     booking._rate_limit(text,integer,interval) 7c8076d29d82d72db797066fd44d06c1
--     booking._client_ip() 8c8e7d145566db576d33037a941ce81f
--     booking._order_balance(bigint) a6b31f93559de53d75a52d8a285f1170
--     booking._vismapay_mode() 6d7d56a83470d01e954a78e8767e8366
--     booking._setting(text,jsonb) 70fcfa245e9e7d070dae7a6c1e90ce4d
-- Rollback: rollbacks/20261025110000_booking_177_ROLLBACK.sql. Testi: tests/checkout/t177_payment_link_info.sql (BEGIN … ROLLBACK).
set local lock_timeout = '5s';

do $g$
declare v text; ok boolean := true; msg text := '';
begin
  v := md5(pg_get_functiondef(to_regprocedure('booking.vismapay_payment_prepare(uuid,uuid)')));
  if v is null or v <> '703c03c301f5a3008192cdbe65e559e2' then ok := false; msg := msg || ' vismapay_payment_prepare=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._create_link_payment(bigint,integer,text)')));
  if v is null or v <> '533ac9af831c0c11e1f504e377a17827' then ok := false; msg := msg || ' _create_link_payment=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._order_rl(text,uuid,integer,integer)')));
  if v is null or v <> 'ec6bf13a3694e5bf9034a80123857246' then ok := false; msg := msg || ' _order_rl=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._rate_limit(text,integer,interval)')));
  if v is null or v <> '7c8076d29d82d72db797066fd44d06c1' then ok := false; msg := msg || ' _rate_limit=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._client_ip()')));
  if v is null or v <> '8c8e7d145566db576d33037a941ce81f' then ok := false; msg := msg || ' _client_ip=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._order_balance(bigint)')));
  if v is null or v <> 'a6b31f93559de53d75a52d8a285f1170' then ok := false; msg := msg || ' _order_balance=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._vismapay_mode()')));
  if v is null or v <> '6d7d56a83470d01e954a78e8767e8366' then ok := false; msg := msg || ' _vismapay_mode=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._setting(text,jsonb)')));
  if v is null or v <> '70fcfa245e9e7d070dae7a6c1e90ce4d' then ok := false; msg := msg || ' _setting=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_payment_link_info(uuid)')));
  if v is not null and v <> '1fb6153b39daa6f1055c93cac7cb4563' then ok := false; msg := msg || ' public_payment_link_info=' || v; end if;
  if (select data_type from information_schema.columns where table_schema = 'kb' and table_name = 'products' and column_name = 'name_en') is distinct from 'text'
     or (select data_type from information_schema.columns where table_schema = 'booking' and table_name = 'addons' and column_name = 'name_en') is distinct from 'text' then
    ok := false; msg := msg || ' name_en-sarake puuttuu';
  end if;
  if not ok then raise exception 'booking_177: tuotannon määrittelyt eivät vastaa odotettua:%. Ei muutoksia.', msg; end if;
end $g$;

drop function if exists booking.public_payment_link_info(uuid);
create function booking.public_payment_link_info(p_token uuid)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
-- booking_177: maksulinkkisivun (/maksa/?p=, /en/pay/?p=) yhteenveto ENNEN maksun aloitusta. Vain luku (ei muuta tilausta eikä maksua; ainoa kirjoitus
-- on yhteinen nopeusrajoitin _order_rl). Palauttaa vain vähimmäistiedot: tila + kieletön syykoodi, summa, valuutta, tilausnumero, rivit (nimi, pvm, klo
-- Europe/Helsinki) ja voimassaolo. EI asiakkaan nimeä, sähköpostia, puhelinta, osoitetta, muistiinpanoja, tilauksen tokenia eikä maksuvälittäjän tunnisteita.
-- Tila seuraa vismapay_payment_prepare-funktion linkkihaaran tarkistuksia (sama järjestys), joten "open" = painike voi käynnistää maksun.
--   open | paid (link_paid, order_paid) | expired (link_expired, payment_cancelled, payment_not_pending) | replaced (replaced, link_stale)
--   not_payable (other_provider_started, order_not_payable, vismapay_off) | not_found (tuntematon tai puuttuva token; ei muita tietoja)
declare
  pay booking.payments; o booking.orders;
  v_ip_max int; v_unpaid numeric; v_paid_any boolean; v_newer boolean; v_mode text;
  v_status text; v_reason text; v_items jsonb;
begin
  v_ip_max := coalesce((booking._setting('rl_order_get_per_10min', '60'::jsonb) #>> '{}')::int, 60);
  if not booking._order_rl('pli', p_token, v_ip_max, v_ip_max) then
    return jsonb_build_object('ok', false, 'code', 'rate_limited');
  end if;
  if p_token is not null then
    select * into pay from booking.payments where link_token = p_token;
  end if;
  if pay.id is null then
    return jsonb_build_object('ok', true, 'status', 'not_found', 'reason', 'not_found', 'can_pay', false);
  end if;
  select * into o from booking.orders where id = pay.order_id;

  v_unpaid := coalesce((booking._order_balance(o.id) ->> 'unpaid')::numeric, 0);
  v_paid_any := exists (select 1 from booking.payments x where x.order_id = o.id and x.status in ('paid', 'partially_refunded', 'refunded'));
  -- korvattu: tilaukselle on kirjattu tämän jälkeen uusi maksu tai maksulinkki (_create_link_payment / admin_record_payment perui tämän)
  v_newer := exists (select 1 from booking.payments x where x.order_id = o.id and x.id > pay.id);
  v_mode := booking._vismapay_mode();

  if pay.status in ('paid', 'partially_refunded', 'refunded') then
    v_status := 'paid'; v_reason := 'link_paid';
  elsif pay.status <> 'pending' then
    if v_unpaid <= 0.004 and v_paid_any then v_status := 'paid'; v_reason := 'order_paid';
    elsif v_newer then v_status := 'replaced'; v_reason := 'replaced';
    elsif pay.link_expires_at is not null and pay.link_expires_at < now() then v_status := 'expired'; v_reason := 'link_expired';
    elsif pay.provider_status in ('failed', 'cancelled') then v_status := 'expired'; v_reason := 'payment_cancelled';
    else v_status := 'expired'; v_reason := 'payment_not_pending'; end if;
  elsif pay.provider = 'mobilepay' and pay.provider_ref is not null then
    v_status := 'not_payable'; v_reason := 'other_provider_started';
  elsif pay.link_expires_at is not null and pay.link_expires_at < now() then
    if v_unpaid <= 0.004 and v_paid_any then v_status := 'paid'; v_reason := 'order_paid';
    elsif v_newer then v_status := 'replaced'; v_reason := 'replaced';
    else v_status := 'expired'; v_reason := 'link_expired'; end if;
  elsif pay.amount > v_unpaid + 0.004 then
    if v_unpaid <= 0.004 and v_paid_any then v_status := 'paid'; v_reason := 'order_paid';
    else v_status := 'replaced'; v_reason := 'link_stale'; end if;
  elsif o.external_source is not null or o.status not in ('pending', 'confirmed', 'completed', 'expired') or o.currency <> 'EUR'
     or o.payment_status = 'invoiced' or o.customer_kind = 'company'
     or (o.status = 'pending' and o.hold_kind = 'preliminary') then
    v_status := 'not_payable'; v_reason := 'order_not_payable';
  elsif v_mode is null or v_mode not in ('test', 'live') then
    v_status := 'not_payable'; v_reason := 'vismapay_off';
  else
    v_status := 'open'; v_reason := 'open';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', it.kind,
           'name', it.product_name,
           'name_en', nullif(btrim(coalesce(ad.name_en, kp.name_en, '')), ''),
           'quantity', it.quantity,
           'date', to_char(r.starts_at at time zone 'Europe/Helsinki', 'YYYY-MM-DD'),
           'start', to_char(r.starts_at at time zone 'Europe/Helsinki', 'HH24:MI'),
           'end', to_char(r.ends_at at time zone 'Europe/Helsinki', 'HH24:MI'),
           'end_date', to_char(r.ends_at at time zone 'Europe/Helsinki', 'YYYY-MM-DD'))
         order by coalesce(it.parent_item_id, it.id), it.parent_item_id is not null, r.starts_at nulls last, it.id), '[]'::jsonb)
    into v_items
    from booking.order_items it
    left join kb.products kp on kp.id = it.product_id and it.kind in ('reservation', 'product')
    left join booking.addons ad on ad.id = it.addon_id
    left join booking.reservations r on r.order_item_id = it.id and r.order_id = it.order_id and r.hidden_at is null and r.status <> 'cancelled'
   where it.order_id = o.id and it.kind <> 'discount';

  return jsonb_build_object(
    'ok', true, 'status', v_status, 'reason', v_reason, 'can_pay', v_status = 'open',
    'amount', pay.amount, 'amount_cents', round(pay.amount * 100)::bigint, 'currency', pay.currency,
    'order_no', o.order_no, 'order_total', o.total_gross,
    'expires_at', pay.link_expires_at,
    'expires_date', to_char(pay.link_expires_at at time zone 'Europe/Helsinki', 'YYYY-MM-DD'),
    'expires_time', to_char(pay.link_expires_at at time zone 'Europe/Helsinki', 'HH24:MI'),
    'paid_at', case when v_reason = 'link_paid' then pay.paid_at end,
    'items', v_items);
end $function$;

revoke all on function booking.public_payment_link_info(uuid) from public;
grant execute on function booking.public_payment_link_info(uuid) to anon, authenticated, service_role;

do $v$
begin
  if md5(pg_get_functiondef('booking.public_payment_link_info(uuid)'::regprocedure)) <> '1fb6153b39daa6f1055c93cac7cb4563' then raise exception 'booking_177: public_payment_link_info md5 ei vastaa odotettua'; end if;
  if exists (select 1 from pg_proc p, aclexplode(p.proacl) a where p.oid = 'booking.public_payment_link_info(uuid)'::regprocedure and a.grantee = 0) then raise exception 'booking_177: PUBLIC-oikeus jäi'; end if;
  if not has_function_privilege('anon', 'booking.public_payment_link_info(uuid)', 'execute') then raise exception 'booking_177: anon ei saa kutsua'; end if;
end $v$;
