-- ============================================================
-- booking_141: viestin toimitustapa (paketti 09).
-- delivery_mode = 'scheduled' (oletus): ennallaan, ajastettu sähköposti kun ajastus on annettu.
-- delivery_mode = 'order_only': vain Ohje-luokka; lyhyt ohje tilausvahvistuksessa ja tilaussivulla,
--   täysi ohje tilaussivulla napin takana; ei erillistä ajastettua sähköpostia (ajastus aina NULL).
-- Olemassa olevat rivit saavat 'scheduled' → käytös ei muutu ennen kuin toimitustapaa vaihdetaan hallinnassa.
-- Rakennettu uusimpien määritelmien päälle: admin_save_message, admin_list_messages, messages_dispatch (booking_121),
--   _order_message_rows ja _product_message_mail (booking_122). Oikeudet ennallaan (create or replace säilyttää ne).
-- admin_save_message: delivery_mode puuttuu → uusi viesti scheduled, olemassa oleva säilyttää tapansa.
-- Tilaussivu/vahvistus saa lisäksi kentät short_text, short_rich, delivery_mode; vanhat text/body/rich ennallaan.
-- Ei muuta sähköpostin lähetystilaa (off / dry_run / live), allowlistia eikä messages.timed_enabled-kytkintä.
-- Ei edge-funktiomuutoksia: mailer ohittaa jo product_messagen, jonka active=false.
-- Rollback: ../rollbacks/20261024100050_booking_141_ROLLBACK.sql
-- Tätä tiedostoa ei ajeta tästä repossa. Bottiavustus ajaa migraation.
-- ============================================================
set local lock_timeout = '5s';

alter table booking.messages
  add column delivery_mode text not null default 'scheduled'
    constraint messages_delivery_mode_check check (delivery_mode in ('scheduled', 'order_only'));
alter table booking.messages
  add constraint messages_order_only_instruction check (delivery_mode = 'scheduled' or category = 'instruction');
alter table booking.messages
  add constraint messages_order_only_no_timing check (
    delivery_mode = 'scheduled'
    or (send_amount is null and send_unit is null and send_direction is null and send_anchor is null)
  );
comment on column booking.messages.delivery_mode is
  'scheduled = ajastettu sähköposti (kun ajastus on annettu). order_only = vain Ohje: lyhyt ohje tilausvahvistuksessa ja tilaussivulla, täysi ohje tilaussivulla; ei erillistä sähköpostia. booking_141.';

create or replace function booking.admin_save_message(p_id bigint, p_data jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  allowed text[] := array['name','category','subject_fi','subject_en','short_fi','short_en','body_fi','body_en','link_url','active','send_amount','send_unit','send_direction','send_anchor','product_ids','delivery_mode'];
  k text;
  v_name text; v_cat text; v_link text;
  v_sub_fi text; v_sub_en text; v_short_fi text; v_short_en text; v_body_fi text; v_body_en text;
  v_active boolean; v_amount integer; v_unit text; v_dir text; v_anchor text;
  v_id bigint; v_pid bigint; v_old jsonb; v_new jsonb;
  v_mode text;
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
  -- booking_141: toimitustapa. Puuttuva kenttä: uusi viesti = scheduled, olemassa oleva säilyttää tapansa
  -- (vanha välimuistissa oleva hallinta ei vaihda order_only-ohjetta takaisin ajastetuksi).
  v_mode := nullif(btrim(coalesce(p_data ->> 'delivery_mode', '')), '');
  if v_mode is null and p_id is not null then
    select m.delivery_mode into v_mode from booking.messages m where m.id = p_id;
  end if;
  v_mode := coalesce(v_mode, 'scheduled');
  if v_mode not in ('scheduled', 'order_only') then perform booking._err('invalid_delivery_mode', 'Tuntematon toimitustapa'); end if;
  if v_mode = 'order_only' and v_cat <> 'instruction' then
    perform booking._err('invalid_delivery_mode', 'Tilauksen yhteydessä näytettävä viesti on Ohje');
  end if;
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
  if v_mode = 'order_only' then
    -- Ei erillistä lähetystä: ajastus tyhjennetään aina, vaikka lomake toisi vanhat arvot.
    v_amount := null; v_unit := null; v_dir := null; v_anchor := null;
  elsif p_data ->> 'send_amount' is null or btrim(p_data ->> 'send_amount') = '' then
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
      link_url = v_link, active = v_active, delivery_mode = v_mode,
      send_amount = v_amount, send_unit = v_unit, send_direction = v_dir, send_anchor = v_anchor
     where id = p_id
    returning id into v_id;
  else
    insert into booking.messages(name, category, subject_fi, subject_en, short_fi, short_en, body_fi, body_en, link_url, active, delivery_mode, send_amount, send_unit, send_direction, send_anchor)
    values (v_name, v_cat, v_sub_fi, v_sub_en, v_short_fi, v_short_en, v_body_fi, v_body_en, v_link, v_active, v_mode, v_amount, v_unit, v_dir, v_anchor)
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
  if v_mode = 'order_only' then
    -- Turvaraja: jo jonoon muodostuneet tämän viestin lähetykset eivät lähde.
    update booking.email_outbox e set status = 'skipped', last_error = 'order_only'
     where e.kind = 'product_message'
       and e.payload ->> 'message_id' = v_id::text
       and e.status in ('pending', 'failed');
  end if;
  select to_jsonb(m) || jsonb_build_object('product_ids', coalesce((select jsonb_agg(mp.product_id order by mp.product_id) from booking.message_products mp where mp.message_id = m.id), '[]'::jsonb))
    into v_new from booking.messages m where m.id = v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'message', v_new);
