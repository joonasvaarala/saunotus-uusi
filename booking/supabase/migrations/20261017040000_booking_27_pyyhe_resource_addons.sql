-- booking_27: Pyyhe (5 €), lisäpalvelurajaus hoitoihin/saunotuksiin/tapahtumiin, `code` admin_day_view:hin ja päivän työvuorot kaikille henkilöstöroolille (hallinnan etusivu).
-- Joonaksen päätös 17.10. (t54u/t56u): pyyhe 5 € yleisissä vuoroissa, yksityisvarauksissa sekä hoidoissa ja saunotuksissa (resurssivaraus), EI tapahtumissa (kb.products.category = 'event');
-- saunavihta ja turvenaamio+jalkakylpy vain yleisissä vuoroissa ja yksityisvarauksissa (eivät hoidossa, saunotuksessa eivätkä tapahtumassa).
-- Additiivinen ja idempotentti (rajoite korvataan samannimisenä, rivi on `on conflict do nothing`, funktiot `create or replace`). Funktiorungot ovat repon booking_11 / booking_22
-- versioiden kopioita merkityin muutoksin (kommentit "MUUTOS"). Versionumero on paikkamerkki: anna ajettaessa numero, joka on suurempi kuin tuotannon viimeisin
-- (booking_26_publish_treatments on jo tuotannossa; 24 ja 25 eivät ole tässä repossa) – kerro versio takaisin, niin repon tiedostonimi päivitetään.
-- EI ajeta tuotantoon ilman Joonaksen hyväksyntää. Rollback: ks. booking/docs/bottiavustus-pyynto-pyyhe.md.

-- MUUTOS 1) Uusi lisäpalvelun tila 'resource' (hoito, saunotus, rituaali). Tapahtuma ('event') EI ole sallittu tila: tapahtumalle ei tarjota lisäpalveluita.
do $$ declare c text; begin
  for c in select conname from pg_constraint where conrelid = 'booking.addons'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%applies_modes%' loop
    execute format('alter table booking.addons drop constraint %I', c);
  end loop;
  alter table booking.addons add constraint addons_applies_modes_check
    check (cardinality(applies_modes) > 0 and applies_modes <@ array['shared','exclusive','resource']);
end $$;
comment on column booking.addons.applies_modes is 'shared = yleinen vuoro, exclusive = yksityisvuoro, resource = resurssivaraus (hoito, saunotus, rituaali; ei tapahtuma).';

-- MUUTOS 2) Pyyhe 5 € (sis. ALV 25,5 %): yleiset vuorot, yksityisvaraukset, hoidot ja saunotukset; EI tapahtumat. Vihta ja turvenaamio+jalkakylpy pysyvät {shared,exclusive}.
insert into booking.addons(code, name, name_en, description, description_en, price_gross, vat_rate, max_per_person, applies_modes, active, sort_order)
values ('pyyhe', 'Pyyhe', 'Towel', 'Lisäpalvelu varaukseen: pyyhe.', 'Add-on for your booking: towel.', 5.00, 25.5, 1, '{shared,exclusive,resource}', true, 30)
on conflict (code) do nothing;

-- MUUTOS 3) _attach_addons: tehokas tila (muutos: v_mode; resurssivaraus = 'resource', tapahtuma = 'event')
create or replace function booking._attach_addons(p_reservation_id bigint, p_addons jsonb)
returns numeric language plpgsql security definer set search_path = '' as $$
declare
  r booking.reservations; a booking.addons; e jsonb; v_acc jsonb := '{}'::jsonb; v_key text; v_qty integer; v_total numeric := 0;
  v_idtxt text; v_code text; v_lim integer; v_mode text;
