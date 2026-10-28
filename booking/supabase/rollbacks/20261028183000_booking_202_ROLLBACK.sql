-- ROLLBACK booking_202. Poistaa osallistujamuistiinpanot, viestilokin ja peruutussarakkeen.
-- Palauttaa email_outbox-lajirajoitteen ilman event_message-arvoa.
-- Korvatut funktiot (admin_event_rule_upsert, _event_rule_json, email_outbox_claim) pitää palauttaa
-- ajamalla uudelleen niiden aiempi määrittely: booking_158 (upsert + _event_rule_json) ja booking_190 (email_outbox_claim),
-- jos tätä rollbackia ajetaan ilman koko ketjun palautusta. Tämä tiedosto pudottaa 202:n omat objektit ja
-- palauttaa _event_rule_jsonin sekä upsertin booking_158:n mukaiseksi siltä osin kuin 202 ne korvasi,
-- ja poistaa event_message-haaran claimista palauttamalla booking_190:n wrapperin.
-- Ei ajeta tästä työtilasta.
set local lock_timeout = '5s';

drop function if exists booking.admin_event_message_send(bigint, bigint, text, text, boolean);
drop function if exists booking.admin_event_messages_list(bigint);
drop function if exists booking.admin_event_participants(bigint, bigint);
drop function if exists booking.admin_event_participant_note_set(bigint, text);
drop function if exists booking.admin_event_occurrence_cancel(bigint);
drop function if exists booking._event_message_blocked(text);

drop trigger if exists reservations_drop_event_note on booking.reservations;
drop function if exists booking.reservations_drop_event_note();
drop table if exists booking.event_participant_notes;
drop table if exists booking.event_messages;
drop index if exists booking.reservations_rule_idx;

-- booking_158: _event_rule_json ilman cancelled_at / reservation_count
create or replace function booking._event_rule_json(p_rule_id bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', r.id, 'product_id', r.product_id, 'kind', r.kind, 'date', r.valid_from, 'start_time', to_char(r.start_time, 'HH24:MI'),
    'duration_minutes', r.duration_minutes,
    'starts_at', (r.valid_from + r.start_time) at time zone booking._tz(),
    'ends_at', ((r.valid_from + r.start_time) + make_interval(mins => r.duration_minutes)) at time zone booking._tz(),
    'max_persons', r.max_persons, 'min_persons', r.min_persons, 'deadline_minutes', r.deadline_minutes,
    'label', r.label, 'label_en', r.label_en, 'active', r.active, 'price_variant_id', r.price_variant_id, 'space_id', r.space_id,
    'pool_id', (select pr.id from booking.resources pr where pr.code = 'event_rule_' || r.id::text),
    'sold_persons', (select coalesce(sum(x.persons), 0)::int from booking.reservations x
                      where x.rule_id = r.id and booking._res_active(x.status, x.hold_expires_at)),
    'waitlist_count', (select count(*)::int from booking.waitlist_entries w where w.rule_id = r.id and w.status in ('waiting', 'notified')),
    'blocks', coalesce((select jsonb_agg(booking._event_block_json(b) order by b.sort_order, b.id)
                          from booking.event_resource_blocks b where b.rule_id = r.id), '[]'::jsonb))
  from booking.schedule_rules r where r.id = p_rule_id
$$;

