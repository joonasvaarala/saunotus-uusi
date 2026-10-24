-- booking_132: jonotuslista täysiin vuoroihin; sähköpostit nyt, WhatsApp vain tietomalli/ajastus (oletuksena pois).
-- Ei varaa kapasiteettia. Jonotusilmoitus ei takaa paikkaa; varaus tehdään normaalisti.
-- Uudelleenajettava: toinen ajo ei muuta mitään (if not exists / create or replace / vartioitu nimenvaihto).
-- Rollback: booking/supabase/rollbacks/20261024061231_booking_132_ROLLBACK.sql
set local lock_timeout = '5s';

-- Uusi viestityyppi email_outboxiin (booking_121:n lista + waitlist_spot_freed). Ilman tätä jonoilmoituksen
-- insert kaatuisi check-rajoitteeseen ja veisi mukanaan varauksen perumisen / pidon vanhenemisen.
alter table booking.email_outbox drop constraint if exists email_outbox_kind_check;
alter table booking.email_outbox add constraint email_outbox_kind_check
  check (kind in ('order_confirmation', 'payment_link', 'receipt', 'refund_receipt', 'cancel_request_ack', 'order_change', 'gift_card_buyer', 'gift_card_recipient', 'voucher_claim_received', 'voucher_claim_problem', 'business_quote_ack', 'business_quote_notify', 'invoice_pdf', 'product_message', 'waitlist_spot_freed'));

