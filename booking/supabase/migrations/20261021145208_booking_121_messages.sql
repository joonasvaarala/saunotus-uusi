-- ============================================================
-- booking_121_messages: tuotekohtaiset viestit (Viestit).
-- Ohje (lyhyt tilausvahvistuksessa, täysi tilaussivulla), jälkimarkkinointi ja palautepyyntö.
-- Ajastettu lähetys on oletuksena POIS (settings messages.timed_enabled = false).
-- Lyhyt ohje tilausvahvistuksessa ei riipu tästä kytkimestä.
-- Sähköpostin lähetystilaa (off / dry_run / live) ja allowlistia ei muuteta.
-- Rollback: rollbacks/20261021145208_booking_121_ROLLBACK.sql
-- Tätä tiedostoa ei ajeta tästä repossa. Bottiavustus ajaa migraation. Ei tuotantoon tästä.
-- ============================================================
set local lock_timeout = '5s';

insert into booking.role_permissions(role_code, permission) values
  ('admin', 'messages.edit'),
  ('manager', 'messages.edit')
on conflict do nothing;

insert into booking.settings(key, value, description, is_public) values
  ('messages.timed_enabled', 'false'::jsonb,
   'Ajastetut tuoteviestit. Oletus pois. Lyhyt ohje tilausvahvistuksessa ei riipu tästä.', false)
on conflict (key) do nothing;

create table booking.messages (
  id              bigint generated always as identity primary key,
  name            text not null check (char_length(btrim(name)) between 1 and 120),
  category        text not null check (category in ('instruction', 'after_marketing', 'feedback')),
  subject_fi      text check (subject_fi is null or char_length(subject_fi) <= 200),
  subject_en      text check (subject_en is null or char_length(subject_en) <= 200),
  short_fi        text check (short_fi is null or char_length(short_fi) <= 2000),
  short_en        text check (short_en is null or char_length(short_en) <= 2000),
  body_fi         text check (body_fi is null or char_length(body_fi) <= 8000),
  body_en         text check (body_en is null or char_length(body_en) <= 8000),
  link_url        text check (link_url is null or (char_length(link_url) <= 500 and link_url ~ '^https://[^[:space:]]+$')),
  active          boolean not null default false,
  send_amount     integer check (send_amount is null or send_amount between 1 and 3650),
  send_unit       text check (send_unit is null or send_unit in ('minutes', 'hours', 'days')),
  send_direction  text check (send_direction is null or send_direction in ('before', 'after')),
  send_anchor     text check (send_anchor is null or send_anchor in ('booking', 'arrival')),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint messages_timing_complete check (
    (send_amount is null and send_unit is null and send_direction is null and send_anchor is null)
    or (send_amount is not null and send_unit is not null and send_direction is not null and send_anchor is not null)
  )
);
comment on table booking.messages is
  'Tuotekohtainen viestipohja. category instruction: short_* tilausvahvistuksessa, body_* tilaussivun Ohjeet-osiossa. after_marketing ja feedback vain ajastettuna sähköpostina. active=false ei näy eikä lähde. Ajastus: määrä + yksikkö + ennen/jälkeen + booking (tilaus luotu) tai arrival (varaus alkaa).';
comment on column booking.messages.link_url is 'Vapaaehtoinen https-linkki, esim. Google-arvostelu. Paikkamerkki {linkki}. Ei ole sivuteksti.';
comment on column booking.messages.send_anchor is 'booking = orders.created_at. arrival = varauksen starts_at (ennen = aikaisin, jälkeen = myöhäisin osuva varaus).';

create table booking.message_products (
  message_id  bigint not null references booking.messages(id) on delete cascade,
  product_id  bigint not null references kb.products(id) on delete cascade,
  primary key (message_id, product_id)
);
comment on table booking.message_products is 'Viesti ↔ tuote. Yksi viesti monelle tuotteelle, yksi tuote monelle viestille. Sama viesti lähtee tilauksesta kerran, ei tuotetta kohti.';
create index message_products_product_idx on booking.message_products(product_id);
create index messages_timed_idx on booking.messages(id) where active and send_amount is not null;

create trigger messages_updated before update on booking.messages
  for each row execute function booking.set_updated_at();

alter table booking.messages enable row level security;
alter table booking.message_products enable row level security;
revoke all on booking.messages from public, anon, authenticated;
revoke all on booking.message_products from public, anon, authenticated;
grant all on booking.messages to service_role;
grant all on booking.message_products to service_role;
select booking._add_audit('booking.messages'::regclass);
select booking._add_audit('booking.message_products'::regclass);

alter table booking.email_outbox drop constraint if exists email_outbox_kind_check;
alter table booking.email_outbox add constraint email_outbox_kind_check
  check (kind in ('order_confirmation', 'payment_link', 'receipt', 'refund_receipt', 'cancel_request_ack', 'order_change', 'gift_card_buyer', 'gift_card_recipient', 'voucher_claim_received', 'voucher_claim_problem', 'business_quote_ack', 'business_quote_notify', 'invoice_pdf', 'product_message'));

-- ---------- apufunktiot (ei suoraan asiakkaille) ----------
create function booking._message_pick(p_fi text, p_en text, p_locale text)
returns text language sql immutable set search_path = '' as $$
  select coalesce(case when p_locale = 'en' then nullif(btrim(p_en), '') end, nullif(btrim(p_fi), ''))
$$;

create function booking._message_fill(p_text text, p_vars jsonb)
returns text language plpgsql immutable set search_path = '' as $$
declare s text := coalesce(p_text, ''); k text;
begin
  if s = '' then return ''; end if;
  foreach k in array array['asiakas_nimi', 'tilaus_linkki', 'tuote', 'saapumisaika', 'linkki'] loop
    s := replace(s, '{' || k || '}', coalesce(p_vars ->> k, ''));
  end loop;
  return s;
end $$;

create function booking._order_product_ids(p_order_id bigint)
returns bigint[] language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(distinct pid), '{}') from (
    select r.product_id as pid from booking.reservations r
     where r.order_id = p_order_id and r.product_id is not null and r.hidden_at is null
    union
    select i.product_id from booking.order_items i
     where i.order_id = p_order_id and i.product_id is not null and i.kind in ('reservation', 'product')
  ) s
$$;