begin
  if p_addons is null or p_addons = 'null'::jsonb then return 0; end if;
  if jsonb_typeof(p_addons) <> 'array' then perform booking._err('invalid_addons', 'Lisäpalvelut väärässä muodossa'); end if;
  if jsonb_array_length(p_addons) = 0 then return 0; end if;
  if jsonb_array_length(p_addons) > 20 then perform booking._err('invalid_addons', 'Liian monta lisäpalvelua'); end if;
  select * into r from booking.reservations where id = p_reservation_id;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;

  -- tehokas tila: yleinen vuoro / yksityisvuoro = r.mode (shared / exclusive); resurssivaraus (hoito, saunotus, rituaali; sale_kind 'other') = 'resource';
  -- tapahtuma (kb.products.category = 'event') = 'event' (ei lisäpalveluita)
  select case when pc.sale_kind = 'other' and pc.resource_class = 'resourced' then case when p.category = 'event' then 'event' else 'resource' end else r.mode end
    into v_mode from booking.product_config pc join kb.products p on p.id = pc.product_id where pc.product_id = r.product_id;
  v_mode := coalesce(v_mode, r.mode);

  for e in select * from jsonb_array_elements(p_addons) loop
    if jsonb_typeof(e) <> 'object' then perform booking._err('invalid_addons', 'Lisäpalvelut väärässä muodossa'); end if;
    v_idtxt := e ->> 'id'; v_code := e ->> 'code';
    if coalesce(e ->> 'quantity', '') !~ '^\d{1,4}$' then perform booking._err('addon_quantity', 'Lisäpalvelun määrän pitää olla kokonaisluku'); end if;
    v_qty := (e ->> 'quantity')::int;
    if v_idtxt is not null and v_idtxt !~ '^\d{1,18}$' then perform booking._err('addon_not_found', 'Lisäpalvelua ei löydy'); end if;
    select * into a from booking.addons where (v_idtxt is not null and id = v_idtxt::bigint) or (v_idtxt is null and v_code is not null and code = v_code);
    if not found then perform booking._err('addon_not_found', 'Lisäpalvelua ei löydy'); end if;
    v_acc := jsonb_set(v_acc, array[a.id::text], to_jsonb(coalesce((v_acc ->> a.id::text)::int, 0) + v_qty));
  end loop;

  for v_key, v_qty in select k, (v_acc ->> k)::int from jsonb_object_keys(v_acc) k order by k::bigint loop
    continue when v_qty = 0;
    select * into a from booking.addons where id = v_key::bigint;
    if not a.active then perform booking._err('addon_inactive', format('Lisäpalvelu "%s" ei ole käytössä', a.name)); end if;
    if not (v_mode = any (a.applies_modes)) then perform booking._err('addon_not_allowed', format('Lisäpalvelu "%s" ei ole saatavilla tälle vuorolle', a.name)); end if;
    v_lim := booking._addon_limit(a.max_per_person, r.persons);
    if v_qty > v_lim then perform booking._err('addon_quantity', format('Lisäpalvelua "%s" voi valita enintään %s kpl', a.name, v_lim)); end if;
    insert into booking.order_items(order_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, addon_id, parent_item_id, price_breakdown)
    values (r.order_id, a.name, 'addon', v_qty, a.price_gross, a.price_gross * v_qty, a.vat_rate, a.id, r.order_item_id,
            jsonb_build_object('addon_code', a.code, 'name_en', a.name_en, 'unit_price', a.price_gross, 'quantity', v_qty, 'max_per_person', a.max_per_person));
    v_total := v_total + a.price_gross * v_qty;
  end loop;
  if v_total > 0 then update booking.orders set total_gross = total_gross + v_total where id = r.order_id; end if;
  return v_total;
end $$;

