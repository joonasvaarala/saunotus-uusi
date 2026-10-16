-- =====================================================================
-- booking 05: varauksen luonti (sisäinen ydin) + JULKINEN rajapinta (anon)
-- Anon saa kutsua vain public_*-funktioita. Ne ovat SECURITY DEFINER, validoivat kaiken ja palauttavat
-- vain julkisia tietoja (ei asiakastietoja). Liiketoimintavirheet palautetaan jsonb {ok:false, code, message}
-- (ei poikkeuksena), jotta rate limit -laskuri ei kumoudu transaktion mukana.
-- =====================================================================
set local search_path = booking, extensions, public;

-- ---------- apufunktiot ----------
create or replace function booking._client_ip()
returns text language plpgsql stable set search_path = '' as $$
declare h text;
begin
  h := nullif(current_setting('request.headers', true), '');
  if h is null then return null; end if;
  begin
    return nullif(btrim(split_part(coalesce((h::json) ->> 'cf-connecting-ip', (h::json) ->> 'x-forwarded-for', ''), ',', 1)), '');
  exception when others then
    return null;
  end;
end $$;

-- Palauttaa true jos pyyntö sallitaan. Kirjaa osuman AINA (myös estetyn), jotta spämmäys ei pääse vuotamaan.
create or replace function booking._rate_limit(p_bucket text, p_max integer, p_window interval)
returns boolean language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  insert into booking.rate_limit_hits(bucket) values (p_bucket);
  select count(*) into n from booking.rate_limit_hits where bucket = p_bucket and at > now() - p_window;
  return n <= p_max;
end $$;

-- Etsii asiakkaan sähköpostilla tai luo uuden. Olemassa olevan asiakkaan tietoja ei ylikirjoiteta (vain tyhjät kentät
-- täydennetään) – julkinen varaus ei voi muokata toisen asiakkaan tietoja. Suostumus voidaan vain antaa, ei perua.
create or replace function booking._upsert_customer(
  p_name text, p_email text, p_phone text, p_marketing boolean, p_source text, p_locale text, p_text_version text default null)
returns bigint language plpgsql security definer set search_path = '' as $$
declare c booking.customers; v_id bigint;
begin
  select * into c from booking.customers
   where lower(email) = lower(p_email) and anonymized_at is null order by id desc limit 1;
  if found then
    update booking.customers set
      phone = coalesce(nullif(phone, ''), p_phone),
      marketing_consent = marketing_consent or coalesce(p_marketing, false),
      marketing_consent_at = case when not marketing_consent and coalesce(p_marketing, false) then now() else marketing_consent_at end,
      marketing_consent_source = case when not marketing_consent and coalesce(p_marketing, false) then p_source else marketing_consent_source end,
      marketing_consent_text_version = case when not marketing_consent and coalesce(p_marketing, false) then p_text_version else marketing_consent_text_version end,
      marketing_unsubscribed_at = case when not marketing_consent and coalesce(p_marketing, false) then null else marketing_unsubscribed_at end
     where id = c.id;
    return c.id;
  end if;
  insert into booking.customers(name, email, phone, language, marketing_consent, marketing_consent_at, marketing_consent_source, marketing_consent_text_version)
  values (p_name, p_email, p_phone, coalesce(p_locale, 'fi'), coalesce(p_marketing, false),
          case when coalesce(p_marketing, false) then now() end,
          case when coalesce(p_marketing, false) then p_source end,
          case when coalesce(p_marketing, false) then p_text_version end)
  returning id into v_id;
  return v_id;
end $$;