-- Päivä = 24 tuntia (ei kalenteripäivä). Grace 36 h. missed_at_booking: lähetyshetki <= tilauksen luonti.
-- Ennen saapumista, kun varaus tehtiin vasta muistutuksen jälkeen: ei lähetetä heti (vahvistuksessa on jo lyhyt ohje).
-- Yli 36 h myöhässä: ei takautuvaa lähetystä, kun kytkin avataan tai cron on ollut pitkään pois.
create function booking._message_decision(
  p_created timestamptz,
  p_arrivals timestamptz[],
  p_amount integer,
  p_unit text,
  p_direction text,
  p_anchor text,
  p_now timestamptz,
  p_order_status text,
  p_payment_status text,
  p_external boolean
) returns jsonb language plpgsql stable set search_path = '' as $$
declare
  v_anchor timestamptz;
  v_send timestamptz;
  v_iv interval;
  v_arr timestamptz[];
begin
  if coalesce(p_external, false) then return jsonb_build_object('action', 'skip', 'reason', 'external_import'); end if;
  if p_order_status is null or p_order_status not in ('confirmed', 'completed') then
    return jsonb_build_object('action', 'skip', 'reason', 'order_status');
  end if;
  if p_payment_status = 'refunded' then return jsonb_build_object('action', 'skip', 'reason', 'refunded'); end if;
  if p_amount is null or p_unit is null or p_direction is null or p_anchor is null then
    return jsonb_build_object('action', 'skip', 'reason', 'no_timing');
  end if;
  if p_amount < 1 or p_amount > 3650 or p_unit not in ('minutes', 'hours', 'days')
     or p_direction not in ('before', 'after') or p_anchor not in ('booking', 'arrival') then
    return jsonb_build_object('action', 'skip', 'reason', 'invalid_timing');
  end if;
  v_iv := case p_unit
    when 'minutes' then make_interval(mins => p_amount)
    when 'hours' then make_interval(hours => p_amount)
    else make_interval(hours => p_amount * 24)
  end;
  if p_anchor = 'booking' then
    v_anchor := p_created;
  else
    select coalesce(array_agg(x order by x), '{}') into v_arr from unnest(coalesce(p_arrivals, '{}'::timestamptz[])) x where x is not null;
    if v_arr is null or cardinality(v_arr) = 0 then return jsonb_build_object('action', 'skip', 'reason', 'no_arrival'); end if;
    v_anchor := case when p_direction = 'before' then v_arr[1] else v_arr[cardinality(v_arr)] end;
  end if;
  if v_anchor is null or p_created is null or p_now is null then
    return jsonb_build_object('action', 'skip', 'reason', 'invalid_timing');
  end if;
  v_send := case when p_direction = 'before' then v_anchor - v_iv else v_anchor + v_iv end;
  if v_send <= p_created then
    return jsonb_build_object('action', 'skip', 'reason', 'missed_at_booking', 'send_at', v_send);
  end if;
  if v_send > p_now then
    return jsonb_build_object('action', 'wait', 'reason', 'not_due', 'send_at', v_send);
  end if;
  if v_send < p_now - interval '36 hours' then
    return jsonb_build_object('action', 'skip', 'reason', 'too_late', 'send_at', v_send);
  end if;
  return jsonb_build_object('action', 'send', 'reason', 'due', 'send_at', v_send);
end $$;

create function booking._message_vars(p_order_id bigint, p_message_id bigint, p_locale text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_loc text := case when p_locale = 'en' then 'en' else 'fi' end;
  v_name text; v_url text; v_products text; v_when text; v_link text; v_token uuid;
begin
  select c.name, o.public_token into v_name, v_token
    from booking.orders o left join booking.customers c on c.id = o.customer_id
   where o.id = p_order_id;
  v_url := coalesce(booking._setting('site_base_url') #>> '{}', '')
        || coalesce(booking._setting('order_page_path') #>> '{}', '/tilaus/')
        || '?t=' || coalesce(v_token::text, '');
  select string_agg(nm, ', ' order by nm) into v_products from (
    select distinct coalesce(case when v_loc = 'en' then nullif(btrim(p.name_en), '') end, p.name) as nm
      from kb.products p
      join booking.message_products mp on mp.product_id = p.id and mp.message_id = p_message_id
     where p.id = any (booking._order_product_ids(p_order_id))
  ) q;
  select string_agg(to_char(r.starts_at at time zone 'Europe/Helsinki', 'DD.MM.YYYY HH24:MI'), ', ' order by r.starts_at)
    into v_when
    from booking.reservations r
    join booking.message_products mp on mp.product_id = r.product_id and mp.message_id = p_message_id
   where r.order_id = p_order_id and r.status in ('confirmed', 'completed') and r.hidden_at is null;
  select case when m.link_url ~ '^https://[^[:space:]]+$' then m.link_url else '' end into v_link
    from booking.messages m where m.id = p_message_id;
  return jsonb_build_object(
    'asiakas_nimi', coalesce(v_name, ''),
    'tilaus_linkki', v_url,
    'tuote', coalesce(v_products, ''),
    'saapumisaika', coalesce(v_when, ''),
    'linkki', coalesce(v_link, ''));
end $$;

create function booking._order_message_rows(p_order_id bigint, p_locale text, p_full boolean)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_loc text := case when p_locale = 'en' then 'en' else 'fi' end;
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', m.id,
      'title', booking._message_fill(coalesce(booking._message_pick(m.subject_fi, m.subject_en, v_loc), ''), booking._message_vars(p_order_id, m.id, v_loc)),
      'body', case when p_full then booking._message_fill(coalesce(booking._message_pick(m.body_fi, m.body_en, v_loc), ''), booking._message_vars(p_order_id, m.id, v_loc)) else null end,
      'text', case when not p_full then booking._message_fill(coalesce(booking._message_pick(m.short_fi, m.short_en, v_loc), ''), booking._message_vars(p_order_id, m.id, v_loc)) else null end,
      'link_url', case when m.link_url ~ '^https://[^[:space:]]+$' then m.link_url end
    ) order by m.id)
    from booking.messages m
    where m.active and m.category = 'instruction'
      and exists (
        select 1 from booking.message_products mp
         where mp.message_id = m.id and mp.product_id = any (booking._order_product_ids(p_order_id)))
      and (
        (p_full and booking._message_pick(m.body_fi, m.body_en, v_loc) is not null)
        or (not p_full and booking._message_pick(m.short_fi, m.short_en, v_loc) is not null)
      )
  ), '[]'::jsonb);