-- MUUTOS 4) admin_create_addon / admin_update_addon: 'resource' sallittu applies_modes-taulukossa (muutos: sallittu joukko ja virheviesti)
create or replace function booking.admin_create_addon(p_data jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  allowed text[] := array['code','name','name_en','description','description_en','price','vat_rate','max_per_person','applies_modes','active','sort_order'];
  k text; v_price numeric; v_vat numeric; v_max integer; v_modes text[]; v_id bigint; v_sort integer;
begin
  perform booking._require_permission('catalog.edit');
  if p_data is null or jsonb_typeof(p_data) <> 'object' then perform booking._err('invalid_addon', 'Anna lisäpalvelun tiedot'); end if;
  for k in select jsonb_object_keys(p_data) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa antaa: ' || k); end if;
  end loop;
  if coalesce(p_data ->> 'code', '') !~ '^[a-z][a-z0-9_]{1,40}$' then perform booking._err('invalid_code', 'Tunnus: pienet kirjaimet, numerot ja alaviiva (alkaa kirjaimella)'); end if;
  if exists (select 1 from booking.addons where code = p_data ->> 'code') then perform booking._err('code_exists', 'Tunnus on jo käytössä'); end if;
  if char_length(btrim(coalesce(p_data ->> 'name', ''))) = 0 or char_length(p_data ->> 'name') > 200 then perform booking._err('invalid_name', 'Anna nimi'); end if;
  if coalesce(p_data ->> 'price', '') !~ '^\d{1,6}([.,]\d{1,2})?$' then perform booking._err('invalid_price', 'Virheellinen hinta'); end if;
  v_price := replace(p_data ->> 'price', ',', '.')::numeric;
  v_vat := case when coalesce(p_data ->> 'vat_rate', '') ~ '^\d{1,2}([.,]\d)?$' then replace(p_data ->> 'vat_rate', ',', '.')::numeric when p_data ? 'vat_rate' then -1 else 25.5 end;
  if v_vat not in (0, 10, 13.5, 14, 24, 25.5) then perform booking._err('invalid_vat', 'ALV-kanta ei ole sallittu (0, 10, 13.5, 14, 24, 25.5)'); end if;
  if p_data ? 'max_per_person' and nullif(p_data ->> 'max_per_person', '') is not null then
    if p_data ->> 'max_per_person' !~ '^\d{1,2}$' or (p_data ->> 'max_per_person')::int not between 1 and 20 then perform booking._err('invalid_max', 'Enimmäismäärä / henkilö: 1–20'); end if;
    v_max := (p_data ->> 'max_per_person')::int;
  end if;
  if p_data ? 'applies_modes' then
    if jsonb_typeof(p_data -> 'applies_modes') <> 'array' then perform booking._err('invalid_modes', 'Vuorotyypit virheellisessä muodossa'); end if;
    select array_agg(distinct x) into v_modes from jsonb_array_elements_text(p_data -> 'applies_modes') x;
    if v_modes is null or not (v_modes <@ array['shared','exclusive','resource']) then perform booking._err('invalid_modes', 'Vuorotyyppi: shared (yleinen), exclusive (yksityinen) ja/tai resource (hoito, saunotus)'); end if;
  end if;
  v_sort := case when coalesce(p_data ->> 'sort_order', '') ~ '^\d{1,5}$' then (p_data ->> 'sort_order')::int else 100 end;
  insert into booking.addons(code, name, name_en, description, description_en, price_gross, vat_rate, max_per_person, applies_modes, active, sort_order)
  values (p_data ->> 'code', btrim(p_data ->> 'name'), nullif(btrim(coalesce(p_data ->> 'name_en', '')), ''), nullif(p_data ->> 'description', ''),
          nullif(p_data ->> 'description_en', ''), v_price, v_vat, v_max, coalesce(v_modes, '{shared,exclusive}'),
          coalesce((p_data ->> 'active')::boolean, true), v_sort)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function booking.admin_update_addon(p_id bigint, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  allowed text[] := array['name','name_en','description','description_en','price','vat_rate','max_per_person','applies_modes','active','sort_order'];
  k text; v_price numeric; v_vat numeric; v_max integer; v_modes text[];
begin
  perform booking._require_permission('catalog.edit');
  if not exists (select 1 from booking.addons where id = p_id) then perform booking._err('not_found', 'Lisäpalvelua ei löydy'); end if;
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata: ' || k); end if;
  end loop;
  if p_patch ? 'name' and (char_length(btrim(coalesce(p_patch ->> 'name', ''))) = 0 or char_length(p_patch ->> 'name') > 200) then perform booking._err('invalid_name', 'Nimi ei voi olla tyhjä'); end if;
  if p_patch ? 'price' then
    if coalesce(p_patch ->> 'price', '') !~ '^\d{1,6}([.,]\d{1,2})?$' then perform booking._err('invalid_price', 'Virheellinen hinta'); end if;
    v_price := replace(p_patch ->> 'price', ',', '.')::numeric;
  end if;
  if p_patch ? 'vat_rate' then
    v_vat := case when coalesce(p_patch ->> 'vat_rate', '') ~ '^\d{1,2}([.,]\d)?$' then replace(p_patch ->> 'vat_rate', ',', '.')::numeric else -1 end;
    if v_vat not in (0, 10, 13.5, 14, 24, 25.5) then perform booking._err('invalid_vat', 'ALV-kanta ei ole sallittu (0, 10, 13.5, 14, 24, 25.5)'); end if;
  end if;
  if p_patch ? 'max_per_person' and nullif(p_patch ->> 'max_per_person', '') is not null then
    if p_patch ->> 'max_per_person' !~ '^\d{1,2}$' or (p_patch ->> 'max_per_person')::int not between 1 and 20 then perform booking._err('invalid_max', 'Enimmäismäärä / henkilö: 1–20'); end if;
    v_max := (p_patch ->> 'max_per_person')::int;
  end if;
  if p_patch ? 'applies_modes' then
    if jsonb_typeof(p_patch -> 'applies_modes') <> 'array' then perform booking._err('invalid_modes', 'Vuorotyypit virheellisessä muodossa'); end if;
    select array_agg(distinct x) into v_modes from jsonb_array_elements_text(p_patch -> 'applies_modes') x;
    if v_modes is null or not (v_modes <@ array['shared','exclusive','resource']) then perform booking._err('invalid_modes', 'Vuorotyyppi: shared (yleinen), exclusive (yksityinen) ja/tai resource (hoito, saunotus)'); end if;
  end if;
  if p_patch ? 'sort_order' and coalesce(p_patch ->> 'sort_order', '') !~ '^\d{1,5}$' then perform booking._err('invalid_sort', 'Virheellinen järjestys'); end if;
  update booking.addons set
    name = case when p_patch ? 'name' then btrim(p_patch ->> 'name') else name end,
    name_en = case when p_patch ? 'name_en' then nullif(btrim(coalesce(p_patch ->> 'name_en', '')), '') else name_en end,
    description = case when p_patch ? 'description' then nullif(p_patch ->> 'description', '') else description end,
    description_en = case when p_patch ? 'description_en' then nullif(p_patch ->> 'description_en', '') else description_en end,
    price_gross = case when p_patch ? 'price' then v_price else price_gross end,
    vat_rate = case when p_patch ? 'vat_rate' then v_vat else vat_rate end,
    max_per_person = case when p_patch ? 'max_per_person' then v_max else max_per_person end,
    applies_modes = case when p_patch ? 'applies_modes' then v_modes else applies_modes end,
    active = case when p_patch ? 'active' then (p_patch ->> 'active')::boolean else active end,
    sort_order = case when p_patch ? 'sort_order' then (p_patch ->> 'sort_order')::int else sort_order end
   where id = p_id;
  return jsonb_build_object('ok', true, 'id', p_id);
end $$;


-- MUUTOS 5) admin_day_view: kenttä `code` lisäpalvelurivillä (reservations[].addons[], prep[].items[], addon_totals[]) → hallinnan ikonit tunnistetaan koodista (muuten kuten booking_22)
CREATE OR REPLACE FUNCTION booking.admin_day_view(p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_from timestamptz := p_date::timestamp at time zone 'Europe/Helsinki';
        v_to timestamptz := (p_date + 1)::timestamp at time zone 'Europe/Helsinki';
        v_prep jsonb; v_totals jsonb;
begin
  perform booking._require_staff();
  with rs as (
    select r.rule_id, r.starts_at, r.ends_at, r.order_item_id, coalesce(it.product_name, '') as product_name
      from booking.reservations r left join booking.order_items it on it.id = r.order_item_id
     where r.starts_at < v_to and r.ends_at > v_from and booking._res_active(r.status, r.hold_expires_at)),
  per as (
    select rs.rule_id, rs.starts_at, rs.ends_at, rs.product_name, ai.addon_id, min(ad.code) as code, min(ai.product_name) as name, sum(ai.quantity)::int as qty
      from rs join booking.order_items ai on ai.parent_item_id = rs.order_item_id and ai.kind = 'addon'
      left join booking.addons ad on ad.id = ai.addon_id
     group by rs.rule_id, rs.starts_at, rs.ends_at, rs.product_name, ai.addon_id),
  grp as (
    select rule_id, starts_at, ends_at, product_name,
           jsonb_agg(jsonb_build_object('addon_id', addon_id, 'code', code, 'name', name, 'quantity', qty) order by name) as items
      from per group by rule_id, starts_at, ends_at, product_name)
  select (select coalesce(jsonb_agg(jsonb_build_object('rule_id', g.rule_id, 'starts_at', g.starts_at, 'ends_at', g.ends_at,
                    'product_name', g.product_name, 'items', g.items) order by g.starts_at, g.rule_id), '[]'::jsonb) from grp g),
         (select coalesce(jsonb_agg(jsonb_build_object('addon_id', t.addon_id, 'code', t.code, 'name', t.name, 'quantity', t.qty) order by t.name), '[]'::jsonb)
            from (select addon_id, min(code) as code, min(name) as name, sum(qty)::int as qty from per group by addon_id) t)
    into v_prep, v_totals;
  return jsonb_build_object(
    'date', p_date,
    'sessions', coalesce((select jsonb_agg(to_jsonb(s) order by s.starts_at, s.rule_id)
                           from booking._sessions(p_date, p_date, null, false) s), '[]'::jsonb),
    'reservations', coalesce((select jsonb_agg(jsonb_build_object(
        'reservation_id', r.id, 'order_id', o.id, 'order_no', o.order_no, 'status', r.status, 'payment_status', o.payment_status,
        'product_name', coalesce(it.product_name, p.name), 'mode', r.mode, 'starts_at', r.starts_at, 'ends_at', r.ends_at,
        'persons', r.persons, 'customer_name', c.name, 'customer_phone', c.phone, 'rule_id', r.rule_id, 'notes', r.notes,
        'annual_card', r.annual_card_id is not null, 'hold_expires_at', r.hold_expires_at,
        'source', coalesce(r.external_source, 'native'), 'external_id', r.external_id,
        'customer_kind', o.customer_kind, 'company', case when o.customer_kind <> 'private' then coalesce(o.billing ->> 'company', c.company) end,
        'space_code', sp.code, 'lifecycle', pcf.lifecycle, 'quota_exempt', r.quota_exempt, 'override_reason', r.override_reason,
        'therapist_missing', r.therapist_missing, 'therapist_exception_at', r.therapist_exception_at, 'therapist_exception_note', r.therapist_exception_note,
        'therapist_missing_open', (r.therapist_missing and r.therapist_exception_at is null and not exists (select 1 from booking.reservation_legs tl where tl.reservation_id = r.id and tl.role = 'therapist')),
        'claim_offset_min', r.claim_offset_min, 'claim_minutes', r.claim_minutes, 'parent_reservation_id', r.parent_reservation_id,
        'legs', coalesce((select jsonb_agg(jsonb_build_object('leg_id', l.id, 'role', l.role, 'resource_code', lr.code, 'starts_at', l.starts_at, 'ends_at', l.ends_at,
                                  'persons', l.persons, 'skill', l.skill) order by l.starts_at, l.id)
                            from booking.reservation_legs l join booking.resources lr on lr.id = l.resource_id where l.reservation_id = r.id), '[]'::jsonb),
        'addons', coalesce((select jsonb_agg(jsonb_build_object('addon_id', ai.addon_id, 'code', (select a2.code from booking.addons a2 where a2.id = ai.addon_id), 'name', ai.product_name, 'quantity', ai.quantity) order by ai.id)
                              from booking.order_items ai where ai.parent_item_id = r.order_item_id and ai.kind = 'addon'), '[]'::jsonb))
        order by r.starts_at, r.id)
        from booking.reservations r join booking.orders o on o.id = r.order_id join booking.resources sp on sp.id = r.space_id
        left join booking.order_items it on it.id = r.order_item_id left join kb.products p on p.id = r.product_id
        left join booking.product_config pcf on pcf.product_id = r.product_id
        left join booking.customers c on c.id = o.customer_id
        where r.starts_at < v_to and r.ends_at > v_from and booking._res_active(r.status, r.hold_expires_at)), '[]'::jsonb),
    'prep', v_prep, 'addon_totals', v_totals,
    'blocks', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'space_id', b.space_id, 'resource_code', br.code, 'closure_event_id', b.closure_event_id, 'starts_at', b.starts_at,
        'ends_at', b.ends_at, 'reason', b.reason) order by b.starts_at)
        from booking.space_blocks b join booking.resources br on br.id = b.space_id where b.active and b.starts_at < v_to and b.ends_at > v_from), '[]'::jsonb));