create table if not exists booking.waitlist_entries (
  id bigint generated always as identity primary key,
  public_token uuid not null default gen_random_uuid() unique,
  product_id bigint not null references kb.products(id),
  rule_id bigint not null references booking.schedule_rules(id),
  session_date date not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  space_id bigint not null references booking.resources(id),
  persons integer not null check (persons between 1 and 50),
  customer_name text not null,
  customer_email text not null,
  customer_phone text,
  locale text not null default 'fi' check (locale in ('fi', 'en')),
  preferred_channel text not null default 'email' check (preferred_channel in ('email', 'whatsapp', 'both')),
  whatsapp_opt_in boolean not null default false,
  status text not null default 'waiting' check (status in ('waiting','notified','booked','cancelled','expired')),
  notified_at timestamptz,
  whatsapp_queued_at timestamptz,
  whatsapp_send_after timestamptz,
  converted_order_id bigint references booking.orders(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint waitlist_window_check check (starts_at < ends_at)
);
create index if not exists waitlist_queue_idx on booking.waitlist_entries(rule_id, session_date, status, created_at);
create index if not exists waitlist_window_idx on booking.waitlist_entries(space_id, starts_at, ends_at) where status = 'waiting';
create unique index if not exists waitlist_one_active_email_idx on booking.waitlist_entries(rule_id, session_date, lower(customer_email)) where status in ('waiting','notified');
alter table booking.waitlist_entries enable row level security;
revoke all on booking.waitlist_entries from public, anon, authenticated;
grant all on booking.waitlist_entries to service_role;

insert into booking.settings(key, value) values
 ('waitlist_enabled', 'true'::jsonb),
 ('waitlist_whatsapp_enabled', 'false'::jsonb),
 ('waitlist_quiet_hours_start', '21'::jsonb),
 ('waitlist_quiet_hours_end', '8'::jsonb)
on conflict (key) do nothing;

create or replace function booking.public_join_waitlist(
  p_rule_id bigint, p_date date, p_persons integer default 1,
  p_name text default null, p_email text default null, p_phone text default null,
  p_locale text default 'fi', p_whatsapp_opt_in boolean default false
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_rule booking.schedule_rules;
  v_s record;
  v_name text := btrim(coalesce(p_name,''));
  v_email text := lower(btrim(coalesce(p_email,'')));
  v_phone text := nullif(btrim(coalesce(p_phone,'')), '');
  v_token uuid;
  v_opt boolean := coalesce(p_whatsapp_opt_in, false);
begin
  if booking._setting('waitlist_enabled', 'true'::jsonb) <> 'true'::jsonb then
    return jsonb_build_object('ok',false,'code','disabled');
  end if;
  if not booking._rate_limit('waitlist:email:' || v_email, 8, interval '10 minutes') then
    return jsonb_build_object('ok',false,'code','rate_limited');
  end if;
  if length(v_name) not between 2 and 120 then return jsonb_build_object('ok',false,'code','invalid_name'); end if;
  if length(v_email) > 200 or not booking._valid_email(v_email) then return jsonb_build_object('ok',false,'code','invalid_email'); end if;
  if v_phone is not null and (length(v_phone) > 30 or v_phone !~ '^[0-9+()\- ]{6,30}$') then
    return jsonb_build_object('ok',false,'code','invalid_phone');
  end if;
  if p_locale not in ('fi','en') or p_locale is null then return jsonb_build_object('ok',false,'code','invalid_locale'); end if;
  select * into v_rule from booking.schedule_rules where id = p_rule_id and active;
  if not found or p_date is null or p_persons is null or p_persons not between greatest(1,v_rule.min_persons) and least(50,v_rule.max_persons) then
    return jsonb_build_object('ok',false,'code','invalid_session');
  end if;
  -- Tarkistus tehdään tuoreesta saatavuudesta: sulut ja exclusive-blokit eivät ole jonotettavia.
  select * into v_s from booking._sessions(p_date,p_date,v_rule.product_id,true) s
    where s.rule_id = p_rule_id and s.session_date = p_date limit 1;
  if not found or v_s.starts_at <= now() or v_s.status <> 'full' then
    return jsonb_build_object('ok',false,'code','not_full');
  end if;
  insert into booking.waitlist_entries(product_id,rule_id,session_date,starts_at,ends_at,space_id,persons,
    customer_name,customer_email,customer_phone,locale,preferred_channel,whatsapp_opt_in)
  values (v_rule.product_id,v_rule.id,p_date,v_s.starts_at,v_s.ends_at,v_rule.space_id,p_persons,
    v_name,v_email,v_phone,p_locale,case when v_opt then 'both' else 'email' end,v_opt)
  on conflict (rule_id,session_date,(lower(customer_email))) where status in ('waiting','notified')
  do update set persons=excluded.persons, customer_name=excluded.customer_name,
    customer_phone=excluded.customer_phone,locale=excluded.locale,preferred_channel=excluded.preferred_channel,
    whatsapp_opt_in=excluded.whatsapp_opt_in,starts_at=excluded.starts_at,ends_at=excluded.ends_at,
    status='waiting',notified_at=null,whatsapp_queued_at=null,whatsapp_send_after=null,updated_at=now()
  returning public_token into v_token;
  return jsonb_build_object('ok',true,'token',v_token,'starts_at',v_s.starts_at,'ends_at',v_s.ends_at,'persons',p_persons);
end $$;

create or replace function booking.public_leave_waitlist(p_token uuid) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_n integer;
begin
  if p_token is null then return jsonb_build_object('ok',false,'code','not_found'); end if;
  update booking.waitlist_entries set status='cancelled',updated_at=now(),whatsapp_send_after=null
  where public_token=p_token and status in ('waiting','notified');
  get diagnostics v_n = row_count;
  -- Uudelleen avattu peruutuslinkki palauttaa saman turvallisen tuloksen, muttei paljasta henkilötietoja.
  return jsonb_build_object('ok',true,'cancelled',v_n>0);
end $$;

-- Sisäinen funktio. Laukeaa myös checkout-holdin vanhenemisesta booking._expire_holds:n kautta.
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
    if not found or v_s.starts_at<>w.starts_at or v_s.status<>'available' or v_s.remaining < w.persons then continue; end if;
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

create or replace function booking._waitlist_reservation_freed_trg() returns trigger language plpgsql security definer set search_path = '' as $$
declare v_old boolean; v_new boolean;
begin
  v_old := booking._res_active(old.status,old.hold_expires_at);
  if tg_op='DELETE' then
    if v_old then perform booking._notify_waitlist_for_window(old.space_id,old.starts_at,old.ends_at); end if;
    return old;
  end if;
  v_new := booking._res_active(new.status,new.hold_expires_at);
  -- Vanhentunut pending-hold ei enää ole _res_active = true, mutta sen peruuttaminen
  -- (_expire_holds) on silti vapautumissignaali ja käynnistää jonotarkistuksen.
  if (v_old or (old.status='pending' and old.hold_expires_at <= now()
                and new.status in ('expired','cancelled'))) and
     (not v_new or new.persons<old.persons or new.space_id is distinct from old.space_id
    or new.starts_at is distinct from old.starts_at or new.ends_at is distinct from old.ends_at) then
    perform booking._notify_waitlist_for_window(old.space_id,old.starts_at,old.ends_at);
  end if;
  return new;
end $$;
drop trigger if exists waitlist_reservation_freed on booking.reservations;
create trigger waitlist_reservation_freed after update or delete on booking.reservations
  for each row execute function booking._waitlist_reservation_freed_trg();

-- Konversio saman sähköpostin oikeasta varauksesta, myös maksamattomalle pidolle.
create or replace function booking._waitlist_booked_trg() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status in ('pending','confirmed','completed') then
    update booking.waitlist_entries w set status='booked',converted_order_id=new.order_id,
       whatsapp_send_after=null,updated_at=now()
    from booking.orders o join booking.customers c on c.id=o.customer_id
    where o.id=new.order_id and w.rule_id=new.rule_id
      and w.session_date=(new.starts_at at time zone 'Europe/Helsinki')::date
      and lower(w.customer_email)=lower(c.email) and w.status in ('waiting','notified');
    -- Älä lähetä viivästynyttä vapautumisviestiä henkilölle, joka ehti jo varata vuoron.
    update booking.email_outbox e set status='skipped',last_error='waitlist_booked'
      where e.kind='waitlist_spot_freed' and e.status in ('pending','failed')
      and exists (select 1 from booking.waitlist_entries w
        where w.converted_order_id=new.order_id
          and e.dedupe_key like 'waitlist:'||w.id||':spot_freed:%');
  end if;
  return new;
end $$;
drop trigger if exists waitlist_reservation_booked on booking.reservations;
create constraint trigger waitlist_reservation_booked after insert or update of status on booking.reservations
  deferrable initially deferred for each row execute function booking._waitlist_booked_trg();

-- Säilytetään booking_121:n claim-kyselyn jokainen nykyinen kenttä ja rikastetaan vain jonotusviestin payload.
-- Nimen vaihto + wrapper on atominen; rollback palauttaa täsmälleen vanhan funktion.
do $$
begin
  if to_regprocedure('booking.email_outbox_claim_base_132(integer)') is null then
    alter function booking.email_outbox_claim(integer) rename to email_outbox_claim_base_132;
  end if;
end $$;
revoke all on function booking.email_outbox_claim_base_132(integer) from public, anon, authenticated;
create or replace function booking.email_outbox_claim(p_limit integer default 20) returns jsonb
language sql volatile security definer set search_path = '' as $$
  select coalesce(jsonb_agg(case when z.item->>'kind'='waitlist_spot_freed'
    then z.item || jsonb_build_object('waitlist',(select e.payload from booking.email_outbox e where e.id=(z.item->>'id')::bigint))
    else z.item end order by z.ord),'[]'::jsonb)
  from jsonb_array_elements(booking.email_outbox_claim_base_132(p_limit)) with ordinality as z(item,ord);
$$;

create or replace function booking.admin_list_waitlist(p_from date default null,p_to date default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform booking._require_staff();
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id',w.id,'rule_id',w.rule_id,'product_id',w.product_id,'product_name',p.name,'session_date',w.session_date,
    'starts_at',w.starts_at,'ends_at',w.ends_at,'persons',w.persons,'customer_name',w.customer_name,
    'customer_email',w.customer_email,'customer_phone',w.customer_phone,'locale',w.locale,
    'status',w.status,'notified_at',w.notified_at,'whatsapp_opt_in',w.whatsapp_opt_in,
    'whatsapp_send_after',w.whatsapp_send_after,'converted_order_id',w.converted_order_id,
    'created_at',w.created_at) order by w.session_date,w.starts_at,w.created_at,w.id)
    from booking.waitlist_entries w join kb.products p on p.id=w.product_id
    where (p_from is null or w.session_date>=p_from) and (p_to is null or w.session_date<=p_to)),'[]'::jsonb);
end $$;

revoke all on function booking._notify_waitlist_for_window(bigint,timestamptz,timestamptz) from public,anon,authenticated;
revoke all on function booking._waitlist_reservation_freed_trg() from public,anon,authenticated;
revoke all on function booking._waitlist_booked_trg() from public,anon,authenticated;
revoke all on function booking.email_outbox_claim(integer) from public,anon,authenticated;
revoke all on function booking.admin_list_waitlist(date,date) from public,anon;
revoke all on function booking.public_join_waitlist(bigint,date,integer,text,text,text,text,boolean) from public;
revoke all on function booking.public_leave_waitlist(uuid) from public;
grant execute on function booking.public_join_waitlist(bigint,date,integer,text,text,text,text,boolean) to anon,authenticated,service_role;
grant execute on function booking.public_leave_waitlist(uuid) to anon,authenticated,service_role;
grant execute on function booking.admin_list_waitlist(date,date) to authenticated,service_role;
grant execute on function booking.email_outbox_claim(integer) to service_role;