-- ---------- varauksen luonnin ydin (EI anonin eikä authenticatedin kutsuttavissa) ----------
-- p_status: 'confirmed' (esim. käsivaraus, pay_later) tai 'pending' (pito p_hold_minutes kunnes maksettu)
create or replace function booking._create_booking_core(
  p_rule_id bigint, p_date date, p_persons integer, p_customer_id bigint,
  p_channel text, p_created_by uuid, p_locale text, p_note text,
  p_status text, p_hold_minutes integer, p_enforce_deadline boolean,
  p_override_start timestamptz default null, p_override_end timestamptz default null, p_price_override numeric default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r booking.schedule_rules; pc booking.product_config; p kb.products; v kb.product_price_variants;
  s_start timestamptz; s_end timestamptz;
  pr record; v_total numeric; v_order booking.orders; v_item_id bigint; v_res_id bigint; v_pools bigint[];
  v_hold timestamptz;
begin
  select * into r from booking.schedule_rules where id = p_rule_id and active;
  if not found then perform booking._err('rule_not_found', 'Vuoroa ei löydy tai se ei ole käytössä'); end if;
  select * into pc from booking.product_config where product_id = r.product_id;
  if not found or not pc.bookable then perform booking._err('not_bookable', 'Tuotetta ei voi varata'); end if;
  select * into p from kb.products where id = r.product_id and active;
  if not found then perform booking._err('product_inactive', 'Tuote ei ole myynnissä'); end if;
  if p.vat_rate is null then perform booking._err('vat_missing', 'Tuotteelta puuttuu ALV-kanta'); end if;
  if r.price_variant_id is not null then select * into v from kb.product_price_variants where id = r.price_variant_id; end if;

  if p_persons is null or p_persons < r.min_persons then
    perform booking._err('persons_min', format('Vähimmäishenkilömäärä on %s', r.min_persons));
  end if;
  if r.max_persons is not null and p_persons > r.max_persons then
    perform booking._err('persons_max', format('Enimmäishenkilömäärä on %s', r.max_persons));
  end if;
  if pc.max_persons is not null and p_persons > pc.max_persons then
    perform booking._err('persons_max', format('Enimmäishenkilömäärä on %s', pc.max_persons));
  end if;

  if p_override_start is not null then
    -- vapaa aika (vain käsivaraus / admin): vain yksityisvuoroille
    if r.mode <> 'exclusive' then perform booking._err('override_not_allowed', 'Mukautettu aika on sallittu vain yksityisvuoroille'); end if;
    s_start := p_override_start; s_end := p_override_end;
    if s_end is null or s_end <= s_start then perform booking._err('bad_time', 'Virheellinen aika'); end if;
  else
    if not (extract(isodow from p_date)::smallint = any (r.weekdays))
       or (r.valid_from is not null and p_date < r.valid_from) or (r.valid_to is not null and p_date > r.valid_to)
       or (v.id is not null and (not v.active or (v.valid_from is not null and p_date < v.valid_from) or (v.valid_to is not null and p_date > v.valid_to)))
       or (p.valid_from is not null and p_date < p.valid_from) or (p.valid_to is not null and p_date > p.valid_to) then
      perform booking._err('no_session', 'Valitulle päivälle ei ole tätä vuoroa');
    end if;
    s_start := (p_date + r.start_time) at time zone booking._tz();
    s_end   := (p_date + r.start_time + make_interval(mins => r.duration_minutes)) at time zone booking._tz();
  end if;

  if p_enforce_deadline and s_start - make_interval(mins => r.deadline_minutes) <= now() then
    perform booking._err('sale_closed', 'Vuoron myynti on päättynyt');
  end if;

  select * into pr from booking._rule_price(p_rule_id, p_persons);
  v_total := coalesce(p_price_override, pr.total);
  select array_agg(pool_id order by pool_id) into v_pools from booking.schedule_rule_pools where rule_id = r.id;

  insert into booking.orders(customer_id, status, payment_status, total_gross, source_channel, locale, customer_note, created_by)
  values (p_customer_id, case when p_status = 'confirmed' then 'confirmed' else 'pending' end, 'unpaid', v_total,
          p_channel, coalesce(p_locale, 'fi'), p_note, p_created_by)
  returning * into v_order;
  if p_status = 'confirmed' then update booking.orders set confirmed_at = now() where id = v_order.id; end if;

  insert into booking.order_items(order_id, product_id, product_name, kind, quantity, unit_price_gross, line_total_gross, vat_rate, price_breakdown)
  values (v_order.id, p.id, p.name, 'reservation', 1, v_total, v_total, p.vat_rate,
          pr.breakdown || jsonb_build_object('rule_id', r.id, 'rule_label', r.label))
  returning id into v_item_id;

  v_hold := case when p_status = 'pending' then now() + make_interval(mins => greatest(coalesce(p_hold_minutes, 15), 1)) end;
  -- Trigger reservations_validate lukitsee tilan ja tarkistaa päällekkäisyydet/kapasiteetin; virhe kumoaa koko lisäyksen.
  insert into booking.reservations(order_id, order_item_id, product_id, rule_id, space_id, mode, starts_at, ends_at, persons,
                                   pool_ids, status, hold_expires_at, created_by)
  values (v_order.id, v_item_id, p.id, r.id, r.space_id, r.mode, s_start, s_end, p_persons,
          coalesce(v_pools, '{}'), p_status, v_hold, p_created_by)
  returning id into v_res_id;

  return jsonb_build_object('order_id', v_order.id, 'order_no', v_order.order_no, 'public_token', v_order.public_token,
                            'reservation_id', v_res_id, 'total', v_total, 'starts_at', s_start, 'ends_at', s_end,
                            'status', p_status, 'hold_expires_at', v_hold, 'product_name', p.name);
end $$;

-- ---------- JULKISET FUNKTIOT ----------
create or replace function booking.public_settings()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) from booking.settings where is_public
$$;

