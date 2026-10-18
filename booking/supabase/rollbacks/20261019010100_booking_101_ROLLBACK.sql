-- ROLLBACK booking_101_drop_business_quote_admin.
-- Palauttaa admin_list_business_quotes, admin_set_business_quote_status ja quotes.manage-oikeuden
-- (admin ja manager), kuten booking_75. Ei luo taulua uudelleen eikä koske RLS:ään.
-- Aja booking_102:n rollbackin jälkeen.

create or replace function booking.admin_list_business_quotes(p_status text default null)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_status text := nullif(lower(btrim(coalesce(p_status, ''))), '');
begin
  perform booking._require_permission('quotes.manage');
  if v_status is not null and v_status not in ('new', 'handled', 'offered', 'closed') then
    perform booking._err('invalid_status', 'Tila on new, handled, offered tai closed');
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', q.id, 'status', q.status, 'company_name', q.company_name, 'contact_name', q.contact_name,
      'email', q.email, 'phone', q.phone, 'preferred_when', q.preferred_when, 'persons', q.persons,
      'offerings', to_jsonb(q.offerings), 'offering_other', q.offering_other, 'message', q.message,
      'locale', q.locale, 'created_at', q.created_at, 'handled_at', q.handled_at, 'admin_note', q.admin_note
    ) order by q.created_at desc, q.id desc)
    from (
      select * from booking.business_quote_requests
       where v_status is null or status = v_status
       order by created_at desc, id desc
       limit 200
    ) q
  ), '[]'::jsonb);
end $$;

create or replace function booking.admin_set_business_quote_status(p_id bigint, p_status text, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_status text := lower(btrim(coalesce(p_status, ''))); v_note text;
begin
  perform booking._require_permission('quotes.manage');
  if v_status not in ('new', 'handled', 'offered', 'closed') then
    perform booking._err('invalid_status', 'Tila on new, handled, offered tai closed');
  end if;
  if p_note is not null and char_length(btrim(p_note)) > 2000 then
    perform booking._err('invalid_note', 'Muistiinpano on liian pitkä');
  end if;
  v_note := case when p_note is null then null else nullif(btrim(p_note), '') end;
  update booking.business_quote_requests set
    status = v_status,
    admin_note = case when p_note is null then admin_note else v_note end,
    handled_by = auth.uid(),
    handled_at = now()
   where id = p_id;
  if not found then perform booking._err('not_found', 'Tarjouspyyntöä ei löydy'); end if;
  return jsonb_build_object('ok', true, 'id', p_id, 'status', v_status);
end $$;

revoke all on function booking.admin_list_business_quotes(text) from public;
revoke all on function booking.admin_set_business_quote_status(bigint, text, text) from public;
grant execute on function booking.admin_list_business_quotes(text) to authenticated, service_role;
grant execute on function booking.admin_set_business_quote_status(bigint, text, text) to authenticated, service_role;

insert into booking.role_permissions(role_code, permission) values
  ('admin', 'quotes.manage'),
  ('manager', 'quotes.manage')
on conflict do nothing;
