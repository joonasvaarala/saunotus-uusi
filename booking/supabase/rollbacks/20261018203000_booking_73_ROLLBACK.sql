-- Rollback booking_73_closure_conflict_ack.
-- Poistaa kuittaukset ja palauttaa admin_review_list-funktion booking_22:n mukaiseksi
-- (ei acked_block_conflicts-osiota, sulkukonfliktit ilman kuittaussuodatinta).
-- Ei palauta kuittausten sisältöä. Ei koske space_blocks-, closure_events- eikä reservations-riveihin.
set local lock_timeout = '5s';

drop function if exists booking.admin_ack_block_conflicts_bulk(jsonb, text, text);
drop function if exists booking.admin_unack_block_conflict(bigint, bigint);
drop function if exists booking.admin_ack_block_conflict(bigint, bigint, text, text);
drop function if exists booking._audit_closure_ack(text, bigint, jsonb);
drop function if exists booking._require_closure_ack();
drop function if exists booking._block_conflict_pairs();
drop function if exists booking._block_conflict_signature(bigint);

drop table if exists booking.closure_conflict_acks;

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
    'block_conflicts', coalesce((select jsonb_agg(jsonb_build_object('reservation_id', c.reservation_id, 'leg_id', c.leg_id, 'resource_id', c.resource_id, 'block_id', b.id, 'starts_at', c.claim_start) order by c.claim_start)
        from booking.v_claims c join booking.space_blocks b on b.active and b.space_id = c.resource_id and b.during && tstzrange(c.claim_start, c.claim_end, '[)')
       where not c.is_override and booking._res_active(c.status, c.hold_expires_at) and c.claim_end > now()), '[]'::jsonb),
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