-- Varattavat tuotteet kauppapaikkaan (nimet/hinnat kb:stä). Ei sisäisiä tietoja.
create or replace function booking.public_catalog()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'slug', p.slug, 'name', p.name, 'name_en', p.name_en,
      'description', p.description, 'description_en', p.description_en,
      'category', p.category, 'sale_kind', pc.sale_kind,
      'price', p.price, 'price_type', p.price_type, 'price_text', p.price_text,
      'duration_text', p.duration_text, 'duration_minutes', p.duration_minutes,
      'min_persons', pc.min_persons, 'max_persons', pc.max_persons
    ) order by pc.sort_order, p.id), '[]'::jsonb)
  from booking.product_config pc
  join kb.products p on p.id = pc.product_id and p.active
  where pc.bookable and pc.shop_visible
    and exists (select 1 from booking.schedule_rules r where r.product_id = p.id and r.active)
$$;

-- Vuorot ja vapaat paikat. Rajattu max 92 pv/haku.
create or replace function booking.public_availability(p_product_id bigint, p_from date, p_to date)
returns table (
  rule_id bigint, label text, mode text, session_date date, starts_at timestamptz, ends_at timestamptz, status text,
  remaining integer, min_persons integer, max_persons integer,
  price_mode text, unit_price numeric, base_price numeric, included_persons integer, extra_person_price numeric)
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_product_id is null or p_from is null or p_to is null or p_to < p_from or p_to - p_from > 92 then
    perform booking._err('bad_range', 'Virheellinen päiväväli (enintään 92 päivää)');
  end if;
  if not exists (select 1 from booking.product_config pc where pc.product_id = p_product_id and pc.bookable and pc.shop_visible) then
    return;
  end if;
  return query
    select s.rule_id, s.label, s.mode, s.session_date, s.starts_at, s.ends_at,
           case when s.status = 'closed' then 'closed' else s.status end,
           s.remaining, s.min_persons, s.max_persons, s.price_mode, s.unit_price, s.base_price, s.included_persons, s.extra_person_price
      from booking._sessions(greatest(p_from, (now() at time zone booking._tz())::date),
                             least(p_to, (now() at time zone booking._tz())::date + (booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int),
                             p_product_id, true) s
     where s.status <> 'closed';
end $$;

-- Luo varauksen julkisesti. Palauttaa aina jsonb: {ok:true,...} tai {ok:false, code, message}.
create or replace function booking.public_create_booking(
  p_rule_id bigint, p_date date, p_persons integer,
  p_name text, p_email text, p_phone text,
  p_marketing_consent boolean default false, p_locale text default 'fi', p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_mode text := booking._setting('public_payment_mode', '"pay_later"'::jsonb) #>> '{}';
  v_ip text := booking._client_ip();
  v_cust bigint; v_res jsonb; v_status text; v_pay_method text; v_pay_provider text;
  v_email text := lower(btrim(coalesce(p_email, ''))); v_name text := btrim(coalesce(p_name, '')); v_phone text := btrim(coalesce(p_phone, ''));
  v_detail text; v_msg text;
  v_hold int := (booking._setting('hold_minutes', '15'::jsonb) #>> '{}')::int;
begin
  if not coalesce((booking._setting('public_booking_enabled', 'true'::jsonb) #>> '{}')::boolean, true) then
    return jsonb_build_object('ok', false, 'code', 'booking_disabled', 'message', 'Verkkovaraus ei ole tällä hetkellä käytössä');
  end if;

  -- rate limit (kirjataan myös estetyt yritykset)
  if v_ip is not null and not booking._rate_limit('ip:' || v_ip, (booking._setting('rl_ip_per_10min', '12'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_email <> '' and not booking._rate_limit('email:' || v_email, (booking._setting('rl_email_per_10min', '5'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;

  -- syötteiden validointi
  if char_length(v_name) < 2 or char_length(v_name) > 120 then
    return jsonb_build_object('ok', false, 'code', 'invalid_name', 'message', 'Anna nimi');
  end if;
  if char_length(v_email) > 254 or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$' then
    return jsonb_build_object('ok', false, 'code', 'invalid_email', 'message', 'Tarkista sähköpostiosoite');
  end if;
  if v_phone !~ '^[0-9+()\- ]{6,30}$' then
    return jsonb_build_object('ok', false, 'code', 'invalid_phone', 'message', 'Tarkista puhelinnumero');
  end if;
  if p_persons is null or p_persons < 1 or p_persons > 50 then
    return jsonb_build_object('ok', false, 'code', 'invalid_persons', 'message', 'Tarkista henkilömäärä');
  end if;
  if p_note is not null and char_length(p_note) > 1000 then
    return jsonb_build_object('ok', false, 'code', 'invalid_note', 'message', 'Viesti on liian pitkä');
  end if;
  if p_date is null or p_date < (now() at time zone booking._tz())::date
     or p_date > (now() at time zone booking._tz())::date + (booking._setting('booking_horizon_days', '120'::jsonb) #>> '{}')::int then
    return jsonb_build_object('ok', false, 'code', 'invalid_date', 'message', 'Päivä ei ole varattavissa');
  end if;
  -- rajoita samanaikaisia maksamattomia pitoja / sähköposti
  if (select count(*) from booking.orders o join booking.customers c on c.id = o.customer_id
       where lower(c.email) = v_email and o.status = 'pending' and o.created_at > now() - interval '1 hour') >= 3 then
    return jsonb_build_object('ok', false, 'code', 'too_many_pending', 'message', 'Sinulla on jo useita keskeneräisiä varauksia');
  end if;

  v_status := case when v_mode = 'pay_later' then 'confirmed' else 'pending' end;
  v_pay_method := case when v_mode = 'pay_later' then 'pay_later' else 'visma_pay' end;
  v_pay_provider := case when v_mode = 'pay_later' then 'manual' else 'visma_pay' end;

  begin  -- alitransaktio: virhe kumoaa asiakkaan/tilauksen/varauksen luonnin mutta rate limit -kirjaus säilyy
    v_cust := booking._upsert_customer(v_name, v_email, v_phone, p_marketing_consent, 'web_booking', p_locale,
                                       (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    v_res := booking._create_booking_core(p_rule_id, p_date, p_persons, v_cust, 'web', null, p_locale, p_note,
                                          v_status, v_hold, true);
    insert into booking.payments(order_id, method, provider, status, amount)
    values ((v_res ->> 'order_id')::bigint, v_pay_method, v_pay_provider, 'pending', (v_res ->> 'total')::numeric);
    update booking.orders set payment_status = case when v_mode = 'pay_later' then 'unpaid' else 'pending' end
     where id = (v_res ->> 'order_id')::bigint;
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;

  return jsonb_build_object('ok', true, 'order_no', v_res -> 'order_no', 'token', v_res -> 'public_token',
                            'status', v_status, 'starts_at', v_res -> 'starts_at', 'ends_at', v_res -> 'ends_at',
                            'total', v_res -> 'total', 'hold_expires_at', v_res -> 'hold_expires_at',
                            'payment_mode', v_mode, 'payment_url', null, 'product_name', v_res -> 'product_name');
end $$;

-- Vahvistussivu: haetaan salaisella tokenilla. Ei sisällä asiakastietoja (vain etunimi).
create or replace function booking.public_get_booking(p_token uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare o booking.orders; res jsonb; cust text;
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select split_part(c.name, ' ', 1) into cust from booking.customers c where c.id = o.customer_id;
  select jsonb_agg(jsonb_build_object(
           'product_name', it.product_name, 'quantity', it.quantity, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate,
           'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'mode', r.mode,
           'status', case when r.status = 'pending' and r.hold_expires_at <= now() then 'expired' else r.status end,
           'hold_expires_at', r.hold_expires_at) order by r.starts_at)
    into res
    from booking.order_items it left join booking.reservations r on r.order_item_id = it.id
   where it.order_id = o.id;
  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'status',
           case when o.status = 'pending' and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now()) then 'expired' else o.status end,
           'payment_status', o.payment_status, 'total', o.total_gross, 'currency', o.currency, 'created_at', o.created_at,
           'first_name', cust, 'items', coalesce(res, '[]'::jsonb),
           'payment_methods', (select coalesce(jsonb_agg(p.method), '[]'::jsonb) from booking.payments p where p.order_id = o.id));
end $$;

-- Asiakas voi perua vielä maksamattoman (pending) varauksen itse; vahvistetut peruutetaan ehtojen mukaan yhteydenotolla.
create or replace function booking.public_cancel_booking(p_token uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o booking.orders; n int;
begin
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  update booking.reservations set status = 'cancelled', cancelled_at = now(), cancel_reason = 'customer_cancelled_pending'
   where order_id = o.id and status = 'pending';
  get diagnostics n = row_count;
  if n = 0 then
    return jsonb_build_object('ok', false, 'code', 'not_cancellable', 'message', 'Vahvistettu varaus perutaan ottamalla yhteyttä: ks. peruutusehdot');
  end if;
  update booking.orders set status = 'cancelled', cancelled_at = now() where id = o.id and status = 'pending';
  update booking.payments set status = 'cancelled' where order_id = o.id and status = 'pending';
  return jsonb_build_object('ok', true);
end $$;