end $$;

create function booking._order_full_instructions(p_order_id bigint, p_locale text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select booking._order_message_rows(p_order_id, p_locale, true)
$$;

create function booking._order_short_instructions(p_order_id bigint, p_locale text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select booking._order_message_rows(p_order_id, p_locale, false)
$$;

create function booking._product_message_mail(p_outbox_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  e booking.email_outbox;
  m booking.messages;
  o booking.orders;
  v_loc text;
  v_vars jsonb;
  v_body text;
  v_subject text;
  v_unsub text;
  v_token uuid;
  v_consent boolean := false;
begin
  select * into e from booking.email_outbox where id = p_outbox_id;
  if not found then return jsonb_build_object('active', false); end if;
  select * into m from booking.messages where id = nullif(e.payload ->> 'message_id', '')::bigint;
  select * into o from booking.orders where id = e.order_id;
  if o.customer_id is not null then
    select cu.unsubscribe_token, cu.marketing_consent into v_token, v_consent
      from booking.customers cu where cu.id = o.customer_id;
  end if;
  v_loc := case when coalesce(nullif(e.locale, ''), o.locale, 'fi') = 'en' then 'en' else 'fi' end;
  if m.id is null then
    return jsonb_build_object('active', false, 'order_status', o.status, 'payment_status', o.payment_status);
  end if;
  v_vars := booking._message_vars(o.id, m.id, v_loc);
  v_subject := booking._message_fill(coalesce(booking._message_pick(m.subject_fi, m.subject_en, v_loc), ''), v_vars);
  v_body := booking._message_fill(coalesce(booking._message_pick(m.body_fi, m.body_en, v_loc), ''), v_vars);
  if m.category = 'after_marketing' and v_token is not null then
    v_unsub := coalesce(booking._setting('site_base_url') #>> '{}', '')
      || case when v_loc = 'en' then '/en/order/' else coalesce(booking._setting('order_page_path') #>> '{}', '/tilaus/') end
      || '?u=' || v_token::text;
  end if;
  return jsonb_build_object(
    'id', m.id,
    'category', m.category,
    'active', m.active,
    'subject', v_subject,
    'text', v_body,
    'link_url', case when m.link_url ~ '^https://[^[:space:]]+$' then m.link_url end,
    'unsubscribe_url', case when v_unsub ~ '^https://[^[:space:]]+$' then v_unsub end,
    'marketing_consent', case when m.category = 'after_marketing' then coalesce(v_consent, false) else true end,
    'order_status', o.status,
    'payment_status', o.payment_status);
end $$;

-- ---------- hallinta ----------
create function booking.admin_list_messages()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._require_permission('messages.edit');
  return jsonb_build_object(
    'timed_enabled', booking._setting('messages.timed_enabled', 'false'::jsonb) = 'true'::jsonb,
    'messages', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', m.id, 'name', m.name, 'category', m.category, 'active', m.active,
        'subject_fi', m.subject_fi, 'subject_en', m.subject_en,
        'short_fi', m.short_fi, 'short_en', m.short_en,
        'body_fi', m.body_fi, 'body_en', m.body_en,
        'link_url', m.link_url,
        'send_amount', m.send_amount, 'send_unit', m.send_unit,
        'send_direction', m.send_direction, 'send_anchor', m.send_anchor,
        'product_ids', coalesce((select jsonb_agg(mp.product_id order by mp.product_id) from booking.message_products mp where mp.message_id = m.id), '[]'::jsonb)
      ) order by m.category, m.name, m.id)
      from booking.messages m
    ), '[]'::jsonb));
end $$;

create function booking.admin_set_messages_timed(p_enabled boolean)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
begin
  perform booking._require_permission('messages.edit');
  if p_enabled is null then perform booking._err('invalid_timing', 'Kytkin puuttuu'); end if;
  insert into booking.settings(key, value, description, is_public)
  values ('messages.timed_enabled', to_jsonb(p_enabled),
          'Ajastetut tuoteviestit. Oletus pois. Lyhyt ohje tilausvahvistuksessa ei riipu tästä.', false)
  on conflict (key) do update set value = excluded.value;
  return jsonb_build_object('ok', true, 'timed_enabled', p_enabled);
end $$;

create function booking.admin_save_message(p_id bigint, p_data jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  allowed text[] := array['name','category','subject_fi','subject_en','short_fi','short_en','body_fi','body_en','link_url','active','send_amount','send_unit','send_direction','send_anchor','product_ids'];
  k text;
  v_name text; v_cat text; v_link text;
  v_sub_fi text; v_sub_en text; v_short_fi text; v_short_en text; v_body_fi text; v_body_en text;
  v_active boolean; v_amount integer; v_unit text; v_dir text; v_anchor text;
  v_id bigint; v_pid bigint; v_old jsonb; v_new jsonb;
begin
  perform booking._require_permission('messages.edit');
  if p_data is null or jsonb_typeof(p_data) <> 'object' then perform booking._err('invalid_text', 'Viesti puuttuu'); end if;
  for k in select jsonb_object_keys(p_data) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata: ' || k); end if;
  end loop;
  v_name := btrim(coalesce(p_data ->> 'name', ''));
  if char_length(v_name) < 1 or char_length(v_name) > 120 then perform booking._err('invalid_name', 'Nimi puuttuu tai on liian pitkä'); end if;
  v_cat := p_data ->> 'category';
  if v_cat is null or v_cat not in ('instruction', 'after_marketing', 'feedback') then perform booking._err('invalid_category', 'Tuntematon luokka'); end if;
  v_sub_fi := nullif(btrim(coalesce(p_data ->> 'subject_fi', '')), '');
  v_sub_en := nullif(btrim(coalesce(p_data ->> 'subject_en', '')), '');
  v_short_fi := nullif(btrim(coalesce(p_data ->> 'short_fi', '')), '');
  v_short_en := nullif(btrim(coalesce(p_data ->> 'short_en', '')), '');
  v_body_fi := nullif(btrim(coalesce(p_data ->> 'body_fi', '')), '');
  v_body_en := nullif(btrim(coalesce(p_data ->> 'body_en', '')), '');
  if char_length(coalesce(v_sub_fi, '')) > 200 or char_length(coalesce(v_sub_en, '')) > 200
     or char_length(coalesce(v_short_fi, '')) > 2000 or char_length(coalesce(v_short_en, '')) > 2000
     or char_length(coalesce(v_body_fi, '')) > 8000 or char_length(coalesce(v_body_en, '')) > 8000 then
    perform booking._err('invalid_text', 'Teksti on liian pitkä');
  end if;
  v_link := nullif(btrim(coalesce(p_data ->> 'link_url', '')), '');
  if v_link is not null and (char_length(v_link) > 500 or v_link !~ '^https://[^[:space:]]+$') then
    perform booking._err('invalid_link', 'Linkin pitää olla https-osoite');
  end if;
  v_active := coalesce((p_data ->> 'active')::boolean, false);
  if p_data ->> 'send_amount' is null or btrim(p_data ->> 'send_amount') = '' then
    v_amount := null; v_unit := null; v_dir := null; v_anchor := null;
    if p_data ->> 'send_unit' is not null and btrim(coalesce(p_data ->> 'send_unit', '')) <> ''
       or p_data ->> 'send_direction' is not null and btrim(coalesce(p_data ->> 'send_direction', '')) <> ''
       or p_data ->> 'send_anchor' is not null and btrim(coalesce(p_data ->> 'send_anchor', '')) <> '' then
      perform booking._err('invalid_timing', 'Ajastus pitää antaa kokonaan tai ei lainkaan');
    end if;
  else
    begin
      v_amount := (p_data ->> 'send_amount')::integer;
    exception when others then
      perform booking._err('invalid_timing', 'Ajastuksen määrä ei ole luku');
    end;
    v_unit := p_data ->> 'send_unit';
    v_dir := p_data ->> 'send_direction';
    v_anchor := p_data ->> 'send_anchor';
    if v_amount is null or v_amount < 1 or v_amount > 3650
       or v_unit is null or v_unit not in ('minutes', 'hours', 'days')
       or v_dir is null or v_dir not in ('before', 'after')
       or v_anchor is null or v_anchor not in ('booking', 'arrival') then
      perform booking._err('invalid_timing', 'Ajastus ei kelpaa');
    end if;
  end if;
  if v_cat <> 'instruction' then v_short_fi := null; v_short_en := null; end if;
  if v_active then
    if v_sub_fi is null then perform booking._err('invalid_text', 'Käytössä olevalta viestiltä puuttuu suomenkielinen aihe'); end if;
    if v_cat = 'instruction' and (v_short_fi is null or v_body_fi is null) then
      perform booking._err('invalid_text', 'Ohje tarvitsee lyhyen ja täyden suomenkielisen tekstin');
    end if;
    if v_cat <> 'instruction' and v_body_fi is null then perform booking._err('invalid_text', 'Viestiltä puuttuu suomenkielinen teksti'); end if;
    if v_cat <> 'instruction' and v_amount is null then perform booking._err('invalid_timing', 'Jälkimarkkinointi ja palautepyyntö tarvitsevat ajastuksen'); end if;
  end if;
  if p_data ? 'product_ids' then
    if jsonb_typeof(p_data -> 'product_ids') <> 'array' then perform booking._err('invalid_product', 'Tuotelista ei kelpaa'); end if;
    if exists (select 1 from jsonb_array_elements_text(p_data -> 'product_ids') e where e !~ '^[0-9]+$') then
      perform booking._err('invalid_product', 'Tuotelista ei kelpaa');
    end if;
    for v_pid in select distinct (x)::bigint from jsonb_array_elements_text(p_data -> 'product_ids') x loop
      if not exists (select 1 from kb.products p where p.id = v_pid) then perform booking._err('invalid_product', 'Tuntematon tuote'); end if;
    end loop;
  end if;
  if p_id is not null then
    select to_jsonb(m) into v_old from booking.messages m where m.id = p_id;
    if v_old is null then perform booking._err('not_found', 'Viestiä ei löydy'); end if;
    update booking.messages set
      name = v_name, category = v_cat, subject_fi = v_sub_fi, subject_en = v_sub_en,
      short_fi = v_short_fi, short_en = v_short_en, body_fi = v_body_fi, body_en = v_body_en,
      link_url = v_link, active = v_active,
      send_amount = v_amount, send_unit = v_unit, send_direction = v_dir, send_anchor = v_anchor
     where id = p_id
    returning id into v_id;
  else
    insert into booking.messages(name, category, subject_fi, subject_en, short_fi, short_en, body_fi, body_en, link_url, active, send_amount, send_unit, send_direction, send_anchor)
    values (v_name, v_cat, v_sub_fi, v_sub_en, v_short_fi, v_short_en, v_body_fi, v_body_en, v_link, v_active, v_amount, v_unit, v_dir, v_anchor)
    returning id into v_id;
  end if;
  if p_data ? 'product_ids' then
    delete from booking.message_products where message_id = v_id;
    insert into booking.message_products(message_id, product_id)
    select v_id, x.pid from (
      select distinct (e)::bigint as pid from jsonb_array_elements_text(p_data -> 'product_ids') e
    ) x
    where exists (select 1 from kb.products p where p.id = x.pid);
  end if;
  select to_jsonb(m) || jsonb_build_object('product_ids', coalesce((select jsonb_agg(mp.product_id order by mp.product_id) from booking.message_products mp where mp.message_id = m.id), '[]'::jsonb))
    into v_new from booking.messages m where m.id = v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'message', v_new);
end $$;

-- Ajastettu lähetys. Kytkin pois → ei tee mitään (ei jonorivejä).
-- Kytkin päällä: yksi email_outbox-rivi / tilaus+viesti (dedupe_key product_message:<id>:<order>).
-- Lähetys (send) kulkee _enqueue_emailin kautta, joten resend.mode=off merkitsee rivin skipped eikä live-sääntö muutu.
-- Pysyvä ohitus (skip) kirjoitetaan heti skipped-riviksi, jotta samaa päätöstä ei tehdä uudestaan.
-- Odotus (wait) ei kirjoita riviä. Usea tuote samassa tilauksessa = yksi viesti.
-- Peruttu / hyvitetty / tuontitilaus ei lähde. Ennen saapumista -ikkuna, joka oli jo ohi tilatessa, ohitetaan.
create function booking.messages_dispatch(p_limit integer default 50)
returns integer language plpgsql volatile security definer set search_path = '' as $$
declare
  n integer := 0;
  lim integer := greatest(least(coalesce(p_limit, 50), 200), 1);
  r record;
  v_dedupe text;
  v_action text;
  v_reason text;
  v_ok boolean;
begin
  if booking._setting('messages.timed_enabled', 'false'::jsonb) is distinct from 'true'::jsonb then
    return 0;
  end if;
  for r in
    with pairs as (
      select m.id as message_id, m.category, o.id as order_id, o.customer_id, o.created_at, o.status as order_status, o.payment_status, o.locale,
             coalesce(c.marketing_consent, false) as marketing_consent,
             m.send_amount, m.send_unit, m.send_direction, m.send_anchor,
             (select coalesce(array_agg(rv.starts_at order by rv.starts_at), '{}')
                from booking.reservations rv
                join booking.message_products mp2 on mp2.product_id = rv.product_id and mp2.message_id = m.id
               where rv.order_id = o.id and rv.status in ('confirmed', 'completed') and rv.hidden_at is null) as arrivals
        from booking.messages m
        join booking.orders o on o.status in ('confirmed', 'completed') and o.external_source is null
        left join booking.customers c on c.id = o.customer_id
       where m.active
         and m.send_amount is not null
         and o.created_at > now() - interval '18 months'
         and exists (
           select 1 from booking.message_products mp
            where mp.message_id = m.id and mp.product_id = any (booking._order_product_ids(o.id)))
         and not exists (
           select 1 from booking.email_outbox e
            where e.dedupe_key = 'product_message:' || m.id::text || ':' || o.id::text)
    ), decided as (
      select p.*, booking._message_decision(p.created_at, p.arrivals, p.send_amount, p.send_unit, p.send_direction, p.send_anchor, now(), p.order_status, p.payment_status, false) as decision
        from pairs p
    )
    select * from decided
     where decision ->> 'action' in ('send', 'skip')
     order by case when decision ->> 'action' = 'send' then 0 else 1 end,
              (decision ->> 'send_at')::timestamptz nulls last, message_id, order_id
     limit lim
  loop
    v_action := r.decision ->> 'action';
    v_reason := coalesce(r.decision ->> 'reason', 'skip');
    v_dedupe := 'product_message:' || r.message_id::text || ':' || r.order_id::text;
    if v_action = 'send' and r.category = 'after_marketing' and r.customer_id is not null and r.marketing_consent is distinct from true then
      insert into booking.email_outbox(kind, order_id, locale, dedupe_key, status, payload, last_error)
      values ('product_message', r.order_id, coalesce(r.locale, 'fi'), v_dedupe, 'skipped', jsonb_build_object('message_id', r.message_id), 'no_consent')
      on conflict (dedupe_key) do nothing;
    elsif v_action = 'send' then
      v_ok := booking._enqueue_email('product_message', r.order_id, null, null, v_dedupe, jsonb_build_object('message_id', r.message_id));
      if not v_ok and not exists (select 1 from booking.email_outbox e where e.dedupe_key = v_dedupe) then
        insert into booking.email_outbox(kind, order_id, locale, dedupe_key, status, payload, last_error)
        values ('product_message', r.order_id, coalesce(r.locale, 'fi'), v_dedupe, 'skipped', jsonb_build_object('message_id', r.message_id), 'no_email');
      end if;
    else
      insert into booking.email_outbox(kind, order_id, locale, dedupe_key, status, payload, last_error)
      values ('product_message', r.order_id, coalesce(r.locale, 'fi'), v_dedupe, 'skipped', jsonb_build_object('message_id', r.message_id), v_reason)
      on conflict (dedupe_key) do nothing;
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

-- public_get_order (booking_120) + instructions. email_outbox_claim (booking_93) + lyhyt ohje ja product_message.
create or replace function booking.public_get_order(p_token uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  o booking.orders; v_cust text; v_bal jsonb; v_end timestamptz; v_conf_n int; v_conf_start timestamptz; v_kind text; v_hours int;
  v_items jsonb; v_res jsonb; v_pay jsonb; v_rec jsonb; v_creq jsonb; v_ups_a jsonb; v_ups_t jsonb; v_can_add boolean; v_pl text; v_open boolean; v_status text; v_online boolean;
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if not booking._order_rl('get', p_token, (booking._setting('rl_order_get_per_10min', '60'::jsonb) #>> '{}')::int, (booking._setting('rl_order_get_per_10min', '60'::jsonb) #>> '{}')::int) then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  select * into o from booking.orders where public_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  v_hours := coalesce((booking._setting('customer_change_hours_before', '48'::jsonb) #>> '{}')::int, 48);
  select split_part(c.name, ' ', 1) into v_cust from booking.customers c where c.id = o.customer_id;
  v_bal := booking._order_balance(o.id);
  v_status := case when o.status = 'pending' and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now()) and not booking._order_mp_inflight(o.id) then 'expired' else o.status end;
  v_online := booking._vismapay_online();
  v_pl := booking._setting('payment_link_path', to_jsonb('/maksa/'::text)) #>> '{}';

  select coalesce(jsonb_agg(jsonb_build_object('name', it.product_name, 'quantity', it.quantity, 'line_total', it.line_total_gross, 'vat_rate', it.vat_rate, 'kind', it.kind) order by it.id), '[]'::jsonb)
    into v_items from booking.order_items it where it.order_id = o.id;
  select coalesce(jsonb_agg(jsonb_build_object('reservation_id', r.id, 'product_id', r.product_id, 'product_name', oi.product_name, 'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons,
           'option', booking._option_json(r.product_option_id),
           'option_label', booking._option_label(r.product_id, o.locale), 'option_label_fi', booking._option_label(r.product_id, 'fi'), 'option_label_en', booking._option_label(r.product_id, 'en'), 'option_choices', booking._product_options_json(r.product_id),
           'status', case when r.status = 'pending' and r.hold_expires_at <= now() and not booking._order_mp_inflight(r.order_id) then 'expired' else r.status end,
           'addons', coalesce((select jsonb_agg(jsonb_build_object('addon_id', a.addon_id, 'name', a.product_name, 'quantity', a.quantity, 'line_total', a.line_total_gross) order by a.id)
                                 from booking.order_items a where a.parent_item_id = r.order_item_id and a.kind = 'addon'), '[]'::jsonb)) order by r.starts_at), '[]'::jsonb)
    into v_res from booking.reservations r left join booking.order_items oi on oi.id = r.order_item_id where r.order_id = o.id and r.hidden_at is null;
  select coalesce(jsonb_agg(jsonb_build_object('status', p.status, 'amount', p.amount, 'paid_at', p.paid_at, 'method_label', coalesce(pm.label, p.method),
           'link_token', case when p.status = 'pending' and p.provider = 'visma_pay' and (p.link_expires_at is null or p.link_expires_at > now()) then p.link_token end,
           'link_path', case when p.status = 'pending' and p.provider = 'visma_pay' and (p.link_expires_at is null or p.link_expires_at > now()) then v_pl || '?p=' || p.link_token end,
           'refunded', p.refunded_amount) order by p.created_at, p.id), '[]'::jsonb)
    into v_pay from booking.payments p left join booking.payment_methods pm on pm.code = p.method
   where p.order_id = o.id and p.status <> 'cancelled'
     and not (p.provider = 'manual' and p.status = 'pending' and not exists (select 1 from booking.payment_lines pl where pl.payment_id = p.id));
  select coalesce(jsonb_agg(jsonb_build_object('receipt_no', x.receipt_no, 'kind', x.kind, 'issued_at', x.issued_at, 'token', x.public_token, 'total', x.total_gross) order by x.issued_at, x.id), '[]'::jsonb)
    into v_rec from booking.receipts x where x.order_id = o.id;
  select jsonb_build_object('status', q.status, 'created_at', q.created_at) into v_creq from booking.order_requests q where q.order_id = o.id and q.kind = 'cancel' order by q.created_at desc, q.id desc limit 1;

  select max(r.ends_at) into v_end from booking.reservations r where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at);
  v_can_add := o.external_source is null and o.status = 'confirmed' and v_end is not null and v_end > now();
  v_open := o.external_source is null and o.status = 'confirmed' and v_end is not null and v_end > now() and not exists (select 1 from booking.order_requests q where q.order_id = o.id and q.kind = 'cancel' and q.status = 'open');
  select count(*), min(r.starts_at) into v_conf_n, v_conf_start from booking.reservations r where r.order_id = o.id and r.status = 'confirmed';
  v_kind := case when exists (select 1 from booking.reservations r where r.order_id = o.id and r.rule_id is not null) then 'rules'
                 when o.source_channel = 'web' and exists (select 1 from booking.reservations r join booking.product_config pc on pc.product_id = r.product_id and pc.public_slots where r.order_id = o.id and r.rule_id is null) then 'slots'
                 else 'other' end;

  if v_can_add then
    select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name, 'name_en', a.name_en, 'description', a.description, 'description_en', a.description_en, 'price', a.price_gross, 'vat_rate', a.vat_rate,
             'max', x.lim, 'reservation_ids', x.rids) order by a.sort_order, a.id), '[]'::jsonb) into v_ups_a
      from booking.addons a
      join lateral (select max(booking._addon_limit(a.max_per_person, r.persons)) lim, jsonb_agg(r.id order by r.id) rids
                      from booking.reservations r left join booking.product_config pc on pc.product_id = r.product_id left join kb.products p on p.id = r.product_id
                     where r.order_id = o.id and booking._res_active(r.status, r.hold_expires_at) and r.ends_at > now()
                       and coalesce(case when pc.sale_kind = 'other' and pc.resource_class = 'resourced' then case when p.category = 'event' then 'event' else 'resource' end else r.mode end, r.mode) = any (a.applies_modes)) x on x.rids is not null
     where a.active;
    select coalesce(jsonb_agg(jsonb_build_object('product_id', p.id, 'name', p.name, 'name_en', p.name_en, 'price', p.price, 'duration_minutes', coalesce(pc.duration_minutes, p.duration_minutes),
             'description', p.description, 'description_en', p.description_en, 'category', p.category) order by pc.sort_order, p.id), '[]'::jsonb) into v_ups_t
      from booking.product_config pc join kb.products p on p.id = pc.product_id
     where pc.public_slots and pc.bookable and pc.shop_visible and pc.lifecycle = 'current' and p.active and p.price is not null;
  end if;

  return jsonb_build_object('ok', true, 'order_no', o.order_no, 'status', v_status, 'payment_status', o.payment_status, 'currency', o.currency, 'locale', coalesce(o.locale, 'fi'),
    'created_at', o.created_at, 'first_name', v_cust, 'customer_kind', o.customer_kind,
    'total', v_bal -> 'total', 'paid', v_bal -> 'net_paid', 'refunded', v_bal -> 'refunded', 'unpaid', v_bal -> 'unpaid',
    'items', v_items, 'reservations', v_res, 'payments', v_pay, 'receipts', v_rec,
    'can_add', v_can_add, 'add_until', case when v_can_add then v_end end,
    'can_change', (o.status = 'confirmed' and o.external_source is null and v_conf_n = 1 and v_conf_start - make_interval(hours => v_hours) >= now() and v_kind in ('rules', 'slots')),
    'change_deadline', case when v_conf_n = 1 then v_conf_start - make_interval(hours => v_hours) end, 'change_hours_before', v_hours,
    'change_via', case v_kind when 'slots' then 'public_change_order_time' when 'rules' then 'public_change_order_time' end, 'booking_kind', v_kind,
    'can_request_cancel', v_open, 'cancel_request', v_creq, 'online_payment_enabled', v_online,
    'upsell', jsonb_build_object('addons', coalesce(v_ups_a, '[]'::jsonb), 'treatments', coalesce(v_ups_t, '[]'::jsonb)),
    'instructions', booking._order_full_instructions(o.id, coalesce(o.locale, 'fi')))
    || booking._checkout_state_json(o.id);
