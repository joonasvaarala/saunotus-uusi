-- booking_137: jonotuslistan tarjousaika ja pito (Joonaksen päätös t161u).
-- * Vuoron alkuun vähintään waitlist_hold_min_hours_before (oletus 48) tuntia ilmoitushetkellä → pito: booking_135:n logiikka
--   (jonon järjestys, ensimmäinen mahtuva), ilmoitetun paikat pidetään waitlist_offer_minutes (oletus 120) min eikä niitä
--   tarjota muille. Vanhentunut pito → claim palauttaa offer_expired; seuraava ajo tarjoaa paikat seuraavalle.
-- * Alle 48 h → ei pitoa: ilmoitus kaikille jonossa oleville, jotka mahtuvat vapaisiin paikkoihin. Nämä ilmoitukset eivät
--   vähennä vapaita paikkoja eivätkä estä toisia ilmoituksia; paikka on myynnissä, ensimmäinen varaaja saa sen. Claim
--   tarkistaa vain mahtuvuuden (enough=false kuten ennen).
-- * Ilmoitus lähtee jonovaraukselle vain tilasta 'waiting' (idempotenssi ennallaan: 'notified' ei saa uutta ilmoitusta).
-- * Uusi sisäinen booking._waitlist_offer_expires_at(notified_at, starts_at): pidon päättymisaika tai null, jos pitoa ei ole.
--   _notify_waitlist_for_window vähentää vain voimassa olevat pidot (myös alle 48 h:n ajossa: aiemmin alkanut pito kunnioitetaan
--   loppuun); booking_135:ssä kaikki ilmoitukset pidettiin 60 min.
-- * Asetusrivit lisätään idempotentisti (on conflict do nothing): olemassa olevaa arvoa ei ylikirjoiteta.
--   Puuttuva tai virheellinen asetus → oletukset 120 min / 48 h.
-- Ei taulumuutoksia, ei public-skeemaa. Uudelleenajettava.
-- Rollback: booking/supabase/rollbacks/20261024095000_booking_137_ROLLBACK.sql (booking_135-tila).
set local lock_timeout = '5s';

insert into booking.settings(key, value, description) values
 ('waitlist_offer_minutes', '120'::jsonb, 'Jonotuslista: pidon kesto minuutteina, kun vuoroon on ilmoitushetkellä vähintään waitlist_hold_min_hours_before tuntia. Oletus 120.'),
 ('waitlist_hold_min_hours_before', '48'::jsonb, 'Jonotuslista: alle tämän tuntimäärän ennen vuoroa paikkoja ei pidetä, vaan ilmoitus lähtee kaikille mahtuville. Oletus 48.')
on conflict (key) do nothing;

-- Pidon päättymisaika: notified_at + waitlist_offer_minutes, jos starts_at - notified_at >= waitlist_hold_min_hours_before;
-- muuten null (ei pitoa). Ei kaada kutsujaa virheellisellä asetuksella (laukeaa varaustriggereistä notify-funktion kautta).
create or replace function booking._waitlist_offer_expires_at(p_notified_at timestamptz, p_starts_at timestamptz)
returns timestamptz language plpgsql stable security definer set search_path = '' as $$
declare
  v_raw text;
  v_hours integer := 48;
  v_mins integer := 120;
begin
  if p_notified_at is null or p_starts_at is null then return null; end if;
  -- Sisäkkäinen case/if: ::int-muunnos vasta, kun arvo on varmasti numeroita (AND-ehtojen järjestystä ei taata).
  v_raw := booking._setting('waitlist_hold_min_hours_before') #>> '{}';
  if v_raw ~ '^[0-9]{1,5}$' then v_hours := v_raw::int; end if;
  if p_starts_at - p_notified_at < make_interval(hours => v_hours) then return null; end if;
  v_raw := booking._setting('waitlist_offer_minutes') #>> '{}';
  if v_raw ~ '^[0-9]{1,6}$' then
    if v_raw::int >= 1 then v_mins := v_raw::int; end if;
  end if;
  return p_notified_at + make_interval(mins => v_mins);
end $$;
revoke all on function booking._waitlist_offer_expires_at(timestamptz,timestamptz) from public,anon,authenticated;

