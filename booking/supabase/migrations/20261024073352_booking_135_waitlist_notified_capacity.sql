-- booking_135: jonotuslistan jatkokorjaus booking_134:ään.
-- * _notify_waitlist_for_window: vapaista paikoista vähennetään kaikki voimassa olevat ilmoitukset, ei vain samassa
--   ajossa tehtyjä. Tuotannon vika: jonossa A5, B1, C4, D3, vapaana 4; 1. ajo ilmoitti B:lle ja D:lle, 2. ajo samalle
--   ikkunalle tarjosi samat 4 paikkaa vielä C:lle. Nyt 2. ajo näkee B:n ja D:n tarjoukset (status 'notified') ja C ohitetaan.
--   Tarjouksen voimassaolo: waitlist_entries-taulussa ei ole expires-saraketta, joten voimassaolo lasketaan
--   notified_at + asetus waitlist_offer_minutes (oletus 60 min, vähintään 1 min), ja vain tuleville vuoroille (starts_at > now()).
--   Vanhentunut tarjous ei enää varaa paikkoja: seuraava ajo voi ilmoittaa ne jonossa seuraavalle mahtuvalle.
--   Kapasiteettipoolit (booking_133 _pool_peak / _pools_remaining): vähennetään myös sellaisten sääntöjen ilmoitukset,
--   jotka jakavat vähintään yhden poolin (schedule_rule_pools) ja joiden vuoro on ajallisesti päällekkäin. Arvio on
--   varovainen (yläraja): toteutuessaan tarjous voi viedä poolista enintään henkilömääränsä verran.
--   Samassa ajossa ilmoitetut näkyvät samasta kyselystä (status 'notified', notified_at = now()), joten booking_134:n
--   v_used-laskuria ei enää tarvita, ja nyt se kattaa myös poolin jakavat säännöt.
-- * public_waitlist_claim: rate limit vain olemassa olevalle aktiiviselle tokenille (waiting/notified). Tuntematon tai
--   satunnainen token palauttaa not_found ilman rate_limit_hits-riviä. Tunnetulle tokenille lisäksi kutsujan IP-raja
--   (booking._client_ip, kun pyyntöotsakkeet ovat saatavilla), kuten muissa julkisissa RPC:issä.
-- Ei taulumuutoksia, ei public-skeemaa. Uudelleenajettava (create or replace).
-- Rollback: booking/supabase/rollbacks/20261024073352_booking_135_ROLLBACK.sql (palauttaa booking_134-tilan).
set local lock_timeout = '5s';

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
  -- booking_135: tarjouksen voimassaolo minuutteina (asetus waitlist_offer_minutes, oletus 60, vähintään 1).
  -- Virheellinen asetusarvo ei kaada perumista (funktio laukeaa varaustriggereistä), vaan käytetään oletusta.
  v_offer_raw text := booking._setting('waitlist_offer_minutes','60'::jsonb) #>> '{}';
  v_offer interval := make_interval(mins => greatest(1, case when v_offer_raw ~ '^[0-9]{1,6}$' then v_offer_raw::int else 60 end));
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
    select coalesce(sum(o.persons),0)::int into v_held
      from booking.waitlist_entries o
     where o.status='notified' and o.id<>w.id and o.starts_at>now()
       and coalesce(o.notified_at,o.updated_at) + v_offer > now()
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

-- booking_135: rate limit vasta, kun token vastaa aktiivista jonovarausta. Tuntematon token → not_found ilman
-- rate_limit_hits-riviä (satunnaiset tokenit eivät kasvata taulua). Muuten sama kuin booking_134.
create or replace function booking.public_waitlist_claim(p_token uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  w booking.waitlist_entries;
  v_s record;
  v_enough boolean;
  v_ip text := booking._client_ip();
begin
  if p_token is null then return jsonb_build_object('ok',false,'code','not_found'); end if;
  select * into w from booking.waitlist_entries where public_token = p_token and status in ('waiting','notified') for update;
  if not found then return jsonb_build_object('ok',false,'code','not_found'); end if;
  if not booking._rate_limit('waitlist:claim:' || p_token::text, 30, interval '10 minutes')
     or (v_ip is not null and not booking._rate_limit('waitlist:claim:ip:' || v_ip, 60, interval '10 minutes')) then
    return jsonb_build_object('ok',false,'code','rate_limited');
  end if;
  if w.starts_at <= now() then return jsonb_build_object('ok',false,'code','expired'); end if;
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
