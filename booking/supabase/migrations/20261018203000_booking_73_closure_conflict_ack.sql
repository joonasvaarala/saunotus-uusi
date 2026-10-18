-- ============================================================
-- booking_73_closure_conflict_ack: sulkukonfliktin kuittaus (ei muuta saatavuutta)
--
-- Joonaksen päätös: savusaunan sulku vs. varaus voi olla ei-todellinen
-- (sulku on tehty käsin Johkussa perinnesaunotusillan takia tai koska
-- varausta ei ollut vahvistettu). Kuittaus piilottaa parin Tarkista-listan
-- Sulkukonfliktit-osiosta. Sulku, varaus ja saatavuus jäävät ennalleen.
--
-- Ei käytetä admin_set_closure_override('ignore') eikä reservations.override_reason:
-- ne muuttavat saatavuutta tai siirtävät varauksen Ylitykset-osioon.
--
-- Kuittaus vanhenee, jos sulun alku/loppu tai closure_events.content_hash muuttuu.
-- _reconcile_closure_blocks ei koske tätä taulua: sama sulku (sama block_id ja
-- sama allekirjoitus) säilyttää kuittauksen.
--
-- Oikeus: blocks.manage TAI bookings.override (molemmat ovat käytössä;
-- blocks.manage = sulkujen hallinta, bookings.override = ylitykset).
-- Suora SQL postgres/supabase_admin/service_role ilman JWT:tä saa ajaa bulk-kuittausta.
--
-- Rollback: rollbacks/20261018203000_booking_73_ROLLBACK.sql
-- Testi: tests/73_closure_conflict_ack.test.sql
-- ============================================================
set local lock_timeout = '5s';
set local search_path = booking, extensions, public;

-- ---------- kuittaukset (yksi voimassa oleva rivi / varaus+sulku) ----------
create table booking.closure_conflict_acks (
  id                bigint generated always as identity primary key,
  reservation_id    bigint not null references booking.reservations(id) on delete cascade,
  block_id          bigint not null references booking.space_blocks(id) on delete cascade,
  closure_event_id  bigint references booking.closure_events(id) on delete set null,
  block_signature   text not null check (char_length(block_signature) >= 3),
  ack_reason        text not null check (char_length(btrim(ack_reason)) >= 3),
  acked_by_label    text,
  acked_by_uid      uuid,
  acked_at          timestamptz not null default now(),
  revoked_at        timestamptz
);
comment on table booking.closure_conflict_acks is
  'Sulkukonfliktin kuittaus (booking_73). Ei muuta space_blocks-, closure_events- eikä reservations-riviä. Voimassa kun revoked_at is null ja block_signature täsmää sulun nykyiseen allekirjoitukseen.';
comment on column booking.closure_conflict_acks.block_signature is
  't:<alku-epoch>|<loppu-epoch> ja kalenterisululla lisäksi |h:<content_hash>. Eri allekirjoitus = kuittaus ei ole voimassa.';

create unique index closure_conflict_acks_open_uq
  on booking.closure_conflict_acks (reservation_id, block_id)
  where revoked_at is null;
create index closure_conflict_acks_block_idx on booking.closure_conflict_acks (block_id);
create index closure_conflict_acks_res_idx on booking.closure_conflict_acks (reservation_id);

alter table booking.closure_conflict_acks enable row level security;
revoke all on booking.closure_conflict_acks from public, anon, authenticated;
revoke all on sequence booking.closure_conflict_acks_id_seq from public, anon, authenticated;
grant all on booking.closure_conflict_acks to service_role;
grant all on sequence booking.closure_conflict_acks_id_seq to service_role;
-- Ei politiikkaa eikä SELECT/INSERT-oikeutta anonille tai authenticatedille: kirjoitus vain RPC:llä.

select booking._add_audit('booking.closure_conflict_acks');

-- ---------- allekirjoitus: sulun ajat, kalenterisululla myös content_hash ----------
create or replace function booking._block_conflict_signature(p_block_id bigint)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select 't:' || trunc(extract(epoch from b.starts_at))::bigint::text
         || '|' || trunc(extract(epoch from b.ends_at))::bigint::text
         || case when ev.content_hash is not null and btrim(ev.content_hash) <> ''
                 then '|h:' || ev.content_hash else '' end
    from booking.space_blocks b
    left join booking.closure_events ev on ev.id = b.closure_event_id
   where b.id = p_block_id
$$;

