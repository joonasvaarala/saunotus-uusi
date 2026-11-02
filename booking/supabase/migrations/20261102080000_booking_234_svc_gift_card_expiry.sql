-- booking_234: asiakaspalvelubotti pidentää oman tai Johku-lahjakortin voimassaoloa.
-- Joonas 2.11.2026: botti saa pidentää omia kortteja (source native + issuer own, ja Johku-kortteja
-- source/issuer johku) ilman erillistä lupaa, jos kortti on vanhentunut alle 12 kuukautta sitten.
-- Kumppanikortit (Elämyslahjat, Kokemuskauppa, Offerilla, muu issuer) eivät kuulu tähän.
-- Sama kirjaus kuin admin_set_gift_card_expiry: gift_card_ledger reason expiry_change (delta 0)
-- ja audit_log-rivi. Ei giftcards.manage-tarkistusta: vain service_role.
-- Tänään on booking._gc_today() (Europe/Helsinki), sama kello kuin admin_set_gift_card_expiry,
-- jotta 12 kk:n ikkuna ja tilan vaihto eivät eriä keskiyön ympärillä.
-- Rollback: rollbacks/20261102080000_booking_234_ROLLBACK.sql

set local lock_timeout = '5s';
set local statement_timeout = '60s';

create or replace function booking.svc_set_gift_card_expiry(
  p_gift_card_id bigint,
  p_valid_to date,
  p_note text,
  p_actor text default 'asiakaspalvelu-bot'
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  g booking.gift_cards;
  v_status text;
  v_today date;
  v_min date;
  v_max date;
  v_actor text;
  v_note text;
  v_old date;
begin
  v_today := booking._gc_today();
  v_min := (v_today - interval '12 months')::date;
  v_max := (v_today + interval '12 months')::date;
  v_actor := coalesce(nullif(btrim(p_actor), ''), 'asiakaspalvelu-bot');
  v_note := nullif(btrim(coalesce(p_note, '')), '');

  if p_gift_card_id is null then
    perform booking._err('not_found', 'Korttia ei löydy');
  end if;
  select * into g from booking.gift_cards where id = p_gift_card_id for update;
  if not found then
    perform booking._err('not_found', 'Korttia ei löydy');
  end if;
  if not ((g.source = 'native' and g.issuer = 'own') or (g.source = 'johku' and g.issuer = 'johku')) then
    perform booking._err('partner_card', 'Vain oman tai Johku-lahjakortin voimassaoloa voi pidentää');
  end if;
  if g.status in ('cancelled', 'pending_payment') then
    perform booking._err('gift_card_inactive', 'Mitätöidyn tai maksamattoman kortin voimassaoloa ei voi pidentää');
  end if;
  if g.balance <= 0 then
    perform booking._err('gift_card_used', 'Käytettyä korttia (saldo 0) ei voi pidentää');
  end if;
  if g.valid_to is null then
    perform booking._err('missing_valid_to', 'Kortilla ei ole voimassaolon päättymispäivää');
  end if;
  if g.valid_to < v_min then
    perform booking._err('expired_too_old', 'Kortti on vanhentunut yli 12 kuukautta sitten');
  end if;
  if v_note is null then
    perform booking._err('note_required', 'Anna syy (p_note)');
  end if;
  if p_valid_to is null or p_valid_to <= v_today then
    perform booking._err('invalid_date', 'Uuden voimassaolon on oltava tuleva päivä');
  end if;
  if p_valid_to <= g.valid_to then
    perform booking._err('not_extended', 'Uuden voimassaolon on oltava nykyistä myöhempi');
  end if;
  if p_valid_to > v_max then
    perform booking._err('extends_too_far', 'Voimassaoloa voi pidentää enintään 12 kuukautta tästä päivästä');
  end if;

  v_old := g.valid_to;
  v_status := g.status;
  if g.status in ('active', 'used', 'expired') then
    v_status := case
      when g.balance = 0 then 'used'
      when p_valid_to < v_today then 'expired'
      else 'active'
    end;
  end if;

  update booking.gift_cards set valid_to = p_valid_to, status = v_status where id = g.id;
  insert into booking.gift_card_ledger(gift_card_id, delta, balance_after, reason, created_by, note, old_valid_to, new_valid_to)
  values (g.id, 0, g.balance, 'expiry_change', auth.uid(), v_note, v_old, p_valid_to);
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (
    auth.uid(),
    coalesce(booking._jwt_role(), 'service_role'),
    'gift_cards',
    g.id::text,
    'SVC_SET_GIFT_CARD_EXPIRY',
    jsonb_build_object('valid_to', v_old, 'status', g.status),
    jsonb_build_object('valid_to', p_valid_to, 'status', v_status, 'note', v_note, 'actor', v_actor)
  );

  return jsonb_build_object(
    'ok', true,
    'id', g.id,
    'old_valid_to', v_old,
    'new_valid_to', p_valid_to,
    'status', v_status,
    'balance', g.balance
  );
end
$fn$;

create or replace function booking.svc_set_gift_card_expiry(
  p_code text,
  p_valid_to date,
  p_note text,
  p_actor text default 'asiakaspalvelu-bot'
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_id bigint;
  v_norm text := booking.gift_code_norm(p_code);
begin
  if v_norm is null or v_norm = '' then
    perform booking._err('not_found', 'Korttia ei löydy');
  end if;
  select g.id into v_id from booking.gift_cards g where g.code = v_norm;
  if not found then
    perform booking._err('not_found', 'Korttia ei löydy');
  end if;
  return booking.svc_set_gift_card_expiry(v_id, p_valid_to, p_note, p_actor);
end
$fn$;

revoke all on function booking.svc_set_gift_card_expiry(bigint, date, text, text) from public, anon, authenticated;
grant execute on function booking.svc_set_gift_card_expiry(bigint, date, text, text) to service_role;

revoke all on function booking.svc_set_gift_card_expiry(text, date, text, text) from public, anon, authenticated;
grant execute on function booking.svc_set_gift_card_expiry(text, date, text, text) to service_role;

comment on function booking.svc_set_gift_card_expiry(bigint, date, text, text) is
  'booking_234: service_role pidentää oman (native/own) tai Johku-lahjakortin voimassaoloa. Ei kumppanikortteja, ei giftcards.manage-tarkistusta. Saldo ennallaan, ledger expiry_change, audit SVC_SET_GIFT_CARD_EXPIRY.';

comment on function booking.svc_set_gift_card_expiry(text, date, text, text) is
  'booking_234: sama kuin svc_set_gift_card_expiry(bigint, date, text, text), haku normalisoidulla koodilla. service_role.';
