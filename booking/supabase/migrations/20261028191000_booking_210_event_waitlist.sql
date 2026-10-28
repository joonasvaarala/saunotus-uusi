-- booking_210: täydet tulevat tapahtumat jonoon. Yleiset vuorot ja niiden pito (booking_139/148) ennallaan.
-- Uudelleen käyttää booking.waitlist_entries + public_join_waitlist + email_outbox (waitlist_spot_freed).
-- Tapahtuma (kb.products.category = 'event'):
--   * liittyminen vaatii tietosuojasuostumuksen (privacy_consent_at). Nimi, sähköposti, valinnainen puhelin, henkilömäärä.
--   * vahvistus ruudulla ja yksi waitlist_joined-viesti (FI/EN, allekirjoitus Tapio templates.ts:ssä).
--   * vapautuminen (peruutus tai kapasiteetin kasvu) EI varaa. Ei pitoa. Jonossa olevat, joille paikkoja riittää,
--     saavat sähköpostin ja varauslinkin saapumisjärjestyksessä (created_at, id). Ensimmäinen varaaja saa paikan.
--   * asetus waitlist_event_notify (oletus true). Pois päältä: ei vapautumisviestejä.
--   * ilmoitukset lokiin booking.waitlist_notify_log (ei sähköpostia lokissa; entry_id).
--   * hallinta: booking.admin_event_waitlist(rule_id), vain henkilökunta.
-- Ei hintaa, ALV:tä eikä URL-muutoksia. Ei ajeta tästä työtilasta.
-- Rollback: booking/supabase/rollbacks/20261028191000_booking_210_ROLLBACK.sql
set local lock_timeout = '5s';

alter table booking.waitlist_entries add column if not exists privacy_consent_at timestamptz;
comment on column booking.waitlist_entries.privacy_consent_at is
  'booking_210: hetki, jolloin asiakas hyväksyi tietosuojaselosteen jonoon liittyessään. Tapahtumassa pakollinen.';

create table if not exists booking.waitlist_notify_log (
  id bigint generated always as identity primary key,
  entry_id bigint not null references booking.waitlist_entries(id) on delete cascade,
  rule_id bigint not null,
  session_date date not null,
  kind text not null check (kind in ('joined', 'spot_freed')),
  created_at timestamptz not null default now()
);
comment on table booking.waitlist_notify_log is
  'booking_210: tapahtuman jonoon liittyminen ja vapautumisilmoitus. Ei sähköpostia; henkilötieto on waitlist_entries-rivillä.';
create index if not exists waitlist_notify_log_rule_idx on booking.waitlist_notify_log(rule_id, created_at, id);
alter table booking.waitlist_notify_log enable row level security;
revoke all on booking.waitlist_notify_log from public, anon, authenticated;
grant all on booking.waitlist_notify_log to service_role;

insert into booking.settings(key, value) values ('waitlist_event_notify', 'true'::jsonb)
on conflict (key) do nothing;

-- Lisätään vain waitlist_joined olemassa olevaan listaan (ei kovakoodattua listaa: säilyttää muiden migraatioiden lajit, esim. booking_202 event_message).
do $k$
declare def text;
begin
  select pg_get_constraintdef(c.oid) into def from pg_constraint c
   where c.conrelid = 'booking.email_outbox'::regclass and c.conname = 'email_outbox_kind_check';
  if def is null then raise exception 'booking_210: email_outbox_kind_check puuttuu'; end if;
  if position('''waitlist_joined''' in def) > 0 then return; end if;
  if def not like '%ARRAY[%' then raise exception 'booking_210: email_outbox_kind_check muotoa ei tunnistettu'; end if;
  execute 'alter table booking.email_outbox drop constraint email_outbox_kind_check';
  execute 'alter table booking.email_outbox add constraint email_outbox_kind_check ' || replace(def, 'ARRAY[', 'ARRAY[''waitlist_joined''::text, ');
end $k$;

drop function if exists booking.public_join_waitlist(bigint, date, integer, text, text, text, text, boolean);

