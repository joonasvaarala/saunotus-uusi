-- booking_257: hallinnan Viestit-sivun «Viesti asiakkaalle».
-- Uusi lokitaulu ja RPC (esikatselu confirm=false, lähetys confirm=true).
-- Ei muuta tapahtuma- eikä koulutusviestien RPC:itä.
-- Sähköposti käyttää olemassa olevaa event_message-lajia (sivuston pohja, ei Tapahtuma/Aika-rivejä).

create table if not exists booking.customer_messages (
  id bigint generated always as identity primary key,
  date_from date not null,
  date_to date not null,
  product_ids bigint[] not null,
  subject_fi text not null,
  body_fi text not null,
  subject_en text not null,
  body_en text not null,
  recipient_count integer not null,
  queued_count integer not null,
  skipped_count integer not null,
  created_by uuid,
  created_at timestamptz not null default now(),
  constraint customer_messages_range check (date_to >= date_from),
  constraint customer_messages_products check (cardinality(product_ids) >= 1),
  constraint customer_messages_subject_fi_len check (char_length(subject_fi) between 1 and 200),
  constraint customer_messages_subject_en_len check (char_length(subject_en) between 1 and 200),
  constraint customer_messages_body_fi_len check (char_length(body_fi) between 1 and 4000),
  constraint customer_messages_body_en_len check (char_length(body_en) between 1 and 4000),
  constraint customer_messages_counts check (recipient_count >= 0 and queued_count >= 0 and skipped_count >= 0)
);
comment on table booking.customer_messages is
  'booking_257: Viesti asiakkaalle -lähetysten loki. Ei vastaanottajalistaa eikä osoitteita. RLS, ei suoraa lukua.';
create index if not exists customer_messages_created_idx on booking.customer_messages (created_at desc);
alter table booking.customer_messages enable row level security;
revoke all on table booking.customer_messages from public, anon, authenticated;
grant all on table booking.customer_messages to service_role;
drop trigger if exists audit_trg on booking.customer_messages;
select booking._add_audit('booking.customer_messages');

