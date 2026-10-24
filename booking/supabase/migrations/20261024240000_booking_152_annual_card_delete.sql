-- =============================================================================
-- booking_152: vuosikortin poisto hallinnasta (vain käyttämätön, hallinnasta myönnetty kortti).
-- 1) booking.admin_delete_annual_card(p_id): oikeus annual_cards.manage. Sallittu vain, kun kortilla ei ole ostotilausta
--    (purchase_order_id is null) eikä yhtään varausta (reservations.annual_card_id, mikä tahansa tila). Muuten selkeä
--    virhe (annual_card_purchased / annual_card_used), joka neuvoo perumaan kortin. Rinnakkainen varaus kesken poiston →
--    viiteavain estää poiston → sama virhe annual_card_used.
--    Asiakastyyppi palautuu samoin kuin perumisessa: olemassa oleva trigger annual_cards_sync (after delete) asettaa
--    customers.customer_type = 'customer', jos asiakkaalla ei ole muuta aktiivista korttia.
--    Audit: olemassa oleva audit_trg (after delete) kirjaa rivin audit_logiin (action DELETE, old_data = koko kortti).
-- 2) booking.admin_list_annual_cards_details(): lisäkentät reservations_count (kaikki kortin varaukset) ja deletable
--    (näkymä näyttää Poista-napin vain silloin). Muut kentät ja järjestys ennallaan (booking_142).
-- Ei muuta hintoja, ALV:tä, kortin myöntämis- tai perumissääntöjä eikä public-skeemaa.
-- Uudelleenajettava: create or replace. Rollback: ../rollbacks/20261024240000_booking_152_ROLLBACK.sql
-- =============================================================================
set local lock_timeout = '5s';

create or replace function booking.admin_delete_annual_card(p_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c booking.annual_cards;
begin
  perform booking._require_permission('annual_cards.manage');
  select * into c from booking.annual_cards where id = p_id for update;
  if not found then perform booking._err('not_found', 'Vuosikorttia ei löydy'); end if;
  if c.purchase_order_id is not null then
    perform booking._err('annual_card_purchased', 'Kortti on ostettu tilauksella, joten sitä ei voi poistaa. Peru kortti poistamisen sijaan.');
  end if;
  if exists (select 1 from booking.reservations r where r.annual_card_id = c.id) then
    perform booking._err('annual_card_used', 'Kortilla on varauksia, joten sitä ei voi poistaa. Peru kortti poistamisen sijaan.');
  end if;
  begin
    delete from booking.annual_cards where id = c.id;
  exception when foreign_key_violation then
    perform booking._err('annual_card_used', 'Kortilla on varauksia, joten sitä ei voi poistaa. Peru kortti poistamisen sijaan.');
  end;
  return jsonb_build_object('ok', true, 'deleted', true, 'id', c.id, 'customer_id', c.customer_id, 'code', c.code);
end $$;

create or replace function booking.admin_list_annual_cards_details() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._require_permission('annual_cards.manage');
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'code', a.code, 'customer_id', a.customer_id, 'customer_name', c.name,
      'customer_email', c.email, 'valid_from', a.valid_from, 'valid_to', a.valid_to, 'active', a.active, 'revoked_at', a.revoked_at,
      'notes', a.notes, 'purchase_order_no', o.order_no,
      'future_bookings', (select count(*) from booking.reservations r where r.annual_card_id = a.id and r.starts_at > now()
                           and booking._res_active(r.status, r.hold_expires_at)),
      'reservations_count', n.cnt,
      'deletable', a.purchase_order_id is null and n.cnt = 0)
      order by a.active desc, a.valid_to desc, a.id desc)
    from booking.annual_cards a join booking.customers c on c.id = a.customer_id left join booking.orders o on o.id = a.purchase_order_id
    cross join lateral (select count(*)::int as cnt from booking.reservations r where r.annual_card_id = a.id) n), '[]'::jsonb);
end $$;

revoke all on function booking.admin_delete_annual_card(bigint) from public, anon, service_role;
grant execute on function booking.admin_delete_annual_card(bigint) to authenticated;
-- admin_list_annual_cards_details: create or replace säilyttää booking_142:n oikeudet (authenticated, service_role).
