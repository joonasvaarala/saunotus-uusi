-- ============================================================
-- booking_61_package_catalog: paketin (tuote 7) tietokantapuolen viimeistely + tekstisäännön noudattaminen (kaikki asiakasnäkyvät tekstit tietokantaan)
--  a) public_catalog(): description_en (tuote 7), voucher_note / voucher_note_en (lahjakorttihuomautus erilleen kuvauksesta), aikajana (timeline, timeline_text, timeline_text_en)
--  b) booking.product_timeline_segments: rakenteiset osavaiheet (nimi FI/EN + minuutit); teksti johdetaan osavaiheista, kesto = osavaiheiden summa (muuten aikajanaa ei näytetä)
--  c) public_settings(): public_treatment_horizon_days näkyviin (kauppa ei kovakoodaa 14)
--  d) public_create_treatment_booking(): uusi valinnainen p_addons (lisäpalvelut kuten public_create_booking); _public_slot_error välittää addon_*-koodit
--  e) site_texts: needs_review/review_note (EN koneluonnos -> massatarkistus), lähteiksi product_config.voucher_note(_en) ja product_timeline_segments.label(_en), admin_texts_mark_reviewed
--  Hintoja, ALV:tä tai julkaisua ei muuteta. Rollback: rollbacks/CHECKOUT_booking_61_ROLLBACK.sql
-- ============================================================
set local lock_timeout = '5s';

-- ---------- e) site_texts-laajennukset ----------
alter table booking.site_texts add column if not exists needs_review boolean not null default false, add column if not exists review_note text;
alter table booking.site_texts drop constraint if exists site_texts_source_table_check;
alter table booking.site_texts add constraint site_texts_source_table_check check (source_table in ('kb.products', 'kb.faq', 'kb.policies', 'kb.locations', 'kb.opening_hours', 'kb.event_dates', 'kb.businesses',
  'booking.addons', 'booking.product_options', 'booking.gift_card_packages', 'booking.schedule_rules', 'booking.product_config', 'booking.product_timeline_segments'));
alter table booking.site_texts drop constraint if exists site_texts_source_pk_col_check;
alter table booking.site_texts add constraint site_texts_source_pk_col_check check (source_pk_col in ('id', 'code', 'product_id'));

-- ---------- uudet tietokentät ----------
alter table booking.product_config add column if not exists voucher_note text, add column if not exists voucher_note_en text;
comment on column booking.product_config.voucher_note is 'Asiakasnäkyvä huomautus lahjakortilla maksavalle (FI). Teksti hallitaan site_texts-järjestelmässä (suojattu luokka).';

create table booking.product_timeline_segments (
  id bigserial primary key,
  product_id bigint not null references kb.products(id) on delete cascade,
  seq integer not null check (seq between 1 and 20),
  kind text not null check (kind in ('ritual', 'break', 'sauna', 'smoke_sauna', 'treatment', 'other')),
  label text not null check (btrim(label) <> '' and char_length(label) <= 60),
  label_en text check (label_en is null or (btrim(label_en) <> '' and char_length(label_en) <= 60)),
  minutes integer not null check (minutes between 1 and 720),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (product_id, seq)
);
create trigger product_timeline_segments_updated before update on booking.product_timeline_segments for each row execute function booking.set_updated_at();
alter table booking.product_timeline_segments enable row level security;
revoke all on booking.product_timeline_segments from anon, authenticated;
revoke all on sequence booking.product_timeline_segments_id_seq from anon, authenticated;

create or replace function booking._fmt_minutes(p_min integer) returns text language sql immutable set search_path = '' as $$
  select case when p_min is null then null when p_min < 60 then p_min || ' min' when p_min % 60 = 0 then (p_min / 60) || ' h' else (p_min / 60) || ' h ' || (p_min % 60) || ' min' end $$;

