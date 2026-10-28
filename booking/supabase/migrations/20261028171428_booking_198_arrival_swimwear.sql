-- booking_198: saapumisajan muoto ja torstain uima-asuohje.
-- EI ajeta tästä commitista. Dev ja tuotanto ajetaan katselmoinnin jälkeen.
--
-- {saapumisaika} oli "31.10.2026 16:30". Pohja "Saavu klo {saapumisaika}" näkyi
-- "Saavu klo 31.10.2026 16:30". Uusi FI-arvo on "31.10.2026 klo 16.30", joten
-- pohjista poistetaan erillinen "klo " paikkamerkin edestä.
-- Yleisen vuoron kuvauksesta korjataan torstain uima-asu (käytetään, kuten la–su).
-- Tuotekuvauksessa sanojen välissä voi olla NBSP (U+00A0), siksi regexp_replace molemmille kielille.
-- Viikko-ohjelman Turvetorstai 16–19 on repossa content/kb/kb.json (ei tätä taulua).

set local lock_timeout = '5s';

create or replace function booking._message_vars(p_order_id bigint, p_message_id bigint, p_locale text)
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
  select string_agg(
      case when v_loc = 'en'
        then to_char(r.starts_at at time zone 'Europe/Helsinki', 'DD.MM.YYYY') || ' at ' || to_char(r.starts_at at time zone 'Europe/Helsinki', 'HH24:MI')
        else to_char(r.starts_at at time zone 'Europe/Helsinki', 'DD.MM.YYYY') || ' klo ' || to_char(r.starts_at at time zone 'Europe/Helsinki', 'HH24.MI')
      end, ', ' order by r.starts_at)
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

revoke all on function booking._message_vars(bigint, bigint, text) from public, anon, authenticated;

update booking.messages set
  short_fi = case when short_fi is null then null else replace(replace(short_fi, 'klo {saapumisaika}', '{saapumisaika}'), 'Torstain vuorolla uima-asu on vapaaehtoinen', 'Torstain vuorolla saunotaan uima-asussa') end,
  body_fi = case when body_fi is null then null else replace(replace(body_fi, 'klo {saapumisaika}', '{saapumisaika}'), 'Torstain vuorolla uima-asu on vapaaehtoinen', 'Torstain vuorolla saunotaan uima-asussa') end,
  subject_fi = case when subject_fi is null then null else replace(replace(subject_fi, 'klo {saapumisaika}', '{saapumisaika}'), 'Torstain vuorolla uima-asu on vapaaehtoinen', 'Torstain vuorolla saunotaan uima-asussa') end,
  short_en = case when short_en is null then null else replace(short_en, 'On the Thursday session, swimwear is optional', 'On the Thursday session, swimwear is worn') end,
  body_en = case when body_en is null then null else replace(body_en, 'On the Thursday session, swimwear is optional', 'On the Thursday session, swimwear is worn') end,
  subject_en = case when subject_en is null then null else replace(subject_en, 'On the Thursday session, swimwear is optional', 'On the Thursday session, swimwear is worn') end
where short_fi like '%klo {saapumisaika}%'
   or body_fi like '%klo {saapumisaika}%'
   or subject_fi like '%klo {saapumisaika}%'
   or short_fi like '%uima-asu on vapaaehtoinen%'
   or body_fi like '%uima-asu on vapaaehtoinen%'
   or subject_fi like '%uima-asu on vapaaehtoinen%'
   or short_en ilike '%thursday session, swimwear is optional%'
   or body_en ilike '%thursday session, swimwear is optional%'
   or subject_en ilike '%thursday session, swimwear is optional%';

update kb.products set
  description = regexp_replace(description, 'Torstain[[:space:]\u00a0]+vuorolla[[:space:]\u00a0]+uima-asu[[:space:]\u00a0]+on[[:space:]\u00a0]+vapaaehtoinen', 'Torstain vuorolla saunotaan uima-asussa', 'g'),
  description_en = regexp_replace(description_en, 'On[[:space:]\u00a0]+the[[:space:]\u00a0]+Thursday[[:space:]\u00a0]+session,[[:space:]\u00a0]+swimwear[[:space:]\u00a0]+is[[:space:]\u00a0]+optional', 'On the Thursday session, swimwear is worn', 'g')
where slug = 'yleinensauna';