create or replace function booking._customer_message_fill(p_text text, p_vars jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select replace(replace(replace(replace(replace(replace(
           coalesce(p_text, ''),
           '{tuote}', coalesce(p_vars ->> 'tuote', '')),
           '{päivämäärä}', coalesce(p_vars ->> 'paivamaara', '')),
           '{kellonaika}', coalesce(p_vars ->> 'kellonaika', '')),
           '{asiakkaan nimi}', coalesce(p_vars ->> 'asiakkaan_nimi', '')),
           '{henkilömäärä}', coalesce(p_vars ->> 'henkilomaara', '')),
           '{tilauslinkki}', coalesce(p_vars ->> 'tilauslinkki', ''))
$$;

create or replace function booking._customer_message_product_name(p_id bigint, p_lang text)
returns text
language sql
stable
set search_path = ''
as $$
  select case when p_lang = 'en' then coalesce(nullif(btrim(p.name_en), ''), p.name) else p.name end
    from kb.products p
   where p.id = p_id
$$;

create or replace function booking._customer_message_hits(p_from date, p_to date, p_product_ids bigint[])
returns table (
  uniq text,
  order_id bigint,
  customer_id bigint,
  email text,
  cust_name text,
  locale text,
  public_token uuid,
  order_no bigint,
  hit_kind text,
  product_id bigint,
  starts_at timestamptz,
  ends_at timestamptz,
  paid_at timestamptz,
  persons integer
)
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce('c:' || o.customer_id::text,
                  nullif('e:' || lower(btrim(coalesce(c.email, ''))), 'e:'),
                  'o:' || o.id::text),
         o.id, o.customer_id, c.email, c.name, coalesce(o.locale, 'fi'), o.public_token, o.order_no,
         'reservation'::text, r.product_id, r.starts_at, r.ends_at, null::timestamptz, r.persons
    from booking.reservations r
    join booking.orders o on o.id = r.order_id
    left join booking.customers c on c.id = o.customer_id
   where r.product_id = any (p_product_ids)
     and (r.starts_at at time zone 'Europe/Helsinki')::date between p_from and p_to
     and (booking._res_active(r.status, r.hold_expires_at) or r.status = 'completed')
     and o.external_source is null
     and (c.id is null or c.anonymized_at is null)
  union all
  select coalesce('c:' || o.customer_id::text,
                  nullif('e:' || lower(btrim(coalesce(c.email, ''))), 'e:'),
                  'o:' || o.id::text),
         o.id, o.customer_id, c.email, c.name, coalesce(o.locale, 'fi'), o.public_token, o.order_no,
         'purchase'::text, oi.product_id, null::timestamptz, null::timestamptz, pay.paid_at, null::integer
    from booking.order_items oi
    join booking.orders o on o.id = oi.order_id
    join booking.payments pay on pay.order_id = o.id
     and pay.status in ('paid', 'partially_refunded')
     and pay.paid_at is not null
     and pay.external_source is null
     and (pay.paid_at at time zone 'Europe/Helsinki')::date between p_from and p_to
    left join booking.customers c on c.id = o.customer_id
   where oi.product_id = any (p_product_ids)
     and o.external_source is null
     and o.cancelled_at is null
     and (c.id is null or c.anonymized_at is null)
$$;

create or replace function booking._customer_message_recipients(p_from date, p_to date, p_product_ids bigint[])
returns table (
  uniq text,
  order_id bigint,
  order_no bigint,
  email text,
  cust_name text,
  locale text,
  public_token uuid,
  persons integer,
  hit_kind text,
  starts_at timestamptz,
  ends_at timestamptz,
  paid_at timestamptz,
  tuote_fi text,
  tuote_en text
)
language sql
stable
security definer
set search_path = ''
as $$
  with hits as (
    select * from booking._customer_message_hits(p_from, p_to, p_product_ids)
  ),
  primary_hit as (
    select distinct on (h.uniq) h.*
      from hits h
     order by h.uniq,
              case when h.hit_kind = 'reservation' then 0 else 1 end,
              coalesce(h.starts_at, h.paid_at),
              h.order_id
  )
  select p.uniq, p.order_id, p.order_no, p.email, p.cust_name, p.locale, p.public_token, p.persons,
         p.hit_kind, p.starts_at, p.ends_at, p.paid_at,
         (select string_agg(s.nm, ', ' order by s.nm)
            from (select distinct booking._customer_message_product_name(h.product_id, 'fi') as nm
                    from hits h where h.uniq = p.uniq) s),
         (select string_agg(s.nm, ', ' order by s.nm)
            from (select distinct booking._customer_message_product_name(h.product_id, 'en') as nm
                    from hits h where h.uniq = p.uniq) s)
    from primary_hit p
$$;

create or replace function booking.admin_customer_message_send(
  p_from date,
  p_to date,
  p_product_ids bigint[],
  p_subject_fi text,
  p_body_fi text,
  p_subject_en text,
  p_body_en text,
  p_confirm boolean default false
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_from date;
  v_to date;
  v_ids bigint[];
  v_subject_fi text := regexp_replace(btrim(coalesce(p_subject_fi, '')), '\s+', ' ', 'g');
  v_body_fi text := btrim(coalesce(p_body_fi, ''));
  v_subject_en text := regexp_replace(btrim(coalesce(p_subject_en, '')), '\s+', ' ', 'g');
  v_body_en text := btrim(coalesce(p_body_en, ''));
  v_n int := 0;
  v_bad int := 0;
  v_queued int := 0;
  v_skipped int := 0;
  v_log bigint;
  rec record;
  v_lang text;
  v_site text;
  v_op text;
  v_url text;
  v_pvm text;
  v_kello text;
  v_hlot text;
  v_tuote text;
  v_vars jsonb;
  v_subj text;
  v_bod text;
  v_ok boolean;
  v_status text;
  v_dedupe text;
begin
  perform booking._require_permission('messages.edit');
  if p_from is null then perform booking._err('invalid_param', 'Valitse päivä tai aikaväli'); end if;
  v_from := p_from;
  v_to := coalesce(p_to, p_from);
  if v_to < v_from then perform booking._err('invalid_param', 'Loppupäivä ei voi olla ennen alkupäivää'); end if;
  if (v_to - v_from) > 366 then perform booking._err('invalid_param', 'Aikaväli on liian pitkä'); end if;
  select array_agg(distinct x order by x) into v_ids
    from unnest(coalesce(p_product_ids, '{}'::bigint[])) as x
   where x is not null;
  if v_ids is null or cardinality(v_ids) < 1 then perform booking._err('invalid_param', 'Valitse vähintään yksi tuote'); end if;
  if exists (select 1 from unnest(v_ids) i where not exists (select 1 from kb.products p where p.id = i)) then
    perform booking._err('not_found', 'Tuntematon tuote');
  end if;
  if char_length(v_subject_fi) < 1 or char_length(v_subject_en) < 1 then perform booking._err('no_subject', 'Aihe puuttuu'); end if;
  if char_length(v_subject_fi) > 200 or char_length(v_subject_en) > 200 then perform booking._err('subject_long', 'Aihe on liian pitkä'); end if;
  if char_length(v_body_fi) < 1 or char_length(v_body_en) < 1 then perform booking._err('no_body', 'Viesti puuttuu'); end if;
  if char_length(v_body_fi) > 4000 or char_length(v_body_en) > 4000 then perform booking._err('body_long', 'Viesti on liian pitkä'); end if;
  if booking._event_message_blocked(v_subject_fi) or booking._event_message_blocked(v_body_fi)
     or booking._event_message_blocked(v_subject_en) or booking._event_message_blocked(v_body_en) then
    perform booking._err('provider_name', 'Viestissä ei saa olla maksuvälittäjän nimeä');
  end if;

  v_site := coalesce(booking._setting('site_base_url') #>> '{}', '');
  v_op := coalesce(booking._setting('order_page_path') #>> '{}', '/tilaus/');

  select count(*) filter (where r.email is not null and booking._valid_email(r.email)),
         count(*) filter (where r.email is null or not booking._valid_email(r.email))
    into v_n, v_bad
    from booking._customer_message_recipients(v_from, v_to, v_ids) r;
  if v_n + v_bad > 500 then perform booking._err('too_many', 'Liian monta vastaanottajaa'); end if;

  if coalesce(p_confirm, false) is not true then
    return jsonb_build_object(
      'ok', true, 'sent', false,
      'recipient_count', v_n, 'skipped_count', v_bad,
      'signature', null,
      'recipients', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'name', r.cust_name, 'order_no', r.order_no, 'persons', r.persons,
                 'language', case when r.locale = 'en' then 'en' else 'fi' end
               ) order by r.cust_name, r.order_id)
          from booking._customer_message_recipients(v_from, v_to, v_ids) r
         where r.email is not null and booking._valid_email(r.email)
      ), '[]'::jsonb),
      'skipped', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'name', r.cust_name, 'order_no', r.order_no, 'reason', 'no_email'
               ) order by r.cust_name, r.order_id)
          from booking._customer_message_recipients(v_from, v_to, v_ids) r
         where r.email is null or not booking._valid_email(r.email)
      ), '[]'::jsonb),
      'preview', (
        select jsonb_build_object(
          'name', r.cust_name, 'order_no', r.order_no,
          'subject_fi', booking._customer_message_fill(v_subject_fi, jsonb_build_object(
            'tuote', coalesce(r.tuote_fi, ''), 'paivamaara',
            case when r.hit_kind = 'reservation'
                 then to_char(r.starts_at at time zone 'Europe/Helsinki', 'DD.MM.YYYY')
                 else to_char(r.paid_at at time zone 'Europe/Helsinki', 'DD.MM.YYYY') end,
            'kellonaika', case when r.hit_kind = 'reservation'
              then to_char(r.starts_at at time zone 'Europe/Helsinki', 'HH24:MI')
                   || case when r.ends_at is null then '' else '–' || to_char(r.ends_at at time zone 'Europe/Helsinki', 'HH24:MI') end
              else '' end,
            'asiakkaan_nimi', coalesce(r.cust_name, ''),
            'henkilomaara', case when r.hit_kind = 'reservation' then coalesce(r.persons::text, '') else '' end,
            'tilauslinkki', v_site || v_op || '?t=' || r.public_token)),
          'body_fi', booking._customer_message_fill(v_body_fi, jsonb_build_object(
            'tuote', coalesce(r.tuote_fi, ''), 'paivamaara',
            case when r.hit_kind = 'reservation'
                 then to_char(r.starts_at at time zone 'Europe/Helsinki', 'DD.MM.YYYY')
                 else to_char(r.paid_at at time zone 'Europe/Helsinki', 'DD.MM.YYYY') end,
            'kellonaika', case when r.hit_kind = 'reservation'
              then to_char(r.starts_at at time zone 'Europe/Helsinki', 'HH24:MI')
                   || case when r.ends_at is null then '' else '–' || to_char(r.ends_at at time zone 'Europe/Helsinki', 'HH24:MI') end
              else '' end,
            'asiakkaan_nimi', coalesce(r.cust_name, ''),
            'henkilomaara', case when r.hit_kind = 'reservation' then coalesce(r.persons::text, '') else '' end,
            'tilauslinkki', v_site || v_op || '?t=' || r.public_token)),
          'subject_en', booking._customer_message_fill(v_subject_en, jsonb_build_object(
            'tuote', coalesce(r.tuote_en, ''), 'paivamaara',
            case when r.hit_kind = 'reservation'
                 then to_char(r.starts_at at time zone 'Europe/Helsinki', 'DD.MM.YYYY')
                 else to_char(r.paid_at at time zone 'Europe/Helsinki', 'DD.MM.YYYY') end,
            'kellonaika', case when r.hit_kind = 'reservation'
              then to_char(r.starts_at at time zone 'Europe/Helsinki', 'HH24:MI')
                   || case when r.ends_at is null then '' else '–' || to_char(r.ends_at at time zone 'Europe/Helsinki', 'HH24:MI') end
              else '' end,
            'asiakkaan_nimi', coalesce(r.cust_name, ''),
            'henkilomaara', case when r.hit_kind = 'reservation' then coalesce(r.persons::text, '') else '' end,
            'tilauslinkki', v_site || v_op || '?t=' || r.public_token)),
          'body_en', booking._customer_message_fill(v_body_en, jsonb_build_object(
            'tuote', coalesce(r.tuote_en, ''), 'paivamaara',
            case when r.hit_kind = 'reservation'
                 then to_char(r.starts_at at time zone 'Europe/Helsinki', 'DD.MM.YYYY')
                 else to_char(r.paid_at at time zone 'Europe/Helsinki', 'DD.MM.YYYY') end,
            'kellonaika', case when r.hit_kind = 'reservation'
              then to_char(r.starts_at at time zone 'Europe/Helsinki', 'HH24:MI')
                   || case when r.ends_at is null then '' else '–' || to_char(r.ends_at at time zone 'Europe/Helsinki', 'HH24:MI') end
              else '' end,
            'asiakkaan_nimi', coalesce(r.cust_name, ''),
            'henkilomaara', case when r.hit_kind = 'reservation' then coalesce(r.persons::text, '') else '' end,
            'tilauslinkki', v_site || v_op || '?t=' || r.public_token))
        )
          from booking._customer_message_recipients(v_from, v_to, v_ids) r
         where r.email is not null and booking._valid_email(r.email)
         order by r.cust_name, r.order_id
         limit 1
      )
    );
  end if;

  if v_n < 1 then perform booking._err('no_recipients', 'Ei vastaanottajia'); end if;
  v_skipped := v_bad;

  insert into booking.customer_messages(
    date_from, date_to, product_ids, subject_fi, body_fi, subject_en, body_en,
    recipient_count, queued_count, skipped_count, created_by)
  values (v_from, v_to, v_ids, v_subject_fi, v_body_fi, v_subject_en, v_body_en,
          v_n, 0, v_skipped, auth.uid())
  returning id into v_log;

  for rec in
    select * from booking._customer_message_recipients(v_from, v_to, v_ids) r
     where r.email is not null and booking._valid_email(r.email)
     order by r.order_id
  loop
    v_lang := case when rec.locale = 'en' then 'en' else 'fi' end;
    v_url := v_site || v_op || '?t=' || rec.public_token;
    v_tuote := case when v_lang = 'en' then rec.tuote_en else rec.tuote_fi end;
    if rec.hit_kind = 'reservation' then
      v_pvm := to_char(rec.starts_at at time zone 'Europe/Helsinki', 'DD.MM.YYYY');
      v_kello := to_char(rec.starts_at at time zone 'Europe/Helsinki', 'HH24:MI');
      if rec.ends_at is not null then
        v_kello := v_kello || '–' || to_char(rec.ends_at at time zone 'Europe/Helsinki', 'HH24:MI');
      end if;
      v_hlot := coalesce(rec.persons::text, '');
    else
      v_pvm := to_char(rec.paid_at at time zone 'Europe/Helsinki', 'DD.MM.YYYY');
      v_kello := '';
      v_hlot := '';
    end if;
    v_vars := jsonb_build_object(
      'tuote', coalesce(v_tuote, ''),
      'paivamaara', coalesce(v_pvm, ''),
      'kellonaika', coalesce(v_kello, ''),
      'asiakkaan_nimi', coalesce(rec.cust_name, ''),
      'henkilomaara', coalesce(v_hlot, ''),
      'tilauslinkki', coalesce(v_url, '')
    );
    if v_lang = 'en' then
      v_subj := booking._customer_message_fill(v_subject_en, v_vars);
      v_bod := booking._customer_message_fill(v_body_en, v_vars);
    else
      v_subj := booking._customer_message_fill(v_subject_fi, v_vars);
      v_bod := booking._customer_message_fill(v_body_fi, v_vars);
    end if;
    v_dedupe := 'customer_message:' || v_log::text || ':' || rec.order_id::text;
    v_ok := booking._enqueue_email('event_message', rec.order_id, null, null, v_dedupe, jsonb_strip_nulls(jsonb_build_object(
      'message_id', v_log, 'subject', v_subj, 'body', v_bod)));
    if coalesce(v_ok, false) then
      select e.status into v_status from booking.email_outbox e where e.dedupe_key = v_dedupe;
      if v_status = 'pending' then v_queued := v_queued + 1; else v_skipped := v_skipped + 1; end if;
    else
      v_skipped := v_skipped + 1;
    end if;
  end loop;

  update booking.customer_messages set queued_count = v_queued, skipped_count = v_skipped where id = v_log;
  return jsonb_build_object(
    'ok', true, 'sent', true, 'id', v_log,
    'recipient_count', v_n, 'queued_count', v_queued, 'skipped_count', v_skipped,
    'signature', null);