-- aikajana: osavaiheet + johdetut tekstit; null jos osavaiheita ei ole tai summa <> tuotteen kesto
create or replace function booking._timeline_json(p_product_id bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_dur integer; v_sum integer; v_n integer; v_segs jsonb; v_txt text; v_txt_en text; v_en_ok boolean;
begin
  select count(*), coalesce(sum(minutes), 0), bool_and(label_en is not null) into v_n, v_sum, v_en_ok from booking.product_timeline_segments where product_id = p_product_id;
  if v_n = 0 then return null; end if;
  select duration_minutes into v_dur from booking.product_config where product_id = p_product_id;
  if v_dur is distinct from v_sum then return null; end if;
  select jsonb_agg(jsonb_build_object('seq', x.seq, 'kind', x.kind, 'label', x.label, 'label_en', x.label_en, 'minutes', x.minutes, 'start_min', x.st, 'end_min', x.st + x.minutes) order by x.seq),
         string_agg(x.label || ' ' || booking._fmt_minutes(x.minutes), ' · ' order by x.seq),
         string_agg(x.label_en || ' ' || booking._fmt_minutes(x.minutes), ' · ' order by x.seq)
    into v_segs, v_txt, v_txt_en
    from (select s.*, coalesce(sum(s.minutes) over (order by s.seq rows between unbounded preceding and 1 preceding), 0)::int st from booking.product_timeline_segments s where s.product_id = p_product_id) x;
  return jsonb_build_object('segments', v_segs, 'text', v_txt, 'text_en', case when v_en_ok then v_txt_en end, 'total_minutes', v_sum);
end $$;

-- ---------- a) public_catalog ----------
create or replace function booking.public_catalog() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'slug', p.slug, 'name', p.name, 'name_en', p.name_en,
      'description', p.description, 'description_en', p.description_en,
      'category', p.category, 'sale_kind', pc.sale_kind,
      'price', p.price, 'price_type', p.price_type, 'price_text', p.price_text,
      'duration_text', p.duration_text, 'duration_minutes', p.duration_minutes,
      'min_persons', pc.min_persons, 'max_persons', case when pc.public_slots then booking._treatment_max_persons(p.id) else pc.max_persons end,
      'booking_kind', case when pc.public_slots then 'slots' else 'rules' end, 'slot_grid_minutes', case when pc.public_slots then 30 end,
      'options', booking._product_options_json(p.id, true), 'option_required', (pc.option_required and exists (select 1 from booking.product_options x where x.product_id = p.id and x.active)),
      'option_label', pc.option_label, 'option_label_en', pc.option_label_en,
      'voucher_note', pc.voucher_note, 'voucher_note_en', pc.voucher_note_en,
      'timeline', booking._timeline_json(p.id) -> 'segments', 'timeline_text', booking._timeline_json(p.id) ->> 'text', 'timeline_text_en', booking._timeline_json(p.id) ->> 'text_en'
    ) order by pc.sort_order, p.id), '[]'::jsonb)
  from booking.product_config pc
  join kb.products p on p.id = pc.product_id and p.active
  where pc.bookable and pc.shop_visible and pc.lifecycle = 'current'
    and (pc.public_slots or exists (select 1 from booking.schedule_rules r where r.product_id = p.id and r.active)) $$;

-- ---------- d) lisäpalvelut hoito-/rituaalivaraukseen ----------
create or replace function booking._public_slot_error(p_detail text, p_msg text) returns jsonb
language sql immutable set search_path = '' as $$
  select case when p_detail in ('not_bookable', 'invalid_persons', 'bad_slot', 'too_soon', 'too_far', 'invalid_date', 'not_offered_day', 'ritual_start', 'time_window',
                                'change_too_late', 'price_change_requires_staff', 'vat_missing', 'option_required', 'invalid_option',
                                'invalid_addons', 'addon_not_found', 'addon_inactive', 'addon_not_allowed', 'addon_quantity')
              then jsonb_build_object('ok', false, 'code', p_detail, 'message', p_msg)
              else jsonb_build_object('ok', false, 'code', 'slot_unavailable', 'message', 'Valittu aika ei ole enää varattavissa – valitse toinen aika') end $$;

