-- ROLLBACK booking_81_pos_fridge_rpc.
-- Poistaa pikakassan ja kylmälaitteen RPC:t ja palauttaa tuotannon admin_update_product_config-funktion
-- (pg_get_functiondef 2026-10-19: audience on sallittu kenttä). Skeema perutaan booking_80-rollbackilla
-- (aja 83, 82, 81, sitten 80).

drop function if exists booking.public_drinks_status(uuid);
drop function if exists booking.public_drinks_checkout(text, jsonb, text, text);
drop function if exists booking.public_drinks_catalog(text);
drop function if exists booking.vismapay_payment_prepare(uuid);
drop function if exists booking.admin_upsert_cold_unit(bigint, text, text, boolean);
drop function if exists booking.admin_list_cold_units();
drop function if exists booking.admin_pos_void(bigint);
drop function if exists booking.admin_pos_status(bigint);
drop function if exists booking.admin_pos_checkout(jsonb, text, text);
drop function if exists booking.admin_pos_tenders();
drop function if exists booking.admin_pos_catalog();
drop function if exists booking._cold_unit_json(bigint);
drop function if exists booking._counter_expire(bigint);
drop function if exists booking._counter_checkout(text, jsonb, text, text, text);
drop function if exists booking._counter_lines(jsonb, text);

create or replace function booking.admin_update_product_config(p_product_id bigint, p_patch jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $fn$
declare allowed text[] := array['bookable','shop_visible','sort_order','min_persons','max_persons','notes',
                                'lifecycle','resource_class','closure_group','duration_minutes','required_skill',
                                'therapists_needed','therapist_offset_min','therapist_minutes','audience']; k text;
begin
  perform booking._require_permission('catalog.edit');
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata: ' || k); end if;
  end loop;
  if p_patch ? 'audience' and coalesce(p_patch ->> 'audience', '') not in ('consumer', 'business') then
    perform booking._err('invalid_audience', 'Näkyvyys on consumer tai business');
  end if;
  update booking.product_config set
    bookable = case when p_patch ? 'bookable' then (p_patch ->> 'bookable')::boolean else bookable end,
    shop_visible = case when p_patch ? 'shop_visible' then (p_patch ->> 'shop_visible')::boolean else shop_visible end,
    sort_order = case when p_patch ? 'sort_order' then (p_patch ->> 'sort_order')::int else sort_order end,
    min_persons = case when p_patch ? 'min_persons' then (p_patch ->> 'min_persons')::int else min_persons end,
    max_persons = case when p_patch ? 'max_persons' then (p_patch ->> 'max_persons')::int else max_persons end,
    notes = case when p_patch ? 'notes' then p_patch ->> 'notes' else notes end,
    lifecycle = case when p_patch ? 'lifecycle' then p_patch ->> 'lifecycle' else lifecycle end,
    resource_class = case when p_patch ? 'resource_class' then p_patch ->> 'resource_class' else resource_class end,
    closure_group = case when p_patch ? 'closure_group' then nullif(btrim(p_patch ->> 'closure_group'), '') else closure_group end,
    duration_minutes = case when p_patch ? 'duration_minutes' then (p_patch ->> 'duration_minutes')::int else duration_minutes end,
    required_skill = case when p_patch ? 'required_skill' then nullif(btrim(p_patch ->> 'required_skill'), '') else required_skill end,
    therapists_needed = case when p_patch ? 'therapists_needed' then (p_patch ->> 'therapists_needed')::int else therapists_needed end,
    therapist_offset_min = case when p_patch ? 'therapist_offset_min' then (p_patch ->> 'therapist_offset_min')::int else therapist_offset_min end,
    therapist_minutes = case when p_patch ? 'therapist_minutes' then (p_patch ->> 'therapist_minutes')::int else therapist_minutes end,
    audience = case when p_patch ? 'audience' then p_patch ->> 'audience' else audience end
   where product_id = p_product_id;
  if not found then perform booking._err('not_found', 'Tuotteella ei ole varauskonfiguraatiota'); end if;
  return jsonb_build_object('ok', true);
end $fn$;