-- Avoimet sulkukonfliktit (sama joukko kuin aiempi admin_review_list.block_conflicts, ennen kuittausta).
create or replace function booking._block_conflict_pairs()
returns table (
  reservation_id bigint,
  leg_id bigint,
  resource_id bigint,
  block_id bigint,
  closure_event_id bigint,
  claim_start timestamptz,
  claim_end timestamptz,
  block_reason text,
  closure_reason text,
  calendar_name text,
  block_signature text
)
language sql
stable
security definer
set search_path = ''
as $$
  select c.reservation_id, c.leg_id, c.resource_id, b.id, b.closure_event_id,
         c.claim_start, c.claim_end, b.reason, ev.reason, cal.name,
         booking._block_conflict_signature(b.id)
    from booking.v_claims c
    join booking.space_blocks b
      on b.active and b.space_id = c.resource_id
     and b.during && tstzrange(c.claim_start, c.claim_end, '[)')
    left join booking.closure_events ev on ev.id = b.closure_event_id
    left join booking.closure_calendars cal on cal.code = ev.calendar_code
   where not c.is_override
     and booking._res_active(c.status, c.hold_expires_at)
     and c.claim_end > now()
$$;

create or replace function booking._require_closure_ack()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  -- Suora SQL-editori / palvelurooli: bulk-ajo ilman selainistuntoa.
  if booking._jwt_role() is null and current_user in ('postgres', 'supabase_admin', 'service_role') then
    return;
  end if;
  if coalesce(booking._jwt_role(), '') = 'service_role' then
    return;
  end if;
  if not booking.is_staff() then
    perform booking._err('forbidden', 'Ei oikeuksia');
  end if;
  if not (booking.has_permission('blocks.manage') or booking.has_permission('bookings.override')) then
    perform booking._err('forbidden', 'Ei oikeutta tähän toimintoon (blocks.manage tai bookings.override)');
  end if;
end $$;