drop function if exists booking.public_create_treatment_booking(bigint, timestamptz, integer, text, text, text, boolean, text, text, text, jsonb, text);
create or replace function booking.public_create_treatment_booking(p_product_id bigint, p_start timestamp with time zone, p_persons integer, p_name text, p_email text, p_phone text, p_marketing_consent boolean DEFAULT false, p_locale text DEFAULT 'fi'::text, p_note text DEFAULT NULL::text, p_customer_kind text DEFAULT 'private'::text, p_company jsonb DEFAULT NULL::jsonb, p_option_code text DEFAULT NULL::text, p_addons jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET lock_timeout TO '3s'
AS $function$
declare
  v_ip text := booking._client_ip();
  v_email text := lower(btrim(coalesce(p_email, ''))); v_name text := btrim(coalesce(p_name, '')); v_phone text := btrim(coalesce(p_phone, ''));
  v_kind text := lower(btrim(coalesce(nullif(p_customer_kind, ''), 'private'))); v_is_company boolean; v_company jsonb;
  v_mode text := booking._setting('public_payment_mode', '"pay_later"'::jsonb) #>> '{}'; v_invoice boolean; v_hold_mode boolean; v_group boolean; v_hmin int; v_thr int := booking._checkout_cfg_int('checkout_group_threshold_persons', 0, 0, 1000);
  v_cust bigint; v_res jsonb; v_end timestamptz; v_total numeric; v_token uuid; v_detail text; v_msg text; v_pay_method text; v_order bigint; v_opt bigint; v_add numeric := 0;
begin
  if not coalesce((booking._setting('public_booking_enabled', 'true'::jsonb) #>> '{}')::boolean, true) then
    return jsonb_build_object('ok', false, 'code', 'booking_disabled', 'message', 'Verkkovaraus ei ole tällä hetkellä käytössä');
  end if;
  if v_ip is not null and not booking._rate_limit('ip:' || v_ip, (booking._setting('rl_ip_per_10min', '12'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_email <> '' and not booking._rate_limit('email:' || v_email, (booking._setting('rl_email_per_10min', '5'::jsonb) #>> '{}')::int, interval '10 minutes') then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  select k.is_company into v_is_company from booking.customer_kinds k where k.code = v_kind and k.active;
  if v_is_company is null then return jsonb_build_object('ok', false, 'code', 'invalid_customer_kind', 'message', 'Valitse asiakastyyppi (yksityinen / yritys)'); end if;
  v_invoice := v_is_company and coalesce((booking._setting('checkout_company_invoice_enabled', 'true'::jsonb) #>> '{}')::boolean, true);
  v_hold_mode := v_mode <> 'pay_later' and not v_invoice;                        -- booking_53: pitotila
  v_group := v_hold_mode and v_thr > 0 and coalesce(p_persons, 0) >= v_thr;
  if v_hold_mode and not v_group and not booking._checkout_online_available() then
    return jsonb_build_object('ok', false, 'code', 'online_payment_unavailable', 'message', 'Verkkomaksu ei ole tilapäisesti käytettävissä – varausta ei voi tehdä juuri nyt');
  end if;
  v_hmin := case when not v_hold_mode then 0 when v_group then booking._checkout_cfg_int('checkout_group_hold_days', 7, 1, 60) * 1440 else booking._checkout_hold_minutes() end;
  if char_length(v_name) < 2 or char_length(v_name) > 120 then
    return jsonb_build_object('ok', false, 'code', 'invalid_name', 'message', case when v_is_company then 'Anna yhteyshenkilön nimi' else 'Anna nimi' end);
  end if;
  if not booking._valid_email(v_email) then return jsonb_build_object('ok', false, 'code', 'invalid_email', 'message', 'Tarkista sähköpostiosoite'); end if;
  if v_phone !~ '^[0-9+()\- ]{6,30}$' then return jsonb_build_object('ok', false, 'code', 'invalid_phone', 'message', 'Tarkista puhelinnumero'); end if;
  if p_note is not null and char_length(p_note) > 1000 then return jsonb_build_object('ok', false, 'code', 'invalid_note', 'message', 'Viesti on liian pitkä'); end if;
  -- suojakatkaisimet: pay_later ei vaadi maksua -> rajataan väärinkäyttö (sähköposti / kokonaismäärä)
  if (select count(*) from booking.orders o join booking.customers c on c.id = o.customer_id join booking.reservations r on r.order_id = o.id
        join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots
       where lower(c.email) = v_email and o.source_channel = 'web' and o.status = 'confirmed' and r.status = 'confirmed' and r.starts_at > now()
         and o.payment_status = 'unpaid') >= coalesce((booking._setting('public_treatment_max_open_per_email', '5'::jsonb) #>> '{}')::int, 5) then
    return jsonb_build_object('ok', false, 'code', 'too_many_open', 'message', 'Sinulla on jo useita tulevia varauksia – ota yhteyttä sähköpostitse');
  end if;
  if v_hold_mode and (select count(*) from booking.orders o join booking.customers c on c.id = o.customer_id
       where lower(c.email) = v_email and o.status = 'pending' and o.created_at > now() - interval '1 hour') >= 3 then
    return jsonb_build_object('ok', false, 'code', 'too_many_pending', 'message', 'Sinulla on jo useita keskeneräisiä varauksia');
  end if;
  if (select count(*) from booking.orders o join booking.reservations r on r.order_id = o.id join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots
       where o.source_channel = 'web' and o.created_at > now() - interval '1 hour') >= coalesce((booking._setting('public_treatment_global_per_hour', '30'::jsonb) #>> '{}')::int, 30) then
    return jsonb_build_object('ok', false, 'code', 'busy', 'message', 'Verkkovarauksia tehdään nyt poikkeuksellisen paljon – yritä myöhemmin uudelleen');
  end if;

  begin  -- alitransaktio: virhe kumoaa asiakkaan/tilauksen/varauksen luonnin mutta rate limit -kirjaus säilyy
    v_end := booking._treatment_slot_check(p_product_id, p_start, p_persons, true);       -- uudelleenvalidointi luontihetkellä (päivä, aikaikkuna, ruudukko, henkilömäärä)
    v_opt := booking._resolve_product_option(p_product_id, p_option_code, true);          -- booking_50: tuotevalinta (option_required / invalid_option)
    if v_is_company then v_company := booking._clean_company(p_company); end if;
    if v_is_company then
      v_cust := booking._upsert_company_customer(v_kind, v_name, v_email, v_phone, v_company, p_marketing_consent, 'web_booking', p_locale, (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    else
      v_cust := booking._upsert_customer(v_name, v_email, v_phone, p_marketing_consent, 'web_booking', p_locale, (booking._setting('marketing_consent_text_version', '"v1"'::jsonb) #>> '{}'));
    end if;
    v_total := booking._treatment_price(p_product_id, p_persons);
    -- ei override-polkua; ei vapaata saunottajaa -> therapist_missing (booking_22) ellei päivä ole suljettu (therapist_closed nousee virheenä)
    perform set_config('booking.checkout_hold_minutes', v_hmin::text, true);
    perform set_config('booking.checkout_hold_kind', case when v_group then 'preliminary' else 'checkout' end, true);
    v_res := booking._create_legs_booking('current', p_product_id, p_start, v_end, p_persons, v_cust, 'web', null, p_note, v_total, null, false, null, false, null, null, p_option_code);
    perform set_config('booking.checkout_hold_minutes', '', true);
    perform set_config('booking.checkout_hold_kind', '', true);
    v_order := (v_res ->> 'order_id')::bigint;
    perform booking._stamp_order_billing(v_order, v_cust, v_company);
    v_add := booking._attach_addons((v_res ->> 'reservation_id')::bigint, p_addons);      -- booking_61: lisäpalvelut (resurssivaraus: esim. pyyhe); virheet BK001 -> addon_* -koodit
    v_total := v_total + v_add;
    v_pay_method := case when v_is_company then 'invoice' else 'pay_later' end;
    if not v_hold_mode then   -- pitotilassa ei paikkaajamaksua
      insert into booking.payments(order_id, method, provider, status, amount) values (v_order, v_pay_method, 'manual', 'pending', v_total);
    end if;
    update booking.orders set payment_status = 'unpaid' where id = v_order returning public_token into v_token;
  exception
    when sqlstate 'BK001' then
      get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
      return booking._public_slot_error(v_detail, v_msg);
    when exclusion_violation then
      return booking._public_slot_error('slot_unavailable', null);
    when lock_not_available then
      return jsonb_build_object('ok', false, 'code', 'busy', 'message', 'Järjestelmä on hetkellä kiireinen, yritä hetken kuluttua uudelleen');
  end;

  return jsonb_build_object('ok', true, 'order_no', v_res -> 'order_no', 'token', v_token, 'status', case when v_hold_mode then 'pending' else 'confirmed' end, 'starts_at', v_res -> 'starts_at', 'ends_at', v_res -> 'ends_at',
                            'persons', p_persons, 'total', v_total, 'addons_total', v_add, 'payment_mode', case when v_hold_mode then v_mode else 'pay_later' end, 'payment_url', null, 'hold_expires_at', v_res -> 'hold_expires_at',
                            'product_name', v_res -> 'product_name', 'customer_kind', v_kind, 'booking_kind', 'slots', 'option', booking._option_json(v_opt))
         || booking._checkout_state_json(v_order);
end $function$
;

revoke all on function booking.public_create_treatment_booking(bigint, timestamptz, integer, text, text, text, boolean, text, text, text, jsonb, text, jsonb) from public;
grant execute on function booking.public_create_treatment_booking(bigint, timestamptz, integer, text, text, text, boolean, text, text, text, jsonb, text, jsonb) to anon, authenticated, service_role;

-- ---------- c) ostoikkuna näkyviin ----------
update booking.settings set is_public = true where key = 'public_treatment_horizon_days' and not is_public;

-- ---------- tekstijärjestelmän päivitykset (a, b, e) ----------
create or replace function booking._text_publish(p_version_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare v booking.site_text_versions; t booking.site_texts; n int;
begin
  select * into v from booking.site_text_versions where id = p_version_id for update;
  select * into t from booking.site_texts where id = v.text_id for update;
  if t.source_table is not null then
    perform set_config('booking.text_apply', 'on', true);
    execute format('update %s set %I = $1 where %I::text = $2', t.source_table, t.source_column, t.source_pk_col) using v.text, t.source_pk;
    get diagnostics n = row_count;
    perform set_config('booking.text_apply', '', true);
    if n <> 1 then perform booking._err('source_missing', 'Lähderiviä ei löydy tekstille ' || t.key); end if;
  end if;
  update booking.site_text_versions set status = 'superseded' where text_id = t.id and status = 'published' and id <> v.id;
  update booking.site_text_versions set status = 'stale', note = coalesce(note || ' | ', '') || 'vanhentunut: toinen versio julkaistiin'
   where text_id = t.id and id <> v.id and status in ('draft', 'proposed', 'approved') and version < v.version;
  update booking.site_text_versions set status = 'published', published_by = auth.uid(), published_at = now() where id = v.id;
  update booking.site_texts set published_text = v.text, published_version = v.version, published_at = now(), needs_translation = false,
         needs_review = case when v.approved_by is not null then false else needs_review end,
         review_note = case when v.approved_by is not null then null else review_note end where id = t.id;
  if t.lang in ('fi', 'en') then
    update booking.site_texts set needs_translation = true where key = t.key and lang in ('fi', 'en') and lang <> t.lang and published_version > 0;
  end if;
  perform booking._text_refresh(t.id);
  perform booking._text_audit('TEXT_PUBLISH', t.id, v.version, jsonb_build_object('key', t.key, 'lang', t.lang, 'protected', v.protected, 'escalation', v.escalation));
end $$;

create or replace function booking._text_json(t booking.site_texts) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', t.id, 'key', t.key, 'lang', t.lang, 'class', t.class, 'kind', t.kind, 'max_len', t.max_len, 'placeholders', to_jsonb(t.placeholders),
    'text', t.published_text, 'version', t.published_version, 'status', t.status, 'needs_translation', t.needs_translation, 'needs_review', t.needs_review, 'review_note', t.review_note, 'published_at', t.published_at,
    'pending', (select coalesce(jsonb_agg(jsonb_build_object('version_id', v.id, 'version', v.version, 'status', v.status, 'text', v.text, 'protected', v.protected, 'escalation', to_jsonb(v.escalation),
                  'author_kind', v.author_kind, 'author_label', v.author_label, 'reason', v.reason, 'created_at', v.created_at) order by v.version), '[]'::jsonb)
                  from booking.site_text_versions v where v.text_id = t.id and v.status in ('draft', 'proposed', 'approved'))) $$;



create or replace function booking._text_source_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
declare r booking.site_texts; v_new text; v_ver int; v_pk text := coalesce(to_jsonb(new) ->> 'id', to_jsonb(new) ->> 'code', to_jsonb(new) ->> 'product_id');
begin
  if coalesce(current_setting('booking.text_apply', true), '') = 'on' then return null; end if;
  for r in select * from booking.site_texts t where t.source_table = tg_table_schema || '.' || tg_table_name and t.source_pk = v_pk loop
    v_new := coalesce(to_jsonb(new) ->> r.source_column, '');
    continue when v_new = r.published_text;
    select coalesce(max(version), 0) + 1 into v_ver from booking.site_text_versions where text_id = r.id;
    update booking.site_text_versions set status = 'superseded' where text_id = r.id and status = 'published';
    update booking.site_text_versions set status = 'stale', note = 'vanhentunut: lähdetaulua muokattu suoraan' where text_id = r.id and status in ('draft', 'proposed', 'approved');
    insert into booking.site_text_versions(text_id, version, text, status, base_version, author, author_kind, author_label, reason, published_by, published_at, escalation, protected)
    values (r.id, v_ver, v_new, 'published', r.published_version, auth.uid(), case when auth.uid() is null then 'system' else 'human' end, coalesce(auth.uid()::text, 'sql'),
            'Muokattu suoraan lähdetaulussa (' || tg_table_schema || '.' || tg_table_name || ')', auth.uid(), now(), booking._text_escalation(r.published_text, v_new), false);
    update booking.site_texts set published_text = v_new, published_version = v_ver, published_at = now(),
           needs_translation = false where id = r.id;
    if r.lang in ('fi', 'en') then update booking.site_texts set needs_translation = true where key = r.key and lang in ('fi', 'en') and lang <> r.lang and published_version > 0; end if;
    perform booking._text_refresh(r.id);
    perform booking._text_audit('TEXT_DIRECT_EDIT', r.id, v_ver, jsonb_build_object('key', r.key, 'table', tg_table_schema || '.' || tg_table_name));
  end loop;
  return null;
end $$;

create or replace function booking._texts_register_sources() returns integer
language plpgsql security definer set search_path = '' as $fn$
declare n integer := 0; c text; pc text := $c$case when lower(coalesce(s.category, '')) in ('hinnat','varaaminen','booking','maksaminen','opening_hours','aukioloajat','käytännöt','practical','payment','cancellation','safety','accessibility','privacy','gift_card','season_card','training_terms','house_rules','dress_code') then 'protected' else 'normal' end$c$;
begin
  -- kb.products (aktiiviset): nimet/kuvaukset normal; kesto protected; hinta/slug/URL locked
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'name', 'name', $$'fi'$$, $$'normal'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'name', 'name_en', $$'en'$$, $$'normal'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'description', 'description', $$'fi'$$, $$'normal'$$, 's.active', 4000);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'description', 'description_en', $$'en'$$, $$'normal'$$, 's.active', 4000);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'duration_text', 'duration_text', $$'fi'$$, $$'protected'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'price_text', 'price_text', $$'fi'$$, $$'locked'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'slug', 'slug', $$'all'$$, $$'locked'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.products', 'id', 'product', 'booking_url', 'booking_url', $$'all'$$, $$'locked'$$, 's.active', 500);
  -- UKK
  n := n + booking._texts_reg('kb.faq', 'id', 'faq', 'question', 'question', $$coalesce(nullif(s.language, ''), 'fi')$$, pc, 's.active', 500);
  n := n + booking._texts_reg('kb.faq', 'id', 'faq', 'answer', 'answer', $$coalesce(nullif(s.language, ''), 'fi')$$, pc, 's.active', 6000);
  -- ehdot ja käytännöt (kaikki protected)
  n := n + booking._texts_reg('kb.policies', 'id', 'policy', 'title', 'title', $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, $$s.status = 'active' and not coalesce(s.internal, false)$$, 300);
  n := n + booking._texts_reg('kb.policies', 'id', 'policy', 'body', 'body', $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, $$s.status = 'active' and not coalesce(s.internal, false)$$, 20000);
  -- lisäpalvelut, tuotevalinnat, lahjakorttipaketit, vuorojen nimet
  foreach c in array array['name', 'description'] loop
    n := n + booking._texts_reg('booking.addons', 'id', 'addon', c, c, $$'fi'$$, $$'normal'$$, 's.active', case when c = 'name' then 200 else 2000 end);
    n := n + booking._texts_reg('booking.addons', 'id', 'addon', c, c || '_en', $$'en'$$, $$'normal'$$, 's.active', case when c = 'name' then 200 else 2000 end);
    n := n + booking._texts_reg('booking.product_options', 'id', 'option', c, c, $$'fi'$$, $$'normal'$$, 's.active', case when c = 'name' then 200 else 2000 end);
    n := n + booking._texts_reg('booking.product_options', 'id', 'option', c, c || '_en', $$'en'$$, $$'normal'$$, 's.active', case when c = 'name' then 200 else 2000 end);
    n := n + booking._texts_reg('booking.gift_card_packages', 'code', 'giftpkg', c, c, $$'fi'$$, $$'normal'$$, 's.active', case when c = 'name' then 200 else 2000 end);
    n := n + booking._texts_reg('booking.gift_card_packages', 'code', 'giftpkg', c, c || '_en', $$'en'$$, $$'normal'$$, 's.active', case when c = 'name' then 200 else 2000 end);
  end loop;
  n := n + booking._texts_reg('booking.schedule_rules', 'id', 'schedule', 'label', 'label', $$'fi'$$, $$'normal'$$, 's.active', 200);
  -- sijainnit, aukioloajat, tapahtumat, yritys (kaikki protected: tosiasiat)
  foreach c in array array['name', 'description', 'directions', 'parking', 'public_transport', 'accessibility'] loop
    n := n + booking._texts_reg('kb.locations', 'id', 'location', c, c, $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, 's.active', 3000);
  end loop;
  n := n + booking._texts_reg('kb.opening_hours', 'id', 'hours', 'session_name', 'session_name', $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.opening_hours', 'id', 'hours', 'swimsuit_rule', 'swimsuit_rule', $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, 's.active', 500);
  n := n + booking._texts_reg('kb.event_dates', 'id', 'event', 'time_text', 'time_text', $$'fi'$$, $$'protected'$$, 's.active', 200);
  n := n + booking._texts_reg('kb.businesses', 'id', 'business', 'description', 'description', $$coalesce(nullif(s.language, ''), 'fi')$$, $$'protected'$$, 's.active', 4000);
  -- booking_61: tuotteen lahjakorttihuomautus (product_config) ja aikajanan osavaiheiden nimet
  n := n + booking._texts_reg('booking.product_config', 'product_id', 'product_voucher', 'note', 'voucher_note', $$'fi'$$, $$'protected'$$, $$s.voucher_note is not null or s.voucher_note_en is not null$$, 600);
  n := n + booking._texts_reg('booking.product_config', 'product_id', 'product_voucher', 'note', 'voucher_note_en', $$'en'$$, $$'protected'$$, $$s.voucher_note is not null or s.voucher_note_en is not null$$, 600);
  n := n + booking._texts_reg('booking.product_timeline_segments', 'id', 'timeline', 'label', 'label', $$'fi'$$, $$'normal'$$, 'true', 60);
  n := n + booking._texts_reg('booking.product_timeline_segments', 'id', 'timeline', 'label', 'label_en', $$'en'$$, $$'normal'$$, 'true', 60);
  -- seed-versiot (versio 1 = nykyinen lähdeteksti)
  insert into booking.site_text_versions(text_id, version, text, status, base_version, author_kind, author_label, reason, published_at, escalation, protected)
  select t.id, 1, t.published_text, 'published', 0, 'system', 'seed booking_60', 'Alkutila lähdetaulusta', now(), '{}', false
    from booking.site_texts t where t.published_version = 1 and not exists (select 1 from booking.site_text_versions v where v.text_id = t.id);
  return n;
end $fn$;



create or replace function booking.admin_texts_mark_reviewed(p_key text, p_lang text, p_note text default null) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare t booking.site_texts;
begin
  perform booking._text_perm_any(array['texts.approve', 'texts.approve_protected']);
  t := booking._text_row(p_key, p_lang, true);
  if t.id is null then perform booking._err('not_found', 'Tekstiä ei löydy'); end if;
  if not t.needs_review then perform booking._err('no_change', 'Teksti ei ole tarkistusjonossa'); end if;
  if t.class = 'protected' then perform booking._text_perm('texts.approve_protected'); end if;
  update booking.site_texts set needs_review = false, review_note = null where id = t.id;
  perform booking._text_audit('TEXT_REVIEWED', t.id, t.published_version, jsonb_build_object('key', t.key, 'lang', t.lang, 'note', p_note));
  return jsonb_build_object('ok', true, 'key', t.key, 'lang', t.lang);
end $$;
create or replace function booking.admin_texts_review_queue(p_limit integer default 200) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._text_perm_any(array['texts.approve', 'texts.approve_protected', 'texts.manage']);
  return jsonb_build_object('ok', true, 'items', (select coalesce(jsonb_agg(jsonb_build_object('key', t.key, 'lang', t.lang, 'class', t.class, 'text', t.published_text, 'review_note', t.review_note) order by t.key, t.lang), '[]'::jsonb)
                                                  from (select * from booking.site_texts where needs_review order by key, lang limit least(greatest(coalesce(p_limit, 200), 1), 500)) t));
end $$;
revoke all on function booking.admin_texts_mark_reviewed(text, text, text), booking.admin_texts_review_queue(integer), booking._timeline_json(bigint), booking._fmt_minutes(integer) from public, anon, authenticated;
grant execute on function booking.admin_texts_mark_reviewed(text, text, text), booking.admin_texts_review_queue(integer) to authenticated, service_role;

-- aikajanan hallinta (catalog.edit): korvaa tuotteen osavaiheet kokonaan; tekstit syntyvät site_texts-rekisteriin (admin_texts_sync / tämä RPC)
create or replace function booking.admin_set_product_timeline(p_product_id bigint, p_segments jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare e jsonb; i int := 0; v_sum int := 0; v_dur int;
begin
  perform booking._require_permission('catalog.edit');
  if p_segments is null or jsonb_typeof(p_segments) <> 'array' then perform booking._err('invalid_segments', 'Osavaiheet väärässä muodossa'); end if;
  select duration_minutes into v_dur from booking.product_config where product_id = p_product_id;
  if not found then perform booking._err('not_found', 'Tuotetta ei löydy'); end if;
  for e in select * from jsonb_array_elements(p_segments) loop v_sum := v_sum + coalesce((e ->> 'minutes')::int, 0); end loop;
  if jsonb_array_length(p_segments) > 0 and v_sum <> v_dur then perform booking._err('timeline_sum', format('Osavaiheiden summa (%s min) ei vastaa tuotteen kestoa (%s min)', v_sum, v_dur)); end if;
  delete from booking.site_texts where source_table = 'booking.product_timeline_segments' and source_pk in (select id::text from booking.product_timeline_segments where product_id = p_product_id);
  delete from booking.product_timeline_segments where product_id = p_product_id;
  for e in select * from jsonb_array_elements(p_segments) loop
    i := i + 1;
    insert into booking.product_timeline_segments(product_id, seq, kind, label, label_en, minutes)
    values (p_product_id, i, e ->> 'kind', e ->> 'label', nullif(btrim(coalesce(e ->> 'label_en', '')), ''), (e ->> 'minutes')::int);
  end loop;
  perform booking._texts_register_sources();
  return jsonb_build_object('ok', true, 'segments', i);
end $$;
revoke all on function booking.admin_set_product_timeline(bigint, jsonb) from public, anon;
grant execute on function booking.admin_set_product_timeline(bigint, jsonb) to authenticated, service_role;

do $$
declare x text;
begin
  foreach x in array array['booking.product_config', 'booking.product_timeline_segments'] loop
    execute format('drop trigger if exists zz_site_text_sync on %s', x);
    execute format('create trigger zz_site_text_sync after update on %s for each row execute function booking._text_source_changed()', x);
  end loop;
end $$;

-- ---------- sisältö: tuote 7 ----------
-- lahjakorttihuomautus ulos kuvauksesta omaan kenttään; EN-kuvaus; aikajana
update booking.product_config set
  voucher_note = 'Elämyslahjojen lahjakortilla: varaa ensin yleinen vuoro ja osta rituaali erikseen.',
  voucher_note_en = 'With an Elämyslahjat gift card: first book a regular session and buy the ritual separately.'
 where product_id = 7 and voucher_note is null;
insert into booking.product_timeline_segments(product_id, seq, kind, label, label_en, minutes) values
  (7, 1, 'ritual', 'rituaali', 'ritual', 20), (7, 2, 'break', 'tauko', 'break', 10), (7, 3, 'smoke_sauna', 'savusauna', 'smoke sauna', 90)
on conflict (product_id, seq) do nothing;
select booking._texts_register_sources();   -- rekisteröi uudet lähteet ensin, jotta kuvauksen muutos kirjautuu versiohistoriaan
update kb.products set
  description = 'Avoin saunarituaali lauantaisin ja sunnuntaisin: vuoro alkaa 20 minuutin saunotusrituaalilla hoitosauna Raunissa (pienryhmä, enintään 6 osallistujaa), josta siirrytään savusaunaan. Sisältää löylyntervehdyksen, kevyttä lämmittelyvihdontaa ja vuodenkierron mukaisen minihoidon sekä pääsyn sauna-alueelle, altaisiin ja laavulle. Rituaaliin voi tulla alasti, mutta savusaunassa ja paljuissa käytetään uima-asua. Ohjelma vaihtuu vuodenaikojen mukaan.',
  description_en = 'Open sauna ritual on Saturdays and Sundays: the session starts with a 20-minute sauna ritual in the healing sauna Rauni (small group, max. 6 participants), after which you move on to the smoke sauna. Includes a löyly greeting, light warming vihta whisking and a seasonal mini treatment, plus access to the sauna area, the pools and the lean-to (laavu). You are welcome to join the ritual naked, but swimwear is worn in the smoke sauna and the hot tubs. The programme changes with the seasons.'
 where id = 7 and description_en is null;
-- EN-tekstit ovat koneluonnoksia: merkitään tarkistettaviksi (massatarkistus), FI-puolta ei merkitä käännettäväksi
update booking.site_texts set needs_review = true, review_note = 'EN-luonnos (booking_61): tarkistettava ennen kuin se katsotaan hyväksytyksi'
 where lang = 'en' and published_version > 0 and key in ('product.7.description', 'product_voucher.7.note')
    or (lang = 'en' and published_version > 0 and key like 'timeline.%' and source_pk in (select id::text from booking.product_timeline_segments where product_id = 7));
update booking.site_texts set needs_translation = false where key in ('product.7.description', 'product_voucher.7.note') or key like 'timeline.%';