create or replace function booking._notify_waitlist_for_window(p_space_id bigint,p_starts_at timestamptz,p_ends_at timestamptz)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  w booking.waitlist_entries;
  v_s record;
  v_site text := rtrim(coalesce(booking._setting('site_base_url') #>> '{}',''),'/');
  v_shop text;
  v_name text;
  v_dedupe text;
  v_wa boolean := booking._setting('waitlist_whatsapp_enabled','false'::jsonb) = 'true'::jsonb;
  v_h integer := extract(hour from now() at time zone 'Europe/Helsinki')::int;
  v_start integer := (booking._setting('waitlist_quiet_hours_start','21'::jsonb) #>> '{}')::int;
  v_end integer := (booking._setting('waitlist_quiet_hours_end','8'::jsonb) #>> '{}')::int;
  v_wa_after timestamptz;
  v_n integer := 0;
  v_held integer;
  v_left integer;
begin
  if booking._setting('waitlist_enabled','true'::jsonb) <> 'true'::jsonb then return 0; end if;
  if p_space_id is null or p_starts_at is null or p_ends_at is null then return 0; end if;
  for w in select * from booking.waitlist_entries
    where space_id=p_space_id and status='waiting' and starts_at>now()
      and starts_at<p_ends_at and ends_at>p_starts_at
    order by created_at,id for update skip locked
  loop
    select * into v_s from booking._sessions(w.session_date,w.session_date,w.product_id,true) s
      where s.rule_id=w.rule_id and s.session_date=w.session_date limit 1;
    if not found or v_s.starts_at<>w.starts_at or v_s.status<>'available' then continue; end if;
    -- booking_134: jonon järjestys säilyy, mutta mahtuvuus ratkaisee; liian iso jonovaraus ohitetaan.
    -- booking_135: vapaista paikoista vähennetään kaikki voimassa olevat ilmoitukset (myös aiemmista ajoista ja
    -- samassa ajossa juuri ilmoitetut) samasta vuorosta sekä päällekkäisistä vuoroista, jotka jakavat kapasiteettipoolin.
    -- booking_137: vain voimassa olevat pidot (_waitlist_offer_expires_at; alle 48 h ennen vuoroa tehdyt ilmoitukset eivät pidä
    -- paikkoja → kaikki mahtuvat saavat ilmoituksen, eikä tämän ajon ilmoitus vähennä seuraavien vapaita paikkoja).
    select coalesce(sum(o.persons),0)::int into v_held
      from booking.waitlist_entries o
     where o.status='notified' and o.id<>w.id and o.starts_at>now()
       and booking._waitlist_offer_expires_at(coalesce(o.notified_at,o.updated_at),o.starts_at) > now()
       and o.starts_at<w.ends_at and o.ends_at>w.starts_at
       and ((o.rule_id=w.rule_id and o.session_date=w.session_date)
         or exists (select 1 from booking.schedule_rule_pools a
                      join booking.schedule_rule_pools b on b.pool_id=a.pool_id
                     where a.rule_id=o.rule_id and b.rule_id=w.rule_id));
    v_left := v_s.remaining - v_held;
    if v_left < w.persons then continue; end if;
    -- Kaupan polku kielen mukaan (content/site.json pages.book): fi /varaa/, en /en/book/.
    v_shop := case when w.locale='en' then '/en/book/' else '/varaa/' end;
    select coalesce(case when w.locale='en' then nullif(p.name_en,'') end,p.name)
      into v_name from kb.products p where p.id=w.product_id;
    v_dedupe := 'waitlist:'||w.id||':spot_freed:'||to_char(w.updated_at,'YYYYMMDDHH24MISSUS');
    -- Jonotuslistan sähköposti kuuluu nykyiseen send-emails -putkeen; dedupe estää kaksoislähetyksen.
    insert into booking.email_outbox(kind,locale,dedupe_key,status,payload)
    values ('waitlist_spot_freed',w.locale,v_dedupe,'pending',jsonb_build_object(
      'to_email',w.customer_email,'to_name',w.customer_name,'product_name',v_name,
      'starts_at',w.starts_at,'ends_at',w.ends_at,'persons',w.persons,
      'book_url',v_site||v_shop||'#/varaa/'||w.rule_id||'/'||w.session_date||'/'||w.product_id||'?n='||w.persons||'&wl='||w.public_token,
      'leave_url',v_site||v_shop||'?poistu_jonosta='||w.public_token))
    on conflict (dedupe_key) do nothing;
    v_wa_after := null;
    if v_wa and w.whatsapp_opt_in and w.customer_phone is not null then
      if v_start > v_end then
        if v_h >= v_start then
          v_wa_after := (((now() at time zone 'Europe/Helsinki')::date + 1)::timestamp + make_interval(hours=>v_end)) at time zone 'Europe/Helsinki';
        elsif v_h < v_end then
          v_wa_after := ((now() at time zone 'Europe/Helsinki')::date::timestamp + make_interval(hours=>v_end)) at time zone 'Europe/Helsinki';
        else v_wa_after := now(); end if;
      else
        v_wa_after := case when v_h >= v_start and v_h < v_end then
          ((now() at time zone 'Europe/Helsinki')::date::timestamp + make_interval(hours=>v_end)) at time zone 'Europe/Helsinki'
          else now() end;
      end if;
    end if;
    update booking.waitlist_entries set status='notified',notified_at=now(),
      whatsapp_send_after=v_wa_after,whatsapp_queued_at=null,updated_at=now()
    where id=w.id;
    v_n:=v_n+1;
  end loop;
  return v_n;
end $$;

-- booking_135: rate limit vasta, kun token vastaa aktiivista jonovarausta (tuntematon token → not_found ilman riviä).
-- booking_137: vanhentunut pito → offer_expired. Muuten sama kuin booking_135.
create or replace function booking.public_waitlist_claim(p_token uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  w booking.waitlist_entries;
  v_s record;
  v_enough boolean;
  v_ip text := booking._client_ip();
  v_exp timestamptz;
begin
  if p_token is null then return jsonb_build_object('ok',false,'code','not_found'); end if;
  select * into w from booking.waitlist_entries where public_token = p_token and status in ('waiting','notified') for update;
  if not found then return jsonb_build_object('ok',false,'code','not_found'); end if;
  if not booking._rate_limit('waitlist:claim:' || p_token::text, 30, interval '10 minutes')
     or (v_ip is not null and not booking._rate_limit('waitlist:claim:ip:' || v_ip, 60, interval '10 minutes')) then
    return jsonb_build_object('ok',false,'code','rate_limited');
  end if;
  if w.starts_at <= now() then return jsonb_build_object('ok',false,'code','expired'); end if;
  -- booking_137: ilmoitetun jonovarauksen pito on vanhentunut → selkeä koodi. Tila pysyy 'notified' (ei palaa jonon
  -- kärkeen eikä saa uutta ilmoitusta); varauksen voi silti tehdä normaalisti, jos paikkoja on. Ilman pitoa (alle 48 h)
  -- päättymisaika on null → vain mahtuvuus ratkaisee.
  v_exp := booking._waitlist_offer_expires_at(coalesce(w.notified_at,w.updated_at),w.starts_at);
  if w.status = 'notified' and v_exp is not null and v_exp <= now() then
    return jsonb_build_object('ok',false,'code','offer_expired');
  end if;
  select * into v_s from booking._sessions(w.session_date,w.session_date,w.product_id,true) s
    where s.rule_id = w.rule_id and s.session_date = w.session_date limit 1;
  v_enough := found and v_s.starts_at = w.starts_at and v_s.status = 'available' and v_s.remaining >= w.persons;
  if not v_enough and w.status = 'notified' then
    -- clock_timestamp: uusi updated_at → uusi dedupe-avain seuraavalle ilmoitukselle.
    update booking.waitlist_entries set status='waiting',notified_at=null,whatsapp_queued_at=null,whatsapp_send_after=null,
      updated_at=clock_timestamp() where id = w.id;
  end if;
  return jsonb_build_object('ok',true,'rule_id',w.rule_id,'product_id',w.product_id,'session_date',w.session_date,
    'persons',w.persons,'enough',v_enough);
end $$;

revoke all on function booking.public_waitlist_claim(uuid) from public;
grant execute on function booking.public_waitlist_claim(uuid) to anon,authenticated,service_role;
revoke all on function booking._notify_waitlist_for_window(bigint,timestamptz,timestamptz) from public,anon,authenticated;