end $$;

create or replace function booking.admin_customer_messages_list()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform booking._require_permission('messages.edit');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', m.id,
             'date_from', m.date_from,
             'date_to', m.date_to,
             'product_ids', m.product_ids,
             'subject_fi', m.subject_fi,
             'recipient_count', m.recipient_count,
             'queued_count', m.queued_count,
             'skipped_count', m.skipped_count,
             'created_at', m.created_at
           ) order by m.created_at desc, m.id desc)
      from (
        select * from booking.customer_messages
         order by created_at desc, id desc
         limit 30
      ) m
  ), '[]'::jsonb);
end $$;

comment on function booking.admin_customer_message_send(date, date, bigint[], text, text, text, text, boolean) is
  'booking_257: esikatselu (p_confirm false) tai lähetys valitun päivän/välin ja tuotteiden varaajille ja ostajille. messages.edit. Yksi viesti per asiakas. Kind event_message ilman event_name/when_text.';
comment on function booking.admin_customer_messages_list() is
  'booking_257: lähetettyjen asiakasviestien loki. Henkilökunta. Ei vastaanottajien osoitteita.';

do $$
declare f text;
begin
  foreach f in array array[
    'booking._customer_message_fill(text, jsonb)',
    'booking._customer_message_product_name(bigint, text)',
    'booking._customer_message_hits(date, date, bigint[])',
    'booking._customer_message_recipients(date, date, bigint[])',
    'booking.admin_customer_message_send(date, date, bigint[], text, text, text, text, boolean)',
    'booking.admin_customer_messages_list()'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  execute 'grant execute on function booking.admin_customer_message_send(date, date, bigint[], text, text, text, text, boolean) to authenticated, service_role';
  execute 'grant execute on function booking.admin_customer_messages_list() to authenticated, service_role';
end $$;

notify pgrst, 'reload schema';