end $function$;

-- MUUTOS 6) Päivän työvuorot KAIKILLE henkilöstöroolille (hallinnan etusivu). Nykyinen admin_upcoming_shifts vaatii shifts.view / shifts.view_all ja rajaa 'staff'-roolin
--    vain omiin vuoroihin; etusivun "kuka on missäkin vuorossa" tarvitsee vain roolin, ajan ja nimen. Ei puhelinta, sähköpostia eikä muistiinpanoja.
create or replace function booking.admin_day_shifts(p_date date)
returns table (shift_id uuid, starts_at timestamptz, ends_at timestamptz, role_type text, calendar_name text, staffing_status text, staff_name text)
language plpgsql stable security definer set search_path = '' as $$
declare v_from timestamptz; v_to timestamptz;
begin
  perform booking._require_staff();
  if p_date is null then perform booking._err('invalid_range', 'Virheellinen päivä'); end if;
  v_from := p_date::timestamp at time zone 'Europe/Helsinki';
  v_to := (p_date + 1)::timestamp at time zone 'Europe/Helsinki';
  return query
    select ws.id, ws.starts_at, ws.ends_at, ws.role_type::text, cs.calendar_name::text, ws.staffing_status::text, ps.name::text
      from public.work_shifts ws
      left join public.calendar_sources cs on cs.id = ws.calendar_source_id
      left join public.shift_assignments sa on sa.shift_id = ws.id
      left join public.staff ps on ps.id = sa.staff_id
     where ws.status = 'active' and ws.starts_at < v_to and ws.ends_at > v_from
     order by ws.starts_at, ws.id, ps.name;
end $$;
revoke all on function booking.admin_day_shifts(date) from public, anon, authenticated;
grant execute on function booking.admin_day_shifts(date) to authenticated;
grant execute on function booking.admin_day_shifts(date) to service_role;

-- Sama ACL kuin muilla admin_*-funktioilla (admin_day_view-kuvaus ja grantit säilyvät create or replace -kutsussa).
