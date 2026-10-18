-- ============================================================
-- booking_74_company_audience: yritysten saunavuorot pois kuluttajan kalenterista.
--  * product_config.audience: consumer (oletus) | business. Yksi asetus, jolla lista korjataan hallinnassa.
--  * Ei poista tuotteita, sääntöjä eikä varauksia. shop_visible ja bookable säilyvät, jotta yritysten kalenteri voi varata samalla polulla.
--  * Tunnistus (varovainen, ei pelkkä id): Johku external_id 17 tai 41, TAI slug saunavuoro-yrityksille / jalkiloylyt-yrityksille.
--    Nämä ovat kb-fixtureissä id 48 "Savusaunavuoro yrityksille" ja id 49 "Savusaunan jälkilöylyt yrityksille".
--    Ei koske Johku 16 (Oma savusaunavuoro) eikä Johku 15 (jälkilöylyt yksityisille) eikä slugia yrityspaivat (tarjous, ei vuoro).
--  * public_catalog() jätetään ennalleen (booking_61 / myöhempi booking_64). Uusi public_catalog_for(audience) suodattaa sen tuloksen.
--  * admin_update_product_config: sallittu kenttä audience (catalog.edit).
-- Rollback: rollbacks/20261018210000_booking_74_ROLLBACK.sql
-- ============================================================
set local lock_timeout = '5s';

alter table booking.product_config add column if not exists audience text not null default 'consumer';
alter table booking.product_config drop constraint if exists product_config_audience_check;
alter table booking.product_config add constraint product_config_audience_check check (audience in ('consumer', 'business'));
comment on column booking.product_config.audience is
  'Kenelle vuoro näkyy kalenterissa: consumer = kuluttajan yleinen kalenteri, business = Yrityksille-sivun saunavuorot. Ei poista varausta.';

update booking.product_config pc
   set audience = 'business'
  from kb.products p
 where p.id = pc.product_id
   and pc.audience is distinct from 'business'
   and (
     (p.external_system = 'johku' and p.external_id in ('17', '41'))
     or p.slug in ('saunavuoro-yrityksille', 'jalkiloylyt-yrityksille')
   );

do $$
declare r record; n int := 0;
begin
  for r in
    select p.id, p.slug, p.external_system, p.external_id, p.name
      from booking.product_config pc
      join kb.products p on p.id = pc.product_id
     where pc.audience = 'business'
     order by p.id
  loop
    n := n + 1;
    raise notice 'booking_74 audience=business id=% slug=% system=% external_id=% name=%', r.id, r.slug, r.external_system, r.external_id, r.name;
  end loop;
  if n = 0 then
    raise notice 'booking_74: ei yhtään audience=business -riviä. Odotettu osuma: johku 17/41 tai slug saunavuoro-yrityksille / jalkiloylyt-yrityksille. Aseta näkyvyys hallinnan Tuotteet-näkymässä.';
  end if;
end $$;

-- Suodattaa public_catalog()-tuloksen. Ei korvaa katalogifunktion runkoa, jotta myöhempi katalogi (lisäpalvelut, aikajana) säilyy.
create or replace function booking.public_catalog_for(p_audience text default 'consumer')
returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg((e.obj || jsonb_build_object('audience', pc.audience)) order by e.ord), '[]'::jsonb)
    from jsonb_array_elements(booking.public_catalog()) with ordinality as e(obj, ord)
    join booking.product_config pc on pc.product_id = (e.obj ->> 'id')::bigint
   where pc.audience = case when lower(btrim(coalesce(p_audience, ''))) = 'business' then 'business' else 'consumer' end
$$;

revoke all on function booking.public_catalog_for(text) from public;
grant execute on function booking.public_catalog_for(text) to anon, authenticated, service_role;

-- booking_14:n allow-lista + audience. Muut kentät ennallaan.
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