end $$;

create or replace function booking.admin_list_messages()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._require_permission('messages.edit');
  return jsonb_build_object(
    'timed_enabled', booking._setting('messages.timed_enabled', 'false'::jsonb) = 'true'::jsonb,
    'messages', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', m.id, 'name', m.name, 'category', m.category, 'active', m.active,
        'delivery_mode', m.delivery_mode,
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

create or replace function booking.messages_dispatch(p_limit integer default 50)
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
         and m.delivery_mode = 'scheduled'
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

create or replace function booking._order_message_rows(p_order_id bigint, p_locale text, p_full boolean)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_loc text := case when p_locale = 'en' then 'en' else 'fi' end;
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', m.id,
      'title', booking._message_fill(coalesce(booking._message_pick(m.subject_fi, m.subject_en, v_loc), ''), booking._message_vars(p_order_id, m.id, v_loc)),
      'body', case when p_full then booking._message_fill(coalesce(booking._message_pick(m.body_fi, m.body_en, v_loc), ''), booking._message_vars(p_order_id, m.id, v_loc)) else null end,
      'short_text', booking._message_fill(coalesce(booking._message_pick(m.short_fi, m.short_en, v_loc), ''), booking._message_vars(p_order_id, m.id, v_loc)),
      'short_rich', booking._message_is_rich(booking._message_pick(m.short_fi, m.short_en, v_loc)),
      'text', case when not p_full then booking._message_fill(coalesce(booking._message_pick(m.short_fi, m.short_en, v_loc), ''), booking._message_vars(p_order_id, m.id, v_loc)) else null end,
      'link_url', case when m.link_url ~ '^https://[^[:space:]]+$' then m.link_url end,
      'delivery_mode', m.delivery_mode,
      'rich', booking._message_is_rich(case when p_full then booking._message_pick(m.body_fi, m.body_en, v_loc) else booking._message_pick(m.short_fi, m.short_en, v_loc) end)
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

create or replace function booking._product_message_mail(p_outbox_id bigint)
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
  v_template text;
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
  -- booking_141: jonoon aiemmin muodostunutkin order_only-lähetys estetään tässä viimeisessä suodattimessa
  -- (mailer: active=false → "tuoteviesti ei ole käytössä", ei lähetystä).
  if m.delivery_mode = 'order_only' then
    return jsonb_build_object('active', false, 'delivery_mode', 'order_only',
      'order_status', o.status, 'payment_status', o.payment_status);
  end if;
  v_vars := booking._message_vars(o.id, m.id, v_loc);
  v_template := coalesce(booking._message_pick(m.body_fi, m.body_en, v_loc), '');
  v_subject := booking._message_fill(coalesce(booking._message_pick(m.subject_fi, m.subject_en, v_loc), ''), v_vars);
  v_body := booking._message_fill(v_template, v_vars);
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
    'rich', booking._message_is_rich(v_template),
    'link_url', case when m.link_url ~ '^https://[^[:space:]]+$' then m.link_url end,
    'unsubscribe_url', case when v_unsub ~ '^https://[^[:space:]]+$' then v_unsub end,
    'marketing_consent', case when m.category = 'after_marketing' then coalesce(v_consent, false) else true end,
    'order_status', o.status,
    'payment_status', o.payment_status);
end $$;