create or replace function booking.public_join_waitlist(
  p_rule_id bigint, p_date date, p_persons integer default 1,
  p_name text default null, p_email text default null, p_phone text default null,
  p_locale text default 'fi', p_whatsapp_opt_in boolean default false,
  p_privacy_consent boolean default false
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_rule booking.schedule_rules;
  v_s record;
  v_name text := btrim(coalesce(p_name,''));
  v_email text := lower(btrim(coalesce(p_email,'')));
  v_phone text := nullif(btrim(coalesce(p_phone,'')), '');
  v_token uuid;
  v_id bigint;
  v_opt boolean := coalesce(p_whatsapp_opt_in, false);
  v_party record;
  v_persons integer;
  v_pname text;
  v_site text;
  v_shop text;
  v_ip text := booking._client_ip();
  v_status text;
begin
  if booking._setting('waitlist_enabled', 'true'::jsonb) <> 'true'::jsonb then
    return jsonb_build_object('ok',false,'code','disabled');
  end if;
  if not booking._rate_limit('waitlist:email:' || v_email, 8, interval '10 minutes') then
    return jsonb_build_object('ok',false,'code','rate_limited');
  end if;
  -- booking_210: tapahtumajono lähettää vahvistusviestin, joten myös IP-kohtainen raja (sama malli kuin lahjakorttiostossa).
  if v_ip is not null and not booking._rate_limit('waitlist:ip:' || v_ip, 20, interval '10 minutes') then
    return jsonb_build_object('ok',false,'code','rate_limited');
  end if;
  if length(v_name) not between 2 and 120 then return jsonb_build_object('ok',false,'code','invalid_name'); end if;
  if length(v_email) > 200 or not booking._valid_email(v_email) then return jsonb_build_object('ok',false,'code','invalid_email'); end if;
  if v_phone is not null and (length(v_phone) > 30 or v_phone !~ '^[0-9+()\- ]{6,30}$') then
    return jsonb_build_object('ok',false,'code','invalid_phone');
  end if;
  if p_locale not in ('fi','en') or p_locale is null then return jsonb_build_object('ok',false,'code','invalid_locale'); end if;
  select * into v_rule from booking.schedule_rules where id = p_rule_id and active;
  if not found or p_date is null then
    return jsonb_build_object('ok',false,'code','invalid_session');
  end if;
  select * into v_party from booking._waitlist_party(p_rule_id);
  if v_party.kind = 'private' then
    v_persons := greatest(1, coalesce(v_rule.min_persons, 1));
  else
    if p_persons is null or p_persons < v_party.min_persons or p_persons > v_party.max_persons then
      return jsonb_build_object('ok',false,'code','invalid_persons','kind',v_party.kind,
        'min',v_party.min_persons,'max',v_party.max_persons);
    end if;
    v_persons := p_persons;
  end if;
  if v_party.kind = 'event' and p_privacy_consent is not true then
    return jsonb_build_object('ok',false,'code','privacy_required');
  end if;
  select * into v_s from booking._sessions(p_date,p_date,v_rule.product_id,true) s
    where s.rule_id = p_rule_id and s.session_date = p_date limit 1;
  if not found or v_s.starts_at <= now()
     or not (v_s.status = 'full'
             or (v_party.kind = 'private' and v_s.status = 'unavailable'
                 and booking._waitlist_private_taken(p_rule_id, v_s.starts_at, v_s.ends_at))) then
    return jsonb_build_object('ok',false,'code','not_full');
  end if;
  insert into booking.waitlist_entries(product_id,rule_id,session_date,starts_at,ends_at,space_id,persons,
    customer_name,customer_email,customer_phone,locale,preferred_channel,whatsapp_opt_in,privacy_consent_at)
  values (v_rule.product_id,v_rule.id,p_date,v_s.starts_at,v_s.ends_at,v_rule.space_id,v_persons,
    v_name,v_email,v_phone,p_locale,case when v_opt then 'both' else 'email' end,v_opt,
    case when p_privacy_consent is true then now() end)
  on conflict (rule_id,session_date,(lower(customer_email))) where status in ('waiting','notified')
  do update set persons=excluded.persons, customer_name=excluded.customer_name,
    customer_phone=excluded.customer_phone,locale=excluded.locale,preferred_channel=excluded.preferred_channel,
    whatsapp_opt_in=excluded.whatsapp_opt_in,starts_at=excluded.starts_at,ends_at=excluded.ends_at,
    privacy_consent_at=coalesce(excluded.privacy_consent_at, booking.waitlist_entries.privacy_consent_at),
    status='waiting',notified_at=null,whatsapp_queued_at=null,whatsapp_send_after=null,updated_at=now()
  returning id, public_token into v_id, v_token;
  if v_party.kind = 'event' then
    select coalesce(case when p_locale = 'en' then nullif(p.name_en,'') end, p.name)
      into v_pname from kb.products p where p.id = v_rule.product_id;
    v_site := rtrim(coalesce(booking._setting('site_base_url') #>> '{}',''),'/');
    v_shop := case when p_locale = 'en' then '/en/book/' else '/varaa/' end;
    -- Kuten _enqueue_email: resend-tila off -> skipped. Lisäksi varatut testitunnukset (RFC 2606/6761: .invalid, .test, .example, .localhost) -> skipped.
    v_status := case when coalesce((select c.mode from booking.integration_config c where c.key = 'resend'), 'off') = 'off'
                       or v_email ~ '[.](invalid|test|example|localhost)$' then 'skipped' else 'pending' end;
    insert into booking.email_outbox(kind,locale,dedupe_key,status,payload)
    values ('waitlist_joined', p_locale, 'waitlist_joined:'||v_id, v_status, jsonb_build_object(
      'to_email', v_email, 'to_name', v_name, 'product_name', v_pname,
      'starts_at', v_s.starts_at, 'ends_at', v_s.ends_at, 'persons', v_persons,
      'leave_url', v_site||v_shop||'?poistu_jonosta='||v_token))
    on conflict (dedupe_key) do nothing;
    insert into booking.waitlist_notify_log(entry_id, rule_id, session_date, kind)
    values (v_id, v_rule.id, p_date, 'joined');
  end if;
  return jsonb_build_object('ok',true,'token',v_token,'starts_at',v_s.starts_at,'ends_at',v_s.ends_at,
    'persons',case when v_party.kind = 'private' then null else v_persons end,'kind',v_party.kind);
end $$;


CREATE OR REPLACE FUNCTION booking._waitlist_notify_entry(p_id bigint, p_hold_expires_at timestamp with time zone)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  w booking.waitlist_entries;
  v_site text := rtrim(coalesce(booking._setting('site_base_url') #>> '{}',''),'/');
  v_shop text;
  v_name text;
  v_dedupe text;
  v_wa boolean := booking._setting('waitlist_whatsapp_enabled','false'::jsonb) = 'true'::jsonb;
  v_h integer := extract(hour from now() at time zone 'Europe/Helsinki')::int;
  v_start integer := (booking._setting('waitlist_quiet_hours_start','21'::jsonb) #>> '{}')::int;
  v_end integer := (booking._setting('waitlist_quiet_hours_end','8'::jsonb) #>> '{}')::int;
  v_wa_after timestamptz;
  v_private boolean;
begin
  select * into w from booking.waitlist_entries where id = p_id and status = 'waiting';
  if not found then return; end if;
  -- Kaupan polku kielen mukaan (content/site.json pages.book): fi /varaa/, en /en/book/.
  v_shop := case when w.locale='en' then '/en/book/' else '/varaa/' end;
  select coalesce(case when w.locale='en' then nullif(p.name_en,'') end,p.name)
    into v_name from kb.products p where p.id=w.product_id;
  -- booking_148: yksityisvuorossa henkilömäärää ei kysytty → ei viestiin eikä varauslinkkiin.
  v_private := exists (select 1 from booking.schedule_rules r where r.id = w.rule_id and r.mode = 'exclusive');
  v_dedupe := 'waitlist:'||w.id||':spot_freed:'||to_char(w.updated_at,'YYYYMMDDHH24MISSUS');
  -- Jonotuslistan sähköposti kuuluu nykyiseen send-emails -putkeen; dedupe estää kaksoislähetyksen.
  insert into booking.email_outbox(kind,locale,dedupe_key,status,payload)
  values ('waitlist_spot_freed',w.locale,v_dedupe,'pending',jsonb_build_object(
    'to_email',w.customer_email,'to_name',w.customer_name,'product_name',v_name,
    'starts_at',w.starts_at,'ends_at',w.ends_at,'persons',case when v_private then null else w.persons end,
    'book_url',v_site||v_shop||'#/varaa/'||w.rule_id||'/'||w.session_date||'/'||w.product_id
      ||case when v_private then '?' else '?n='||w.persons||'&' end||'wl='||w.public_token,
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
  -- booking_210: tapahtuman vapautumisilmoitus lokiin (ei henkilötietoja, entry_id riittää).
  if exists (select 1 from kb.products p where p.id = w.product_id and p.category = 'event') then
    insert into booking.waitlist_notify_log(entry_id, rule_id, session_date, kind)
    values (w.id, w.rule_id, w.session_date, 'spot_freed');
  end if;
  -- hold_expires_at kirjoitetaan vain pidolle; aiempi pito säilyy historiana (ei toista pitoa samaan vuoroon).
  update booking.waitlist_entries set status='notified',notified_at=now(),
    hold_expires_at=coalesce(p_hold_expires_at,hold_expires_at),
    whatsapp_send_after=v_wa_after,whatsapp_queued_at=null,updated_at=now()
  where id=w.id;
end $function$
;

CREATE OR REPLACE FUNCTION booking._waitlist_process_session(p_rule_id bigint, p_date date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  w booking.waitlist_entries;
  v_s record;
  v_product bigint;
  v_space bigint;
  v_prev text;
  v_cur integer;
  v_offered integer;
  v_hold_until timestamptz;
  v_active boolean;
  v_mode text;
  v_held integer;
  v_n integer := 0;
  v_private boolean;
  v_event boolean;
begin
  if p_rule_id is null or p_date is null then return 0; end if;
  -- Sama vuoro yksi transaktio kerrallaan (ei kahta rinnakkaista pitoa). Varattu → ohitetaan, sweep hoitaa myöhemmin.
  if not pg_try_advisory_xact_lock(hashtextextended('booking:waitlist:'||p_rule_id||':'||p_date, 0)) then return 0; end if;
  select r.product_id, r.space_id, r.mode = 'exclusive' into v_product, v_space, v_private
    from booking.schedule_rules r where r.id = p_rule_id;
  if not found then return 0; end if;
  v_event := exists (select 1 from kb.products p where p.id = v_product and p.category = 'event');
  -- Sama tilan lukko kuin varauksen kapasiteettitarkistuksella: pito ei kilpaile rinnakkaisen varauksen kanssa. Varattu → ohitetaan.
  if not pg_try_advisory_xact_lock(hashtextextended('booking:space:' || v_space::text, 0)) then return 0; end if;
  -- Raaka vapaa kapasiteetti ilman pitoja (pidot vähennetään alla itse).
  v_prev := current_setting('booking.waitlist_hold_exempt', true);
  perform set_config('booking.waitlist_hold_exempt', 'all', true);
  select * into v_s from booking._sessions(p_date,p_date,v_product,true) s
    where s.rule_id=p_rule_id and s.session_date=p_date limit 1;
  perform set_config('booking.waitlist_hold_exempt', coalesce(v_prev, ''), true);
  if not found or v_s.starts_at <= now() then return 0; end if;
  -- booking_210: tapahtumailmoitus on asetuksen takana (oletus päällä). Pois päältä ei lähetä eikä varaa.
  if v_event and booking._setting('waitlist_event_notify', 'true'::jsonb) is distinct from 'true'::jsonb then
    return 0;
  end if;
  v_cur := case when v_s.status = 'available' then greatest(coalesce(v_s.remaining,0),0) else 0 end;
  select st.offered_free into v_offered from booking.waitlist_session_state st
   where st.rule_id=p_rule_id and st.session_date=p_date;
  v_offered := coalesce(v_offered, 0);
  -- Pitotila: ilmoitus nyt antaisi pidon (vuoroon ≥ waitlist_hold_min_hours_before h).
  v_hold_until := booking._waitlist_offer_expires_at(now(), v_s.starts_at);
  -- Tapahtuma: ei pitoa eikä autovarausta. Kaikki mahtuvat saavat linkin, ensimmäinen varaaja saa paikan.
  if v_event then v_hold_until := null; end if;
  v_active := exists (select 1 from booking.waitlist_entries a
    where a.rule_id=p_rule_id and a.session_date=p_date and a.status='notified' and a.hold_expires_at > now());
  if v_hold_until is not null and v_active then
    -- Yksi pito kerrallaan: muut eivät saa mitään. Vain lasku kirjataan; kasvu jää uudeksi vapautumiseksi pidon jälkeen.
    insert into booking.waitlist_session_state(rule_id,session_date,offered_free,updated_at)
    values (p_rule_id,p_date,v_cur,now())
    on conflict (rule_id,session_date) do update
      set offered_free = least(booking.waitlist_session_state.offered_free, excluded.offered_free), updated_at = now();
    return 0;
  end if;
  v_mode := case when v_hold_until is not null and v_cur > v_offered then 'hold' else 'all' end;
  for w in select * from booking.waitlist_entries
    where rule_id=p_rule_id and session_date=p_date and status='waiting' and starts_at>now()
      and (v_mode = 'all' or hold_expires_at is null)
    order by created_at,id for update skip locked
  loop
    if v_s.starts_at<>w.starts_at or v_s.status<>'available' then continue; end if;
    -- booking_134/135: jonon järjestys, mahtuvuus ratkaisee. Vähennetään voimassa olevat pidot samasta vuorosta ja
    -- päällekkäisistä, kapasiteettipoolin jakavista vuoroista (booking_139: vain hold_expires_at > now()).
    select coalesce(sum(o.persons),0)::int into v_held
      from booking.waitlist_entries o
     where o.status='notified' and o.id<>w.id and o.starts_at>now() and o.hold_expires_at > now()
       and o.starts_at<w.ends_at and o.ends_at>w.starts_at
       and ((o.rule_id=w.rule_id and o.session_date=w.session_date)
         or exists (select 1 from booking.schedule_rule_pools a
                      join booking.schedule_rule_pools b on b.pool_id=a.pool_id
                     where a.rule_id=o.rule_id and b.rule_id=w.rule_id));
    if v_private then
      -- booking_148: yksityisvuoro vapautuu kokonaan → mahtuu aina, kun vuoro on vapaa eikä tilaa pidetä toiselle
      -- (voimassa oleva pito samaan tai päällekkäiseen yksityisvuoroon samassa tilassa).
      if exists (select 1 from booking.waitlist_entries o
                   join booking.schedule_rules orr on orr.id = o.rule_id and orr.mode = 'exclusive'
                  where o.status='notified' and o.id<>w.id and o.hold_expires_at > now()
                    and o.space_id = w.space_id and o.starts_at<w.ends_at and o.ends_at>w.starts_at) then continue; end if;
    elsif v_cur - v_held < w.persons then continue; end if;
    if v_mode = 'hold' then
      perform booking._waitlist_notify_entry(w.id, v_hold_until);
      v_n := 1;
      exit;   -- vain yksi pito
    end if;
    perform booking._waitlist_notify_entry(w.id, null);
    v_n := v_n + 1;
  end loop;
  if v_mode = 'hold' and v_n = 0 then
    -- Uusi vapautuminen, mutta kukaan mahtuva ilman aiempaa pitoa ei ole jonossa → ilmoitus kaikille mahtuville ilman pitoa.
    for w in select * from booking.waitlist_entries
      where rule_id=p_rule_id and session_date=p_date and status='waiting' and starts_at>now()
      order by created_at,id for update skip locked
    loop
      if v_s.starts_at<>w.starts_at or v_s.status<>'available' then continue; end if;
      select coalesce(sum(o.persons),0)::int into v_held
        from booking.waitlist_entries o
       where o.status='notified' and o.id<>w.id and o.starts_at>now() and o.hold_expires_at > now()
         and o.starts_at<w.ends_at and o.ends_at>w.starts_at
         and ((o.rule_id=w.rule_id and o.session_date=w.session_date)
           or exists (select 1 from booking.schedule_rule_pools a
                        join booking.schedule_rule_pools b on b.pool_id=a.pool_id
                       where a.rule_id=o.rule_id and b.rule_id=w.rule_id));
      if v_private then
        if exists (select 1 from booking.waitlist_entries o
                     join booking.schedule_rules orr on orr.id = o.rule_id and orr.mode = 'exclusive'
                    where o.status='notified' and o.id<>w.id and o.hold_expires_at > now()
                      and o.space_id = w.space_id and o.starts_at<w.ends_at and o.ends_at>w.starts_at) then continue; end if;
      elsif v_cur - v_held < w.persons then continue; end if;
      perform booking._waitlist_notify_entry(w.id, null);
      v_n := v_n + 1;
    end loop;
  end if;
  insert into booking.waitlist_session_state(rule_id,session_date,offered_free,updated_at)
  values (p_rule_id,p_date,v_cur,now())
  on conflict (rule_id,session_date) do update set offered_free = excluded.offered_free, updated_at = now();
  return v_n;
end $function$
;


-- Kapasiteetin kasvu (max_persons tai tapahtuman pooli) käsitellään heti. Peruutus kulkee yhä varaustriggerin kautta.
-- Sweep (minuutin välein) jää varalle, jos lukko oli varattu.
create or replace function booking._waitlist_event_capacity_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
declare d date;
begin
  if tg_op = 'UPDATE' and new.max_persons is not distinct from old.max_persons then return new; end if;
  if not exists (select 1 from kb.products p where p.id = new.product_id and p.category = 'event') then return new; end if;
  for d in select distinct e.session_date from booking.waitlist_entries e
            where e.rule_id = new.id and e.status = 'waiting' and e.starts_at > now()
  loop
    perform booking._waitlist_process_session(new.id, d);
  end loop;
  return new;
end $$;
drop trigger if exists waitlist_event_capacity on booking.schedule_rules;
create trigger waitlist_event_capacity after update of max_persons on booking.schedule_rules
  for each row execute function booking._waitlist_event_capacity_trg();

create or replace function booking._waitlist_pool_capacity_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
declare k record;
begin
  if tg_op = 'UPDATE' and new.capacity is not distinct from old.capacity then return new; end if;
  for k in select r.id as rule_id, e.session_date
             from booking.schedule_rule_pools rp
             join booking.schedule_rules r on r.id = rp.rule_id
             join kb.products p on p.id = r.product_id and p.category = 'event'
             join booking.waitlist_entries e on e.rule_id = r.id and e.status = 'waiting' and e.starts_at > now()
            where rp.pool_id = new.id
            group by r.id, e.session_date
  loop
    perform booking._waitlist_process_session(k.rule_id, k.session_date);
  end loop;
  return new;
end $$;
drop trigger if exists waitlist_pool_capacity on booking.resources;
create trigger waitlist_pool_capacity after update of capacity on booking.resources
  for each row execute function booking._waitlist_pool_capacity_trg();

create or replace function booking.admin_event_waitlist(p_rule_id bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._require_staff();
  if p_rule_id is null or not exists (
       select 1 from booking.schedule_rules r
       join kb.products p on p.id = r.product_id and p.category = 'event'
       where r.id = p_rule_id) then
    return '[]'::jsonb;
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', w.id, 'persons', w.persons, 'customer_name', w.customer_name,
      'customer_email', w.customer_email, 'customer_phone', w.customer_phone,
      'locale', w.locale, 'status', w.status, 'created_at', w.created_at,
      'notified_at', w.notified_at, 'privacy_consent_at', w.privacy_consent_at)
      order by w.created_at, w.id)
    from booking.waitlist_entries w
    where w.rule_id = p_rule_id and w.status in ('waiting','notified','booked')), '[]'::jsonb);
end $$;

-- Jonoviestien payload claimiin: laajennetaan booking_146:n kerrosta (ei uutta nimeämistä), jolloin ylin email_outbox_claim
-- (booking_190 / booking_202) säilyy sellaisenaan ja kutsuu edelleen tätä kerrosta.
create or replace function booking.email_outbox_claim_base_146(p_limit integer default 20) returns jsonb
language sql security definer set search_path = '' as $$
  select coalesce(jsonb_agg(case when z.item->>'kind' in ('waitlist_spot_freed', 'waitlist_joined')
    then z.item || jsonb_build_object('waitlist',(select e.payload from booking.email_outbox e where e.id=(z.item->>'id')::bigint))
    else z.item end order by z.ord),'[]'::jsonb)
  from jsonb_array_elements(booking.email_outbox_claim_base_132(p_limit)) with ordinality as z(item,ord);
$$;
revoke all on function booking.email_outbox_claim_base_146(integer) from public, anon, authenticated;

revoke all on function booking.public_join_waitlist(bigint, date, integer, text, text, text, text, boolean, boolean) from public;
revoke all on function booking._waitlist_event_capacity_trg() from public, anon, authenticated;
revoke all on function booking._waitlist_pool_capacity_trg() from public, anon, authenticated;
revoke all on function booking.admin_event_waitlist(bigint) from public, anon;
grant execute on function booking.public_join_waitlist(bigint, date, integer, text, text, text, text, boolean, boolean) to anon, authenticated, service_role;
grant execute on function booking.admin_event_waitlist(bigint) to authenticated, service_role;

comment on function booking.public_join_waitlist(bigint, date, integer, text, text, text, text, boolean, boolean) is
  'booking_210: jonoon liittyminen. Tapahtuma vaatii p_privacy_consent. Ei palauta muiden tietoja. Rajattu nopeus.';
comment on function booking.admin_event_waitlist(bigint) is
  'booking_210: tapahtumakerran jono henkilökunnalle. Ei tokenia. Tyhjä, jos sääntö ei ole tapahtuma.';