-- booking_158: admin_event_rule_upsert (aikaa ei siirretä, jos varauksia on)
create or replace function booking.admin_event_rule_upsert(p_id bigint default null, p_product_id bigint default null, p_patch jsonb default '{}'::jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  allowed text[] := array['date','start_time','duration_minutes','max_persons','min_persons','deadline_minutes','label','label_en','active','price_variant_id'];
  k text; r booking.schedule_rules; p kb.products; pc booking.product_config;
  v_date date; v_start time; v_dur integer; v_max integer; v_min integer; v_deadline integer; v_label text; v_label_en text; v_active boolean;
  v_variant bigint; v_space bigint; v_sold integer; v_has_res boolean; v_id bigint; v_auto_label boolean := false;
begin
  perform booking._require_permission('catalog.edit');
  p_patch := coalesce(p_patch, '{}'::jsonb);
  if jsonb_typeof(p_patch) <> 'object' then perform booking._err('invalid_param', 'p_patch puuttuu'); end if;
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata: ' || k); end if;
  end loop;

  if p_id is not null then
    select * into r from booking.schedule_rules where id = p_id for update;
    if not found or r.kind <> 'event' then perform booking._err('not_found', 'Tapahtumakertaa ei löydy'); end if;
    if p_product_id is not null and p_product_id <> r.product_id then perform booking._err('invalid_param', 'Kerta kuuluu toiseen tuotteeseen'); end if;
    p_product_id := r.product_id;
  end if;
  select * into p from kb.products where id = p_product_id;
  if not found then perform booking._err('not_found', 'Tuotetta ei löydy'); end if;
  if p.category not in ('event', 'training') then perform booking._err('not_event', 'Tuote ei ole tapahtuma tai koulutus'); end if;
  select * into pc from booking.product_config where product_id = p.id;
  if not found then perform booking._err('not_found', 'Tuotteen varausasetukset puuttuvat'); end if;

  -- päivä ja aika
  if p_patch ? 'date' then
    if coalesce(p_patch ->> 'date', '') !~ '^\d{4}-\d{2}-\d{2}$' then perform booking._err('invalid_param', 'Päivä muodossa VVVV-KK-PP'); end if;
    begin v_date := (p_patch ->> 'date')::date; exception when others then perform booking._err('invalid_param', 'Virheellinen päivä'); end;
  else v_date := r.valid_from; end if;
  if p_patch ? 'start_time' then
    if coalesce(p_patch ->> 'start_time', '') !~ '^\d{1,2}[:.]\d{2}(:00)?$' then perform booking._err('invalid_param', 'Alkuaika muodossa HH:MM'); end if;
    begin v_start := replace(p_patch ->> 'start_time', '.', ':')::time; exception when others then perform booking._err('invalid_param', 'Virheellinen alkuaika'); end;
  else v_start := r.start_time; end if;
  if v_date is null then perform booking._err('invalid_param', 'Päivä puuttuu'); end if;
  if v_start is null then perform booking._err('invalid_param', 'Alkuaika puuttuu'); end if;

  v_dur := case when p_patch ? 'duration_minutes' then booking._event_jint(p_patch -> 'duration_minutes', 'duration_minutes', 1, 20160)
                else coalesce(r.duration_minutes, pc.duration_minutes, p.duration_minutes) end;
  if v_dur is null then perform booking._err('invalid_param', 'Kesto puuttuu'); end if;
  if v_dur > 1440 and p.category <> 'training' then
    perform booking._err('multi_day_training_only', 'Monipäiväinen kerta (yksi lippu) on sallittu vain koulutuksille');
  end if;
  v_max := case when p_patch ? 'max_persons' then booking._event_jint(p_patch -> 'max_persons', 'max_persons', 1, 1000)
                when p_id is not null then r.max_persons else pc.max_persons end;
  v_min := coalesce(case when p_patch ? 'min_persons' then booking._event_jint(p_patch -> 'min_persons', 'min_persons', 1, 1000) end,
                    r.min_persons, pc.min_persons, 1);
  if v_max is not null and v_min > v_max then perform booking._err('invalid_param', 'Vähimmäismäärä on suurempi kuin enimmäismäärä'); end if;
  v_deadline := coalesce(case when p_patch ? 'deadline_minutes' then booking._event_jint(p_patch -> 'deadline_minutes', 'deadline_minutes', 0, 43200) end,
                         r.deadline_minutes, 0);
  v_active := coalesce(case when p_patch ? 'active' then booking._event_jbool(p_patch -> 'active', 'active') end, r.active, true);
  if p_patch ? 'price_variant_id' then
    v_variant := booking._event_jint(p_patch -> 'price_variant_id', 'price_variant_id', 1, 2000000000);
    if v_variant is not null and not exists (select 1 from kb.product_price_variants v where v.id = v_variant and v.product_id = p.id) then
      perform booking._err('invalid_param', 'Hintavaihtoehto ei kuulu tuotteeseen');
    end if;
  else v_variant := r.price_variant_id; end if;
  if p_patch ? 'label' then v_label := nullif(btrim(coalesce(p_patch ->> 'label', '')), ''); else v_label := r.label; end if;
  if v_label is null
     or (p_id is not null and not (p_patch ? 'label') and r.label = to_char(r.valid_from, 'DD.MM.YYYY') || ' klo ' || to_char(r.start_time, 'HH24.MI')) then
    v_label := to_char(v_date, 'DD.MM.YYYY') || ' klo ' || to_char(v_start, 'HH24.MI');
    v_auto_label := true;
  end if;
  if char_length(v_label) > 200 then perform booking._err('invalid_param', 'Nimi on liian pitkä'); end if;
  if p_patch ? 'label_en' then v_label_en := nullif(btrim(coalesce(p_patch ->> 'label_en', '')), ''); else v_label_en := r.label_en; end if;
  if v_label_en is not null and char_length(v_label_en) > 200 then perform booking._err('invalid_param', 'Englanninkielinen nimi on liian pitkä'); end if;

  if p_id is null then
    select id into v_space from booking.resources where code = 'ei_resurssia';
    if v_space is null then perform booking._err('not_found', 'Resurssia ei_resurssia ei löydy'); end if;
    insert into booking.schedule_rules(product_id, label, label_en, mode, space_id, weekdays, start_time, duration_minutes, valid_from, valid_to,
                                       min_persons, max_persons, price_mode, price_variant_id, deadline_minutes, active, sort_order, kind, notes)
    values (p.id, v_label, v_label_en, 'shared', v_space, array[extract(isodow from v_date)::smallint], v_start, v_dur, v_date, v_date,
            v_min, v_max, 'per_person', v_variant, v_deadline, v_active, 100, 'event', 'booking_158: tapahtumakerta')
    returning id into v_id;
  else
    select coalesce(sum(x.persons), 0)::int, count(*) > 0 into v_sold, v_has_res
      from booking.reservations x where x.rule_id = r.id and booking._res_active(x.status, x.hold_expires_at);
    if v_has_res and ((v_date, v_start, v_dur) is distinct from (r.valid_from, r.start_time, r.duration_minutes) or (r.active and not v_active)) then
      perform booking._err('has_reservations', 'Kerralla on varauksia: aikaa ei voi muuttaa eikä kertaa passivoida');
    end if;
    if coalesce(v_max, pc.max_persons) is not null and coalesce(v_max, pc.max_persons) < v_sold then
      perform booking._err('max_below_sold', format('Enimmäismäärä ei voi olla pienempi kuin myydyt paikat (%s)', v_sold));
    end if;
    update booking.schedule_rules
       set label = v_label, label_en = v_label_en, weekdays = array[extract(isodow from v_date)::smallint], start_time = v_start,
           duration_minutes = v_dur, valid_from = v_date, valid_to = v_date, min_persons = v_min, max_persons = v_max,
           price_variant_id = v_variant, deadline_minutes = v_deadline, active = v_active
     where id = r.id;
    v_id := r.id;
  end if;

  perform booking._event_rule_pool_sync(v_id);
  perform booking._event_sync_blocks(v_id);
  perform booking._event_raise_conflicts(v_id);
  perform booking._texts_register_sources();
  return booking._event_rule_json(v_id);
end $$;

-- booking_190: email_outbox_claim ilman event_message-haaraa
CREATE OR REPLACE FUNCTION booking.email_outbox_claim(p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(case when z.item->>'kind' = 'annual_card_code'
    then z.item || jsonb_build_object('annual_card', booking._annual_card_mail((z.item->>'id')::bigint))
                || coalesce(booking._annual_card_admin_to((z.item->>'id')::bigint), '{}'::jsonb)
    when z.item->>'kind' = 'payment_link'
    then z.item || coalesce((select jsonb_build_object('voucher_difference', jsonb_build_object('total', e.payload -> 'total', 'voucher_value', e.payload -> 'voucher_value', 'difference', e.payload -> 'difference'))
                               from booking.email_outbox e where e.id = (z.item->>'id')::bigint and e.payload ->> 'variant' = 'voucher_difference'), '{}'::jsonb)
    when z.item->>'kind' = 'voucher_claim_received'
    then z.item || coalesce((select jsonb_build_object('order', (z.item->'order') || jsonb_build_object('instructions', booking._order_short_instructions(e.order_id, coalesce(nullif(e.locale, ''), o.locale, 'fi'))))
                               from booking.email_outbox e join booking.orders o on o.id = e.order_id where e.id = (z.item->>'id')::bigint and jsonb_typeof(z.item->'order') = 'object'), '{}'::jsonb)
                || coalesce((select jsonb_build_object('voucher_claim', jsonb_build_object('claim_id', vc.id, 'status', vc.status, 'source', vc.source, 'code_masked', booking._vc_mask(vc.code), 'problem_code', vc.problem_code,
                                   'hold_until', vc.hold_until, 'created_at', vc.created_at, 'customer_name', vc.customer_name))
                               from booking.email_outbox e join booking.voucher_claims vc on vc.order_id = e.order_id
                              where e.id = (z.item->>'id')::bigint and coalesce(z.item #>> '{voucher_claim,status}', 'cancelled') in ('cancelled', 'expired')
                                and vc.status in ('open', 'processing', 'problem', 'redeemed')
                              order by vc.created_at, vc.id limit 1), '{}'::jsonb)
    when z.item->>'kind' = 'unpaid_booking_cancelled'
    then z.item || coalesce((select jsonb_build_object('unpaid_booking', jsonb_strip_nulls(jsonb_build_object(
                  'retry_url', e.payload ->> 'retry_url',
                  'product_name', case when e.locale = 'en' then coalesce(nullif(e.payload ->> 'product_name_en', ''), e.payload ->> 'product_name') else e.payload ->> 'product_name' end,
                  'starts_at', e.payload -> 'starts_at')))
                from booking.email_outbox e where e.id = (z.item->>'id')::bigint), '{}'::jsonb)
    else z.item end order by z.ord), '[]'::jsonb)
  from jsonb_array_elements(booking.email_outbox_claim_base_146(p_limit)) with ordinality as z(item, ord);
$function$;

alter table booking.schedule_rules drop column if exists cancelled_at;

do $k$
declare def text; expr text;
begin
  select pg_get_constraintdef(c.oid) into def
    from pg_constraint c
   where c.conrelid = 'booking.email_outbox'::regclass and c.conname = 'email_outbox_kind_check';
  if def is null or position('event_message' in def) = 0 then return; end if;
  expr := regexp_replace(def, '''event_message''::text,\s*', '', 'g');
  if position('event_message' in expr) > 0 then
    raise exception 'booking_202 rollback: event_message jäi rajoitteeseen';
  end if;
  execute 'alter table booking.email_outbox drop constraint email_outbox_kind_check';
  execute 'alter table booking.email_outbox add constraint email_outbox_kind_check ' || expr;
end $k$;