create or replace function booking._audit_closure_ack(p_action text, p_id bigint, p_data jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
  values (auth.uid(), booking._jwt_role(), 'closure_conflict_acks', p_id::text, p_action, p_data);
end $$;

-- ---------- yksi pari ----------
create or replace function booking.admin_ack_block_conflict(
  p_reservation_id bigint,
  p_block_id bigint,
  p_note text,
  p_label text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_note text := btrim(coalesce(p_note, ''));
  v_label text := nullif(left(btrim(coalesce(p_label, '')), 200), '');
  v_sig text;
  v_ev bigint;
  v_existing booking.closure_conflict_acks;
  v_id bigint;
begin
  perform booking._require_closure_ack();
  if char_length(v_note) < 3 then
    perform booking._err('note_required', 'Kuittaus vaatii perustelun (vähintään 3 merkkiä)');
  end if;
  if p_reservation_id is null or p_block_id is null then
    perform booking._err('not_found', 'Varaus tai sulku puuttuu');
  end if;
  if not exists (
    select 1 from booking._block_conflict_pairs() p
     where p.reservation_id = p_reservation_id and p.block_id = p_block_id
  ) then
    perform booking._err('no_conflict', 'Sulkukonfliktia ei ole tälle varaukselle ja sululle');
  end if;
  v_sig := booking._block_conflict_signature(p_block_id);
  if v_sig is null then
    perform booking._err('not_found', 'Sulkua ei löydy');
  end if;
  select b.closure_event_id into v_ev from booking.space_blocks b where b.id = p_block_id;

  perform pg_advisory_xact_lock(hashtextextended('booking:closure_ack:' || p_reservation_id::text || ':' || p_block_id::text, 0));
  select * into v_existing
    from booking.closure_conflict_acks
   where reservation_id = p_reservation_id and block_id = p_block_id and revoked_at is null
   for update;
  if found and v_existing.block_signature = v_sig then
    return jsonb_build_object('ok', true, 'already', true, 'id', v_existing.id,
      'reservation_id', p_reservation_id, 'block_id', p_block_id);
  end if;
  if found then
    update booking.closure_conflict_acks set revoked_at = now() where id = v_existing.id;
  end if;
  insert into booking.closure_conflict_acks(
    reservation_id, block_id, closure_event_id, block_signature, ack_reason, acked_by_label, acked_by_uid
  ) values (
    p_reservation_id, p_block_id, v_ev, v_sig, left(v_note, 300), v_label, auth.uid()
  ) returning id into v_id;
  perform booking._audit_closure_ack('BLOCK_CONFLICT_ACK', v_id, jsonb_build_object(
    'reservation_id', p_reservation_id, 'block_id', p_block_id, 'closure_event_id', v_ev,
    'block_signature', v_sig, 'ack_reason', left(v_note, 300), 'acked_by_label', v_label,
    'replaced_id', v_existing.id));
  return jsonb_build_object('ok', true, 'already', false, 'id', v_id,
    'reservation_id', p_reservation_id, 'block_id', p_block_id);
end $$;

create or replace function booking.admin_unack_block_conflict(
  p_reservation_id bigint,
  p_block_id bigint
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_id bigint; v_row booking.closure_conflict_acks;
begin
  perform booking._require_closure_ack();
  if p_reservation_id is null or p_block_id is null then
    perform booking._err('not_found', 'Varaus tai sulku puuttuu');
  end if;
  perform pg_advisory_xact_lock(hashtextextended('booking:closure_ack:' || p_reservation_id::text || ':' || p_block_id::text, 0));
  select * into v_row
    from booking.closure_conflict_acks
   where reservation_id = p_reservation_id and block_id = p_block_id and revoked_at is null
   for update;
  if not found then
    return jsonb_build_object('ok', true, 'already', true, 'revoked', false,
      'reservation_id', p_reservation_id, 'block_id', p_block_id);
  end if;
  update booking.closure_conflict_acks set revoked_at = now() where id = v_row.id returning id into v_id;
  perform booking._audit_closure_ack('BLOCK_CONFLICT_UNACK', v_id, jsonb_build_object(
    'reservation_id', p_reservation_id, 'block_id', p_block_id, 'ack_id', v_id,
    'block_signature', v_row.block_signature));
  return jsonb_build_object('ok', true, 'already', false, 'revoked', true, 'id', v_id,
    'reservation_id', p_reservation_id, 'block_id', p_block_id);
end $$;

-- ---------- usea pari kerralla (tuotannon kerta-ajo). Yksi virhe peruu koko kutsun. ----------
create or replace function booking.admin_ack_block_conflicts_bulk(
  p_pairs jsonb,
  p_note text,
  p_label text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  e jsonb;
  v_res jsonb := '[]'::jsonb;
  v_one jsonb;
  v_n integer := 0;
  v_rid bigint;
  v_bid bigint;
begin
  perform booking._require_closure_ack();
  if p_pairs is null or jsonb_typeof(p_pairs) <> 'array' or jsonb_array_length(p_pairs) < 1 then
    perform booking._err('bad_pairs', 'p_pairs pitää olla ei-tyhjä JSON-taulukko objekteja {reservation_id, block_id}');
  end if;
  if jsonb_array_length(p_pairs) > 200 then
    perform booking._err('too_many', 'Enintään 200 paria kerralla');
  end if;
  for e in select value from jsonb_array_elements(p_pairs) loop
    if jsonb_typeof(e) <> 'object' or not (e ? 'reservation_id') or not (e ? 'block_id') then
      perform booking._err('bad_pairs', 'Jokaisella parilla pitää olla reservation_id ja block_id');
    end if;
    v_rid := (e ->> 'reservation_id')::bigint;
    v_bid := (e ->> 'block_id')::bigint;
    v_one := booking.admin_ack_block_conflict(v_rid, v_bid, p_note, p_label);
    v_res := v_res || jsonb_build_array(v_one);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'count', v_n, 'items', v_res);
end $$;

-- ---------- Tarkista-lista: kuitattu pari pois avoimista, oma osio kuitatuille ----------
create or replace function booking.admin_review_list()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform booking._require_staff();
  return jsonb_build_object(
    'therapist_conflicts', coalesce((select jsonb_agg(jsonb_build_object('reservation_id', c.reservation_id, 'leg_id', c.leg_id, 'starts_at', c.claim_start, 'ends_at', c.claim_end, 'skill', c.skill) order by c.claim_start)
        from booking.v_claims c where c.role = 'therapist' and not c.is_override and booking._res_active(c.status, c.hold_expires_at) and c.claim_end > now()
         and booking._therapist_slack(c.skill, c.claim_start, c.claim_end, c.persons, c.session_key, c.leg_id, c.reservation_id) < 0), '[]'::jsonb),
    'block_conflicts', coalesce((select jsonb_agg(jsonb_build_object(
            'reservation_id', p.reservation_id, 'leg_id', p.leg_id, 'resource_id', p.resource_id, 'block_id', p.block_id,
            'closure_event_id', p.closure_event_id, 'starts_at', p.claim_start, 'ends_at', p.claim_end,
            'block_reason', p.block_reason, 'closure_reason', p.closure_reason, 'calendar_name', p.calendar_name) order by p.claim_start)
        from booking._block_conflict_pairs() p
       where not exists (
         select 1 from booking.closure_conflict_acks a
          where a.reservation_id = p.reservation_id and a.block_id = p.block_id
            and a.revoked_at is null and a.block_signature = p.block_signature)), '[]'::jsonb),
    'acked_block_conflicts', coalesce((select jsonb_agg(jsonb_build_object(
            'reservation_id', p.reservation_id, 'leg_id', p.leg_id, 'resource_id', p.resource_id, 'block_id', p.block_id,
            'closure_event_id', p.closure_event_id, 'starts_at', p.claim_start, 'ends_at', p.claim_end,
            'block_reason', p.block_reason, 'closure_reason', p.closure_reason, 'calendar_name', p.calendar_name,
            'ack_id', a.id, 'ack_reason', a.ack_reason, 'acked_by_label', a.acked_by_label, 'acked_at', a.acked_at) order by p.claim_start)
        from booking._block_conflict_pairs() p
        join booking.closure_conflict_acks a
          on a.reservation_id = p.reservation_id and a.block_id = p.block_id
         and a.revoked_at is null and a.block_signature = p.block_signature), '[]'::jsonb),
    'overrides', coalesce((select jsonb_agg(jsonb_build_object('reservation_id', r.id, 'reason', r.override_reason, 'starts_at', r.starts_at) order by r.starts_at)
        from booking.reservations r where r.override_reason is not null and r.ends_at > now() and booking._res_active(r.status, r.hold_expires_at)), '[]'::jsonb),
    'orphan_addons', coalesce((select jsonb_agg(jsonb_build_object('reservation_id', r.id, 'starts_at', r.starts_at) order by r.starts_at)
        from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id and cardinality(pc.requires_parent_product_ids) > 0
        left join booking.reservations pr on pr.id = r.parent_reservation_id
       where r.ends_at > now() and booking._res_active(r.status, r.hold_expires_at) and r.override_reason is null
         and (pr.id is null or not booking._res_active(pr.status, pr.hold_expires_at))), '[]'::jsonb),
    'missing_therapist', coalesce((select jsonb_agg(jsonb_build_object('reservation_id', r.id, 'starts_at', r.starts_at, 'ends_at', r.ends_at, 'product_id', r.product_id,
              'product_name', coalesce(p.name, ''), 'persons', r.persons, 'order_no', o.order_no, 'source', coalesce(r.external_source, 'native'),
              'days_to_start', ((r.starts_at at time zone 'Europe/Helsinki')::date - (now() at time zone 'Europe/Helsinki')::date)) order by r.starts_at)
        from booking.reservations r join booking.orders o on o.id = r.order_id left join kb.products p on p.id = r.product_id
       where r.therapist_missing and r.therapist_exception_at is null and r.ends_at > now() and booking._res_active(r.status, r.hold_expires_at)
         and not exists (select 1 from booking.reservation_legs l where l.reservation_id = r.id and l.role = 'therapist')), '[]'::jsonb));
end $$;

revoke all on function booking._block_conflict_signature(bigint) from public, anon, authenticated;
revoke all on function booking._block_conflict_pairs() from public, anon, authenticated;
revoke all on function booking._require_closure_ack() from public, anon, authenticated;
revoke all on function booking._audit_closure_ack(text, bigint, jsonb) from public, anon, authenticated;
revoke all on function booking.admin_ack_block_conflict(bigint, bigint, text, text) from public, anon;
revoke all on function booking.admin_unack_block_conflict(bigint, bigint) from public, anon;
revoke all on function booking.admin_ack_block_conflicts_bulk(jsonb, text, text) from public, anon;

grant execute on function booking._block_conflict_signature(bigint) to service_role;
grant execute on function booking._block_conflict_pairs() to service_role;
grant execute on function booking._require_closure_ack() to service_role;
grant execute on function booking._audit_closure_ack(text, bigint, jsonb) to service_role;
grant execute on function booking.admin_ack_block_conflict(bigint, bigint, text, text) to authenticated, service_role;
grant execute on function booking.admin_unack_block_conflict(bigint, bigint) to authenticated, service_role;
grant execute on function booking.admin_ack_block_conflicts_bulk(jsonb, text, text) to authenticated, service_role;