end $$;


CREATE OR REPLACE FUNCTION booking.email_outbox_claim(p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_ids bigint[]; v_site text := coalesce(booking._setting('site_base_url') #>> '{}', ''); v_op text := coalesce(booking._setting('order_page_path') #>> '{}', '/tilaus/');
        v_pp text := coalesce(booking._setting('payment_link_path') #>> '{}', '/maksa/'); v_res jsonb;
begin
  update booking.email_outbox set status = 'pending', locked_at = null where status = 'sending' and locked_at < now() - interval '10 minutes';
  select coalesce(array_agg(id), '{}') into v_ids from (
    select id from booking.email_outbox where status in ('pending','failed') and next_attempt_at <= now() order by id limit greatest(least(coalesce(p_limit, 20), 50), 1) for update skip locked) q;
  update booking.email_outbox set status = 'sending', locked_at = now(), attempts = attempts + 1 where id = any (v_ids);
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id, 'kind', e.kind, 'locale', e.locale, 'attempts', e.attempts, 'max_attempts', e.max_attempts, 'to', coalesce(nullif(e.payload ->> 'to_email', ''), c.email), 'to_name', coalesce(nullif(e.payload ->> 'to_name', ''), c.name),
      'reply_to', case when e.kind = 'business_quote_notify' then coalesce(nullif(btrim(e.payload ->> 'reply_to'), ''), nullif(btrim(q.email), '')) end,
      'quote', case when e.kind in ('business_quote_ack', 'business_quote_notify') then jsonb_strip_nulls(jsonb_build_object(
          'id', coalesce(q.id, case when e.payload ->> 'quote_id' ~ '^[0-9]+$' then (e.payload ->> 'quote_id')::bigint end),
          'company_name', coalesce(nullif(btrim(e.payload ->> 'company_name'), ''), q.company_name),
          'contact_name', coalesce(nullif(btrim(e.payload ->> 'contact_name'), ''), q.contact_name),
          'email', coalesce(nullif(btrim(e.payload ->> 'email'), ''), q.email),
          'phone', coalesce(nullif(btrim(e.payload ->> 'phone'), ''), q.phone),
          'persons', coalesce(nullif(e.payload ->> 'persons', '')::int, q.persons),
          'offerings', coalesce(e.payload -> 'offerings', to_jsonb(q.offerings)),
          'offering_other', coalesce(nullif(btrim(e.payload ->> 'offering_other'), ''), q.offering_other),
          'preferred_when', coalesce(nullif(btrim(e.payload ->> 'preferred_when'), ''), q.preferred_when),
          'message', coalesce(nullif(btrim(e.payload ->> 'message'), ''), q.message),
          'locale', coalesce(nullif(btrim(e.payload ->> 'locale'), ''), q.locale),
          'created_at', coalesce(nullif(e.payload ->> 'created_at', ''), to_jsonb(q.created_at) #>> '{}')
        )) end,
      'order', case when o.id is null or e.kind = 'gift_card_recipient' then null else jsonb_build_object('order_no', o.order_no, 'order_url', v_site || v_op || '?t=' || o.public_token, 'total', o.total_gross, 'status', o.status,
          'instructions', case when e.kind = 'order_confirmation' then booking._order_short_instructions(o.id, coalesce(nullif(e.locale, ''), o.locale, 'fi')) else '[]'::jsonb end,
          'items', coalesce((select jsonb_agg(jsonb_build_object('name', i.product_name, 'quantity', i.quantity, 'line_total', i.line_total_gross, 'vat_rate', i.vat_rate, 'kind', i.kind) order by i.id) from booking.order_items i where i.order_id = o.id), '[]'::jsonb),
          'reservations', coalesce((select jsonb_agg(jsonb_build_object('product_name', it.product_name, 'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'status', r.status, 'option', booking._option_json(r.product_option_id)) order by r.starts_at)
              from booking.reservations r left join booking.order_items it on it.id = r.order_item_id where r.order_id = o.id), '[]'::jsonb)) end,
      'gift_cards', case when e.kind like 'gift_card\_%' then (select coalesce(jsonb_agg(jsonb_build_object('public_token', g.public_token, 'package_code', g.package_code, 'package_name', pk.name, 'package_name_en', pk.name_en,
            'kind', g.kind, 'amount', g.initial_amount, 'valid_to', g.valid_to, 'recipient_name', g.recipient_name, 'greeting', g.greeting, 'buyer_name', g.buyer_name, 'persons', pk.persons,
            'locale', g.locale, 'status', g.status, 'delivery_to', g.delivery_to, 'deliver_on', g.deliver_on, 'deliver_time', to_char(g.deliver_time, 'HH24:MI'),
            'deliver_at', booking._gc_deliver_ts(g.deliver_on, g.deliver_time), 'delivered_at', g.delivered_at,
            'recipient_email', case when e.kind = 'gift_card_buyer' then g.recipient_email end, 'cover_message', case when e.kind = 'gift_card_recipient' then g.cover_message end) order by g.id), '[]'::jsonb)
          from booking.gift_cards g left join booking.gift_card_packages pk on pk.code = g.package_code
         where g.id in (select (x)::bigint from jsonb_array_elements_text(coalesce(e.payload -> 'card_ids', '[]'::jsonb)) x)) end,
      'voucher_claim', case when e.kind like 'voucher\_claim\_%' then (select jsonb_build_object('claim_id', vc.id, 'status', vc.status, 'source', vc.source, 'code_masked', booking._vc_mask(vc.code), 'problem_code', vc.problem_code,
            'hold_until', vc.hold_until, 'created_at', vc.created_at, 'customer_name', vc.customer_name) from booking.voucher_claims vc where vc.id = (e.payload ->> 'claim_id')::bigint) end,
      'product_message', case when e.kind = 'product_message' then booking._product_message_mail(e.id) end,
      'invoice', case when e.kind = 'invoice_pdf' then (select jsonb_build_object('id', inv.id, 'invoice_no', inv.invoice_no, 'public_token', inv.public_token, 'total', inv.total_gross, 'due_date', inv.due_date, 'reference_no', inv.reference_no, 'status', inv.status) from booking.invoices inv where inv.id = nullif(e.payload ->> 'invoice_id', '')::bigint) end,
      'receipt', case when rc.id is null then null else jsonb_build_object('id', rc.id, 'receipt_no', rc.receipt_no, 'kind', rc.kind, 'text_body', rc.text_body, 'public_token', rc.public_token, 'total', rc.total_gross, 'issued_at', rc.issued_at) end,
      'payment', case when p.id is null then null else jsonb_build_object('id', p.id, 'amount', p.amount, 'link_url', case when p.provider <> 'manual' and p.status = 'pending' then v_site || v_pp || '?p=' || p.link_token end,
          'link_expires_at', p.link_expires_at) end) order by e.id), '[]'::jsonb)
    into v_res
    from booking.email_outbox e left join booking.orders o on o.id = e.order_id left join booking.customers c on c.id = o.customer_id
    left join booking.receipts rc on rc.id = e.receipt_id left join booking.payments p on p.id = e.payment_id
    left join booking.business_quote_requests q
      on e.kind in ('business_quote_ack', 'business_quote_notify')
     and q.id = case when e.payload ->> 'quote_id' ~ '^[0-9]+$' then (e.payload ->> 'quote_id')::bigint end
   where e.id = any (v_ids);
  return v_res;
end $function$;

revoke all on function booking._message_pick(text, text, text) from public, anon, authenticated;
revoke all on function booking._message_fill(text, jsonb) from public, anon, authenticated;
revoke all on function booking._order_product_ids(bigint) from public, anon, authenticated;
revoke all on function booking._message_decision(timestamptz, timestamptz[], integer, text, text, text, timestamptz, text, text, boolean) from public, anon, authenticated;
revoke all on function booking._message_vars(bigint, bigint, text) from public, anon, authenticated;
revoke all on function booking._order_message_rows(bigint, text, boolean) from public, anon, authenticated;
revoke all on function booking._order_full_instructions(bigint, text) from public, anon, authenticated;
revoke all on function booking._order_short_instructions(bigint, text) from public, anon, authenticated;
revoke all on function booking._product_message_mail(bigint) from public, anon, authenticated;
revoke all on function booking.admin_list_messages() from public, anon;
revoke all on function booking.admin_save_message(bigint, jsonb) from public, anon;
revoke all on function booking.admin_set_messages_timed(boolean) from public, anon;
revoke all on function booking.messages_dispatch(integer) from public, anon, authenticated;
grant execute on function booking._message_decision(timestamptz, timestamptz[], integer, text, text, text, timestamptz, text, text, boolean) to service_role;
grant execute on function booking.admin_list_messages() to authenticated, service_role;
grant execute on function booking.admin_save_message(bigint, jsonb) to authenticated, service_role;
grant execute on function booking.admin_set_messages_timed(boolean) to authenticated, service_role;
grant execute on function booking.messages_dispatch(integer) to service_role;

comment on function booking.messages_dispatch(integer) is
  'pg_cron kerran minuutissa. Ei tee mitään, jos messages.timed_enabled ei ole true. Kirjoittaa email_outbox-rivin product_message, dedupe product_message:<viesti>:<tilaus>. Jälkimarkkinointi vaatii customers.marketing_consent = true (syy no_consent).';

-- Peruutuslinkki jälkimarkkinoinnissa. Token on customers.unsubscribe_token (booking_02).
-- Ohje ja palautepyyntö ovat palveluviestejä: tätä ei kutsuta niistä, eikä suostumus koske niitä.
create function booking.public_marketing_unsubscribe(p_token uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare c booking.customers;
begin
  if p_token is null then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  select * into c from booking.customers where unsubscribe_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found'); end if;
  if c.marketing_consent or c.marketing_unsubscribed_at is null then
    update booking.customers set
      marketing_consent = false,
      marketing_unsubscribed_at = coalesce(marketing_unsubscribed_at, now()),
      marketing_consent_source = case when marketing_consent then 'product_message_unsubscribe' else marketing_consent_source end
     where id = c.id;
  end if;
  update booking.email_outbox e set status = 'skipped', last_error = 'unsubscribed'
   where e.kind = 'product_message'
     and e.status in ('pending', 'failed')
     and e.order_id in (select o.id from booking.orders o where o.customer_id = c.id)
     and exists (
       select 1 from booking.messages m
        where m.category = 'after_marketing'
          and m.id = nullif(e.payload ->> 'message_id', '')::bigint);
  return jsonb_build_object('ok', true);
end $$;

comment on function booking.public_marketing_unsubscribe(uuid) is
  'Jälkimarkkinoinnin peruutus. customers.marketing_consent = false, marketing_unsubscribed_at täyttyy, jonossa olevat after_marketing-rivit skipped/unsubscribed. Ohje ja palautepyyntö eivät muutu.';
revoke all on function booking.public_marketing_unsubscribe(uuid) from public;
grant execute on function booking.public_marketing_unsubscribe(uuid) to anon, authenticated, service_role;

-- Esimerkkipohjat ovat pois päältä eikä niillä ole tuotteita. Ei asiakkaalle näkyvää sisältöä.
insert into booking.messages(name, category, subject_fi, subject_en, short_fi, short_en, body_fi, body_en, active, send_amount, send_unit, send_direction, send_anchor)
select v.name, v.category, v.subject_fi, v.subject_en, v.short_fi, v.short_en, v.body_fi, v.body_en, false, v.send_amount, v.send_unit, v.send_direction, v.send_anchor
  from (values
    ('[ESIMERKKI EI KÄYTÖSSÄ] Ohje', 'instruction',
     '[ESIMERKKI] Ohje', '[EXAMPLE] Instructions',
     'Esimerkkipohja, ei käytössä. Korvaa tämä teksti ennen kuin kytket viestin päälle.',
     'Example template, not in use. Replace this text before turning the message on.',
     'Esimerkkipohja, ei käytössä. Täysi ohje näytetään tilaussivulla.',
     'Example template, not in use. The full text is shown on the order page.',
     2, 'days', 'before', 'arrival'),
    ('[ESIMERKKI EI KÄYTÖSSÄ] Jälkimarkkinointi', 'after_marketing',
     '[ESIMERKKI] Jälkimarkkinointi', '[EXAMPLE] Follow-up',
     null, null,
     'Esimerkkipohja, ei käytössä. Hei {asiakas_nimi}.',
     'Example template, not in use. Hello {asiakas_nimi}.',
     1, 'days', 'after', 'arrival'),
    ('[ESIMERKKI EI KÄYTÖSSÄ] Palautepyyntö', 'feedback',
     '[ESIMERKKI] Palautepyyntö', '[EXAMPLE] Feedback',
     null, null,
     'Esimerkkipohja, ei käytössä. Arvostelulinkki tulee kentästä {linkki}.',
     'Example template, not in use. The review link comes from {linkki}.',
     7, 'days', 'after', 'arrival')
  ) as v(name, category, subject_fi, subject_en, short_fi, short_en, body_fi, body_en, send_amount, send_unit, send_direction, send_anchor)
 where not exists (select 1 from booking.messages m where m.name = v.name);

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron')
     and not exists (select 1 from cron.job where jobname = 'booking_messages_dispatch') then
    perform cron.schedule('booking_messages_dispatch', '* * * * *', 'select booking.messages_dispatch()');
  end if;
exception when others then
  raise notice 'pg_cron-ajastus ohitettu: %', sqlerrm;
end $$;
