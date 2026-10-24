-- ROLLBACK booking_152_annual_card_delete: vuosikortin poisto pois hallinnasta.
-- Poistaa admin_delete_annual_card-funktion ja palauttaa booking_142:n admin_list_annual_cards_details-määritelmän täsmälleen
-- (ilman reservations_count- ja deletable-kenttiä). Jo poistetut kortit eivät palaudu (audit_logissa old_data).
-- Uudelleenajettava (toinen ajo ei muuta mitään).
set local lock_timeout = '5s';
drop function if exists booking.admin_delete_annual_card(bigint);

create or replace function booking.admin_list_annual_cards_details() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._require_permission('annual_cards.manage');
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'code', a.code, 'customer_id', a.customer_id, 'customer_name', c.name,
      'customer_email', c.email, 'valid_from', a.valid_from, 'valid_to', a.valid_to, 'active', a.active, 'revoked_at', a.revoked_at,
      'notes', a.notes, 'purchase_order_no', o.order_no,
      'future_bookings', (select count(*) from booking.reservations r where r.annual_card_id = a.id and r.starts_at > now()
                           and booking._res_active(r.status, r.hold_expires_at)))
      order by a.active desc, a.valid_to desc, a.id desc)
    from booking.annual_cards a join booking.customers c on c.id = a.customer_id left join booking.orders o on o.id = a.purchase_order_id), '[]'::jsonb);
end $$;

-- admin_list_annual_cards_details: create or replace säilyttää booking_142:n oikeudet (authenticated, service_role).
