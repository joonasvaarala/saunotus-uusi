-- PROD-määrittely ennen booking_239:ää (md5 sama DEV/PROD, 3.11.2026)
CREATE OR REPLACE FUNCTION booking.admin_save_discount_code(p_id bigint, p_data jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  d booking.discount_codes; v_annual boolean := coalesce((p_data ->> 'is_annual_card_code')::boolean, false);
  v_code text := booking._norm_code(p_data ->> 'code'); v_kind text := coalesce(p_data ->> 'kind', 'percent');
  v_value numeric; v_usage text := coalesce(p_data ->> 'usage_type', 'single'); v_scope text := coalesce(p_data ->> 'target_scope', 'order');
  v_max int; v_pids bigint[]; v_from date; v_to date; v_desc text := nullif(btrim(coalesce(p_data ->> 'description', '')), '');
begin
  perform booking._require_permission('catalog.edit');
  if p_id is not null then
    select * into d from booking.discount_codes where id = p_id for update;
    if d.id is null then perform booking._err('not_found', 'Koodia ei löydy'); end if;
  end if;
  if v_annual or coalesce(d.is_annual_card_code, false) then perform booking._require_permission('annual_cards.manage'); end if;
  if v_code = '' then v_code := booking._generate_discount_code(); end if;
  if v_code !~ '^[A-Z0-9-]{3,40}$' then perform booking._err('invalid_code', 'Koodissa saa olla 3–40 merkkiä: kirjaimia A–Z, numeroita ja väliviivoja'); end if;
  if v_kind not in ('percent', 'fixed') then perform booking._err('invalid_kind', 'Valitse prosentti tai euromäärä'); end if;
  if coalesce(p_data ->> 'value', '') !~ '^\d{1,6}(\.\d{1,2})?$' then perform booking._err('invalid_value', 'Tarkista alennuksen määrä'); end if;
  v_value := (p_data ->> 'value')::numeric;
  if v_value <= 0 or (v_kind = 'percent' and v_value > 100) then perform booking._err('invalid_value', 'Prosentti 0–100, euromäärä yli 0'); end if;
  if v_usage not in ('single', 'multi', 'permanent') then perform booking._err('invalid_usage', 'Tarkista käyttökerrat'); end if;
  if v_usage = 'multi' then
    if coalesce(p_data ->> 'max_uses', '') !~ '^\d{1,6}$' or (p_data ->> 'max_uses')::int < 2 then perform booking._err('invalid_max_uses', 'Käyttökertoja vähintään 2'); end if;
    v_max := (p_data ->> 'max_uses')::int;
  end if;
  if v_scope not in ('order', 'product') then perform booking._err('invalid_scope', 'Tarkista kohdistus'); end if;
  if v_scope = 'product' then
    select coalesce(array_agg(distinct x::bigint order by x::bigint), '{}') into v_pids
      from jsonb_array_elements_text(case when jsonb_typeof(p_data -> 'product_ids') = 'array' then p_data -> 'product_ids' else '[]'::jsonb end) x where x ~ '^\d{1,18}$';
    if exists (select 1 from unnest(v_pids) u where not exists (select 1 from kb.products p where p.id = u)) then
      perform booking._err('invalid_products', 'Tuntematon tuote');
    end if;
  end if;
  begin
    v_from := nullif(p_data ->> 'valid_from', '')::date; v_to := nullif(p_data ->> 'valid_to', '')::date;
  exception when others then perform booking._err('invalid_dates', 'Tarkista päivämäärät'); end;
  if v_from is not null and v_to is not null and v_to < v_from then perform booking._err('invalid_dates', 'Päättymispäivä ennen alkua'); end if;
  if v_desc is not null and char_length(v_desc) > 300 then perform booking._err('invalid_description', 'Kuvaus on liian pitkä'); end if;
  if v_annual then v_kind := 'percent'; v_value := 100; v_usage := 'permanent'; v_scope := 'product'; v_max := null; end if;
  if exists (select 1 from booking.discount_codes where code = v_code and id is distinct from p_id) then
    perform booking._err('code_exists', 'Koodi on jo käytössä');
  end if;
  if p_id is null then
    insert into booking.discount_codes(code, description, kind, value, valid_from, valid_to, max_uses, product_ids, active, target_scope, usage_type, is_annual_card_code)
    values (v_code, v_desc, v_kind, v_value, v_from, v_to, v_max, case when v_scope = 'product' then v_pids end,
            coalesce((p_data ->> 'active')::boolean, true), v_scope, v_usage, v_annual)
    returning * into d;
  else
    if v_usage <> 'permanent' and v_max is null and v_usage = 'single' then v_max := 1; end if;
    if v_max is not null and v_max < d.used_count then perform booking._err('invalid_max_uses', 'Käyttökertoja ei voi asettaa alle jo käytetyn määrän'); end if;
    update booking.discount_codes set code = v_code, description = v_desc, kind = v_kind, value = v_value, valid_from = v_from, valid_to = v_to,
           max_uses = v_max, product_ids = case when v_scope = 'product' then v_pids end, active = coalesce((p_data ->> 'active')::boolean, active),
           target_scope = v_scope, usage_type = v_usage, is_annual_card_code = v_annual
     where id = p_id returning * into d;
  end if;
  return jsonb_build_object('ok', true, 'id', d.id, 'code', d.code);
end $function$;
