-- =============================================================================
-- booking_145_giftcard_list_search.sql (hallinta › Talous › Lahjakortit: haku, aakkosjärjestys, tuotteen nimi)
-- =============================================================================
-- Kirjoittaa vain booking-skeemaan. Ei uusia tauluja, sarakkeita, oikeuksia eikä datamuutoksia. Ei muuta hintoja eikä ALV:tä.
-- booking.admin_list_gift_cards (sama allekirjoitus ja paluutyyppi kuin booking_44:ssä → oikeudet säilyvät create or replacessa):
--  1) Tuotteen nimi riville: product_name = paketin nimi (gift_card_packages.name) → kb.products.name (product_id)
--     → Johku-mallin nimi (external_meta.template). Tuotannossa Johku-korteilla (961 kpl 24.10.2026) ei ole package_codea,
--     joten package_name on niillä tyhjä; product_id on 861:llä ja loput 100 tunnistetaan Johku-mallin nimestä.
--  2) Haku (kirjainkoosta riippumaton, ilike) kattaa myös tuotteen nimen (sama lauseke kuin kohdassa 1).
--     Koodi-, nimi-, sähköposti- ja tilausnumerohaku ennallaan.
--  3) Uusi järjestys p_sort = 'name_asc': saajan nimi, jos tyhjä niin ostajan nimi, suomalaisella aakkostuksella
--     (ICU fi-x-icu: … X Y Z Å Ä Ö), kirjainkoosta riippumatta; nimettömät viimeisinä, sitten koodi ja id.
--     Muut järjestykset ennallaan (oletus created_desc = uusin ensin, created_asc = vanhin ensin; created_asc:n tasatilanteet nyt id:n
--     mukaan nousevasti, ennen laskevasti).
-- Staff-tarkistus (booking.is_staff()), SECURITY DEFINER ja search_path '' kuten ennen.
-- Rollback: rollbacks/20261024180000_booking_145_ROLLBACK.sql (palauttaa booking_44:n määritelmän täsmälleen).
-- =============================================================================
set local lock_timeout = '5s';

create or replace function booking._gc_product_name(g booking.gift_cards) returns text
language sql stable security definer set search_path to ''
as $$
  select coalesce((select nullif(btrim(p.name), '') from booking.gift_card_packages p where p.code = g.package_code),
                  (select nullif(btrim(k.name), '') from kb.products k where k.id = g.product_id),
                  nullif(btrim(g.external_meta ->> 'template'), ''))
$$;
revoke all on function booking._gc_product_name(booking.gift_cards) from public, anon, authenticated;
grant execute on function booking._gc_product_name(booking.gift_cards) to service_role;

create or replace function booking.admin_list_gift_cards(p_search text default null, p_status text default null, p_source text default null, p_kind text default null,
    p_package text default null, p_vat_treatment text default null, p_unverified boolean default null, p_expiring_days int default null, p_has_balance boolean default null,
    p_sort text default 'created_desc', p_limit int default 50, p_offset int default 0) returns jsonb
language plpgsql stable security definer set search_path to ''
as $$
declare v_s text := nullif(btrim(coalesce(p_search, '')), ''); v_norm text; v_res jsonb; v_today date := booking._gc_today(); v_lim int := least(greatest(coalesce(p_limit, 50), 1), 200); v_off int := greatest(coalesce(p_offset, 0), 0);
begin
  if not booking.is_staff() then perform booking._err('forbidden', 'Ei oikeuksia'); end if;
  if coalesce(p_sort, 'created_desc') not in ('created_desc', 'created_asc', 'name_asc', 'valid_to_asc', 'valid_to_desc', 'balance_desc', 'balance_asc', 'initial_desc', 'initial_asc') then perform booking._err('invalid_sort', 'Tuntematon lajittelu'); end if;
  if p_status is not null and p_status not in ('active', 'used', 'expired', 'cancelled', 'pending_verification', 'pending_payment') then perform booking._err('invalid_param', 'Virheellinen tila'); end if;
  v_norm := booking.gift_code_norm(v_s);
  with f as (
    select g.*, booking._gc_product_name(g) as pname from booking.gift_cards g
     where (v_s is null or (char_length(v_norm) >= 4 and g.code like '%' || v_norm || '%')
            or g.buyer_name ilike '%' || v_s || '%' or g.buyer_email ilike '%' || v_s || '%' or g.recipient_name ilike '%' || v_s || '%' or g.recipient_email ilike '%' || v_s || '%'
            or booking._gc_product_name(g) ilike '%' || v_s || '%'
            or (v_s ~ '^\d{1,10}$' and exists (select 1 from booking.orders o where o.id = g.purchase_order_id and (o.order_no = v_s::bigint or o.johku_order_no = v_s::bigint))))
       and (p_status is null or case when p_status = 'expired' then (g.status = 'expired' or (g.status = 'active' and g.valid_to < v_today)) when p_status = 'active' then g.status = 'active' and (g.valid_to is null or g.valid_to >= v_today) else g.status = p_status end)
       and (p_source is null or g.source = p_source) and (p_kind is null or g.kind = p_kind) and (p_package is null or g.package_code = p_package)
       and (p_vat_treatment is null or g.vat_treatment = p_vat_treatment) and (p_unverified is null or g.balance_verified = not p_unverified)
       and (p_expiring_days is null or (g.status = 'active' and g.valid_to between v_today and v_today + p_expiring_days))
       and (p_has_balance is null or (g.balance > 0) = p_has_balance)
  ), s as (
    select count(*) c, coalesce(sum(balance), 0) sb, coalesce(sum(initial_amount), 0) si,
           coalesce(sum(balance) filter (where status = 'active' and (valid_to is null or valid_to >= v_today)), 0) sr from f
  ), r as (
    select f.id, f.pname, row_number() over (order by
        (case when p_sort = 'name_asc' then lower(coalesce(nullif(btrim(f.recipient_name), ''), nullif(btrim(f.buyer_name), ''))) end) collate "fi-x-icu" asc nulls last,
        (case when p_sort = 'name_asc' then f.code end) asc,
        (case when p_sort = 'valid_to_asc' then f.valid_to end) asc nulls last, (case when p_sort = 'valid_to_desc' then f.valid_to end) desc nulls last,
        (case when p_sort = 'balance_desc' then f.balance end) desc, (case when p_sort = 'balance_asc' then f.balance end) asc,
        (case when p_sort = 'initial_desc' then f.initial_amount end) desc, (case when p_sort = 'initial_asc' then f.initial_amount end) asc,
        (case when p_sort = 'created_asc' then f.created_at end) asc, (case when p_sort = 'created_asc' then f.id end) asc, f.created_at desc, f.id desc) rn from f
  )
  select jsonb_build_object('total', s.c, 'sum_balance', s.sb, 'sum_initial', s.si, 'sum_balance_redeemable', s.sr,
      'rows', coalesce((select jsonb_agg(booking._gc_card_json(g2, true) || jsonb_build_object('product_name', r.pname) order by r.rn)
                          from r join booking.gift_cards g2 on g2.id = r.id where r.rn > v_off and r.rn <= v_off + v_lim), '[]'::jsonb))
    into v_res from s;
  return v_res;
end $$;
