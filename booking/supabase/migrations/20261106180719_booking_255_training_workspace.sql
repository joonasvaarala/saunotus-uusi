-- booking_255: rauhallinen jakson työtila. EI ajeta tästä työtilasta.
-- Bottiavustus: ensin DEV aoejjmfzulhkhxbehphs, sitten PROD sxbofnuisemspgquoxyv, ennen mergeä.
-- Lisäys vain booking-skeemaan. Ei korvaa kapasiteetti-, hinta-, checkout- tai booking_254-funktioita.
-- Viestit käyttävät nykyistä event_message / _enqueue_email -putkea. Ei cron-ajastuksia.
set local lock_timeout = '5s';

create table booking.training_session_work (
  rule_id bigint primary key references booking.schedule_rules(id) on delete cascade,
  materials_shared boolean not null default false,
  templates jsonb not null default '{}'::jsonb check (jsonb_typeof(templates) = 'object' and octet_length(templates::text) <= 20000),
  updated_at timestamptz not null default now()
);
create table booking.training_product_groups (
  product_id bigint primary key references kb.products(id) on delete cascade,
  group_kind text not null check (group_kind in ('training','trip'))
);
insert into booking.training_product_groups select id, 'trip' from kb.products where id = 121 and category = 'training';
create table booking.training_participant_details (
  reservation_id bigint primary key references booking.reservations(id) on delete cascade,
  diet text not null default '' check (char_length(diet) <= 1000),
  accommodation text not null default '' check (char_length(accommodation) <= 1000),
  arrival text not null default '' check (char_length(arrival) <= 200),
  language text not null default 'fi' check (language in ('fi','en')),
  present boolean not null default false,
  updated_at timestamptz not null default now()
);
-- Erillinen käsin hoidettava lista: olemassa olevan julkisen jonon automatiikka ei käsittele näitä rivejä.
create table booking.training_waitlist (
  id bigint generated always as identity primary key,
  rule_id bigint not null references booking.schedule_rules(id) on delete cascade,
  name text not null check (char_length(name) between 2 and 200),
  email text check (email is null or booking._valid_email(email)),
  phone text check (phone is null or char_length(phone) <= 40),
  language text not null default 'fi' check (language in ('fi','en')),
  persons integer not null default 1 check (persons between 1 and 20),
  status text not null default 'waiting' check (status in ('waiting','offered','booked','cancelled')),
  created_at timestamptz not null default now(),
  offered_at timestamptz,
  check (email is not null or phone is not null)
);
create index training_waitlist_order_idx on booking.training_waitlist(rule_id, created_at, id) where status in ('waiting','offered');
-- Esikatselun sisältö ja vastaanottajat jäädytetään. Lähetys käyttää vain tätä kertakäyttöistä tunnistetta.
create table booking.training_message_previews (
  id uuid primary key default gen_random_uuid(),
  rule_id bigint not null references booking.schedule_rules(id) on delete cascade,
  created_by uuid not null,
  content jsonb not null,
  recipients jsonb not null,
  expires_at timestamptz not null default now() + interval '30 minutes',
  sent_at timestamptz
);
create index training_message_previews_expiry_idx on booking.training_message_previews(expires_at);

do $$ declare n text; begin
  foreach n in array array['training_session_work','training_product_groups','training_participant_details','training_waitlist','training_message_previews'] loop
    execute format('alter table booking.%I enable row level security', n);
    execute format('revoke all on booking.%I from public, anon, authenticated', n);
    execute format('grant all on booking.%I to service_role', n);
  end loop;
end $$;
-- Ei vapaita tekstejä audit_logiin (ruokavalio voi olla terveystieto).
create function booking.training_details_anonymize() returns trigger
language plpgsql security definer set search_path = '' as $$ begin
  delete from booking.training_participant_details d using booking.reservations r, booking.orders o
   where d.reservation_id = r.id and r.order_id = o.id and o.customer_id = new.id;
  delete from booking.training_waitlist where lower(email) = lower(old.email);
  -- Esikatseluissa on henkilötietoja. Vanhenneet myös siivotaan seuraavan esikatselun yhteydessä.
  delete from booking.training_message_previews where exists (select 1 from jsonb_array_elements(recipients) j where (j->>'customer_id')::bigint=old.id) or expires_at < now();
  return null;
end $$;
create trigger training_details_anonymize after update of anonymized_at on booking.customers
for each row when (old.anonymized_at is null and new.anonymized_at is not null) execute function booking.training_details_anonymize();

create function booking._training_work_rule(p_rule_id bigint) returns booking.schedule_rules
language plpgsql stable security definer set search_path = '' as $$ declare r booking.schedule_rules; begin
  select sr.* into r from booking.schedule_rules sr join kb.products p on p.id = sr.product_id and p.category = 'training' where sr.id = p_rule_id;
  if not found then perform booking._err('not_found', 'Jaksoa ei löydy'); end if;
  return r;
end $$;

-- Osallistujat tulevat nykyisestä kapasiteettilogiikasta; myös Full-koulutuksen osakerran osallistujat säilyvät.
create function booking.admin_training_people(p_rule_id bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$ declare r booking.schedule_rules; begin
  perform booking._require_staff(); r := booking._training_work_rule(p_rule_id);
  return coalesce((select jsonb_agg(j || jsonb_build_object(
    'diet', coalesce(d.diet,''), 'accommodation',coalesce(d.accommodation,''), 'arrival',coalesce(d.arrival,''),
    'language',coalesce(d.language, nullif(j->>'language',''),o.locale,'fi'), 'present',coalesce(d.present,false),
    'paid_actual',coalesce(pay.paid,0), 'deposit_due',coalesce(tp.deposit_paid,pc.deposit_amount,kp.price),
    'course_total',coalesce(tp.total,pc.course_price), 'billed_total',o.total_gross,
    'due_actual',greatest(coalesce(tp.total,pc.course_price,o.total_gross)-coalesce(pay.paid,0),0)) order by j->>'name', j->>'reservation_id')
    from jsonb_array_elements(booking.admin_event_participants(r.product_id,r.id)) j
    join booking.orders o on o.id = (j->>'order_id')::bigint
    join kb.products kp on kp.id = r.product_id
    join booking.product_config pc on pc.product_id = r.product_id
    left join booking.training_participants tp on tp.order_id = o.id
    left join booking.training_participant_details d on d.reservation_id = (j->>'reservation_id')::bigint
    left join lateral (select sum(p.amount - coalesce(p.refunded_amount,0)) paid from booking.payments p where p.order_id = o.id and p.status in ('paid','partially_refunded','refunded')) pay on true
    where j->>'reservation_status' <> 'cancelled'), '[]'::jsonb);
end $$;

create function booking.admin_training_work_get(p_rule_id bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$ declare r booking.schedule_rules; begin
  perform booking._require_staff(); r := booking._training_work_rule(p_rule_id);
  return jsonb_build_object('rule',booking._event_rule_json(r.id)||jsonb_build_object('session_ends_at',greatest(upper(booking._training_rule_range(r.id)),(select max(upper(booking._training_rule_range(s.rule_id))) from booking._training_segments_of(r.id) s)),'segment_ids',(select jsonb_agg(s.rule_id order by s.sort_pos) from booking._training_segments_of(r.id) s),'training_segment_only',r.training_segment_only,'seats_remaining',booking._training_option_seats_left(r.id)), 'people',booking.admin_training_people(r.id),
    'work',coalesce((select to_jsonb(w) from booking.training_session_work w where w.rule_id = r.id),'{}'::jsonb),
    'waitlist',coalesce((select jsonb_agg(to_jsonb(w) order by w.created_at,w.id) from booking.training_waitlist w where w.rule_id = r.id and w.status in ('waiting','offered')),'[]'::jsonb),
    'messages',coalesce((select jsonb_agg(to_jsonb(m) order by m.created_at desc) from booking.event_messages m where m.rule_id = r.id),'[]'::jsonb));
end $$;
create function booking.admin_training_work_list() returns jsonb
language plpgsql stable security definer set search_path = '' as $$ begin
  perform booking._require_staff();
  return coalesce((select jsonb_agg(jsonb_build_object('rule_id',r.id,'group_kind',coalesce(g.group_kind,'training'),
    'session_ends_at',greatest(upper(booking._training_rule_range(r.id)),(select max(upper(booking._training_rule_range(s.rule_id))) from booking._training_segments_of(r.id) s)),'segment_ids',(select jsonb_agg(s.rule_id order by s.sort_pos) from booking._training_segments_of(r.id) s),'training_segment_only',r.training_segment_only,'seats_remaining',booking._training_option_seats_left(r.id),
    'materials_shared',coalesce(w.materials_shared,false), 'message_sent',exists(select 1 from booking.event_messages m where m.rule_id=r.id and m.queued_count>0),
    'open_payments',(select count(*) from jsonb_array_elements(booking.admin_training_people(r.id)) j where (j->>'due_actual')::numeric>0.004)))
    from booking.schedule_rules r join kb.products p on p.id=r.product_id and p.category='training'
    left join booking.training_product_groups g on g.product_id=p.id left join booking.training_session_work w on w.rule_id=r.id),'[]'::jsonb);
end $$;
create function booking.admin_training_work_save(p_rule_id bigint,p_materials_shared boolean,p_templates jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$ begin
  perform booking._require_staff(); perform booking._training_work_rule(p_rule_id);
  insert into booking.training_session_work(rule_id,materials_shared,templates) values(p_rule_id,p_materials_shared,coalesce(p_templates,'{}'::jsonb))
  on conflict(rule_id) do update set materials_shared=excluded.materials_shared,templates=excluded.templates,updated_at=now();
  return jsonb_build_object('ok',true);
end $$;
create function booking.admin_training_person_save(p_reservation_id bigint,p_details jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$ declare rid bigint; begin
  perform booking._require_staff();
  select r.rule_id into rid from booking.reservations r join booking.orders o on o.id=r.order_id left join booking.customers c on c.id=o.customer_id
   where r.id=p_reservation_id and c.anonymized_at is null;
  perform booking._training_work_rule(rid);
  insert into booking.training_participant_details(reservation_id,diet,accommodation,arrival,language,present)
  values(p_reservation_id,coalesce(p_details->>'diet',''),coalesce(p_details->>'accommodation',''),coalesce(p_details->>'arrival',''),coalesce(p_details->>'language','fi'),coalesce((p_details->>'present')::boolean,false))
  on conflict(reservation_id) do update set diet=excluded.diet,accommodation=excluded.accommodation,arrival=excluded.arrival,language=excluded.language,present=excluded.present,updated_at=now();
  return jsonb_build_object('ok',true);
end $$;

-- Sama mekanismi kuin nykyisissä tapahtumasuluissa: event_resource_blocks -> _event_sync_blocks -> space_blocks.
-- Tilalukko on sama kuin varauksilla ja Työvuoro-Tapion käsisuluilla. Käsisulkuja ei korvata eikä poisteta.
create function booking.admin_training_space_add(p_rule_id bigint,p_space_id bigint,p_date date,p_start time,p_end time) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r booking.schedule_rules; s timestamptz; e timestamptz; v_id bigint; begin
  perform booking._require_permission('blocks.manage');
  perform 1 from booking.schedule_rules where id=p_rule_id for update;
  r := booking._training_work_rule(p_rule_id);
  if not r.active or r.cancelled_at is not null then perform booking._err('invalid_param','Jakso ei ole käytössä'); end if;
  if not exists(select 1 from booking.resources where id=p_space_id and active and kind='space' and code in ('savusauna','hoitosauna_rauni','hoitosauna_lovi','rauni','lovi')) then
    perform booking._err('invalid_resource','Valitse Savusauna, Rauni tai Lovi'); end if;
  if p_date is null or p_start is null or p_end is null or p_end<=p_start then perform booking._err('invalid_param','Tarkista päivä ja kellonajat'); end if;
  if p_date<r.valid_from-1 or p_date>((r.valid_from+r.start_time+make_interval(mins=>r.duration_minutes))::date+1) then perform booking._err('invalid_param','Valitse jakson päivä'); end if;
  s := (p_date+p_start) at time zone booking._tz(); e := (p_date+p_end) at time zone booking._tz();
  perform booking._lock_resources(array[p_space_id]); perform booking._expire_holds(p_space_id);
  if exists(select 1 from booking.space_blocks b where b.space_id=p_space_id and b.active and b.during && tstzrange(s,e,'[)'))
    or exists(select 1 from booking.v_claims c where c.resource_id=p_space_id and booking._res_active(c.status,c.hold_expires_at) and tstzrange(c.claim_start,c.claim_end,'[)') && tstzrange(s,e,'[)')) then
    perform booking._err('conflict','Tila on jo varattu tai suljettu tälle ajalle'); end if;
  insert into booking.event_resource_blocks(rule_id,resource_id,mode,start_day,start_clock,end_day,end_clock,note,sort_order)
  values(r.id,p_space_id,'exclusive',p_date-r.valid_from,p_start,p_date-r.valid_from,p_end,'Koulutus / matka',100) returning id into v_id;
  return jsonb_build_object('ok',true,'id',v_id);
end $$;
create function booking.admin_training_space_cancel(p_rule_id bigint,p_block_id bigint,p_confirm boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$ declare rid bigint; begin
  perform booking._require_permission('blocks.manage'); perform booking._training_work_rule(p_rule_id);
  if p_confirm is not true then perform booking._err('no_confirm','Vahvista peruutus'); end if;
  perform 1 from booking.schedule_rules where id=p_rule_id for update;
  select resource_id into rid from booking.event_resource_blocks where id=p_block_id and rule_id=p_rule_id and mode='exclusive';
  if rid is null then perform booking._err('not_found','Tilavarausta ei löydy'); end if;
  perform booking._lock_resources(array[rid]);
  delete from booking.event_resource_blocks where id=p_block_id and rule_id=p_rule_id;
  return jsonb_build_object('ok',true);
end $$;
-- Kalenterin nykyisiin näkymiin vain sulut: monipäiväinen sulku näkyy jokaisena peittämällään päivänä.
create function booking.admin_calendar_space_blocks(p_from timestamptz,p_to timestamptz) returns jsonb
language plpgsql stable security definer set search_path = '' as $$ begin
  perform booking._require_staff();
  if p_from is null or p_to is null or p_to<=p_from or p_to-p_from>interval '93 days' then perform booking._err('bad_range','Virheellinen aikaväli'); end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',b.id,'space_id',b.space_id,'space_name',r.name,'starts_at',b.starts_at,'ends_at',b.ends_at,'reason',b.reason) order by b.starts_at,b.id)
    from booking.space_blocks b join booking.resources r on r.id=b.space_id where b.active and b.starts_at<p_to and b.ends_at>p_from),'[]'::jsonb);
end $$;

create function booking.admin_training_waitlist_add(p_rule_id bigint,p_person jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$ declare v_id bigint; begin
  perform booking._require_staff(); perform booking._training_work_rule(p_rule_id);
  insert into booking.training_waitlist(rule_id,name,email,phone,language,persons)
  values(p_rule_id,btrim(p_person->>'name'),nullif(btrim(p_person->>'email'),''),nullif(btrim(p_person->>'phone'),''),coalesce(p_person->>'language','fi'),coalesce((p_person->>'persons')::int,1)) returning id into v_id;
  return jsonb_build_object('ok',true,'id',v_id);
end $$;
create function booking.admin_training_waitlist_update(p_rule_id bigint,p_id bigint,p_status text) returns jsonb
language plpgsql security definer set search_path = '' as $$ declare next_id bigint; w booking.training_waitlist; begin
  perform booking._require_staff(); perform booking._training_work_rule(p_rule_id);
  perform 1 from booking.schedule_rules where id=p_rule_id for update;
  select * into w from booking.training_waitlist where id=p_id and rule_id=p_rule_id for update;
  if not found then perform booking._err('not_found','Odottajaa ei löydy'); end if;
  if p_status='offered' then
    select id into next_id from booking.training_waitlist where rule_id=p_rule_id and status in ('waiting','offered') order by created_at,id limit 1;
    if next_id<>p_id or w.status<>'waiting' then perform booking._err('queue_order','Tarjoa paikka ensin jonon ensimmäiselle'); end if;
    if coalesce(booking._training_option_seats_left(p_rule_id),0)<w.persons then perform booking._err('capacity_exceeded','Paikkoja ei ole vielä vapautunut'); end if;
  elsif p_status not in ('booked','cancelled') then perform booking._err('invalid_param','Virheellinen tila'); end if;
  update booking.training_waitlist set status=p_status,offered_at=case when p_status='offered' then now() else offered_at end where id=p_id;
  return jsonb_build_object('ok',true);
end $$;

-- Ei muuteta nykyistä ilmoittautumisfunktiota. Henkilökunnan lisäys kuluttaa samat osakerrat.
create function booking.admin_training_person_add(p_rule_id bigint,p_customer jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r booking.schedule_rules; pc booking.product_config; result jsonb; oid bigint; resid bigint; sid bigint; segid bigint; dep numeric; begin
  perform booking._require_permission('bookings.manage'); r:=booking._training_work_rule(p_rule_id);
  if not r.active or r.cancelled_at is not null or r.valid_from<(now() at time zone booking._tz())::date then perform booking._err('invalid_param','Jakso ei ole varattavissa'); end if;
  perform sr.id from booking.schedule_rules sr where sr.id=p_rule_id or sr.id in(select booking._training_segment_ids(p_rule_id)) order by sr.id for update;
  perform booking._lock_resources(coalesce((select array_agg(distinct rp.pool_id order by rp.pool_id) from booking.schedule_rule_pools rp where rp.rule_id=p_rule_id or rp.rule_id in(select booking._training_segment_ids(p_rule_id))),'{}'));
  if coalesce(booking._training_option_seats_left(p_rule_id),0)<1 then perform booking._err('capacity_exceeded','Jakso on täynnä'); end if;
  select * into pc from booking.product_config where product_id=r.product_id;
  select coalesce(pc.deposit_amount,kp.price) into dep from kb.products kp where kp.id=r.product_id;
  result:=booking.admin_create_booking(p_rule_id=>r.id,p_date=>r.valid_from,p_persons=>1,p_customer=>p_customer,p_payment_method=>'pay_later',p_paid=>false,p_price=>dep);
  oid:=(result->>'order_id')::bigint; resid:=(result->>'reservation_id')::bigint;
  for sid in select s.rule_id from booking._training_segments_of(r.id) s where s.rule_id<>r.id order by s.rule_id loop
    if not exists(select 1 from booking.reservations where order_id=oid and rule_id=sid) then
      segid:=booking._training_hold_segment(oid,sid,now()+interval '1 hour');
      update booking.reservations set status='confirmed',hold_expires_at=null where id=segid;
    end if;
  end loop;
  update booking.orders set locale=coalesce(p_customer->>'language','fi') where id=oid;
  insert into booking.training_participants(reservation_id,order_id,name,email,phone,language,privacy_consent_at,course_price,total,deposit_paid,remaining,segments)
  values(resid,oid,p_customer->>'name',p_customer->>'email',p_customer->>'phone',coalesce(p_customer->>'language','fi'),now(),pc.course_price,pc.course_price,dep,pc.course_price-dep,booking._training_segment_json(r.id))
  on conflict(reservation_id) do nothing;
  return result;
end $$;

-- Vastaanottajat aina vain valitusta jaksosta, myös Full-koulutuksen osakertalaiset; yksi viesti/tilaus.
create function booking._training_message_recipients(p_rule_id bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.order_id),'[]'::jsonb) from (
    select distinct on (o.id) o.id order_id,o.customer_id,c.name,c.email,
      case when coalesce(d.language,tp.language,o.locale)='en' then 'en' else 'fi' end language
    from booking._event_rule_res_ids(p_rule_id) ids join booking.reservations r on r.id=ids.id
    join booking.orders o on o.id=r.order_id join booking.customers c on c.id=o.customer_id
    left join booking.training_participants tp on tp.order_id=o.id
    left join booking.training_participant_details d on d.reservation_id=r.id
    where (booking._res_active(r.status,r.hold_expires_at) or r.status='completed') and o.external_source is null and c.anonymized_at is null and booking._valid_email(c.email)
    order by o.id,r.id
  ) x
$$;
create function booking.admin_training_message_preview(p_rule_id bigint,p_content jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$ declare r booking.schedule_rules; recs jsonb; mid uuid; lng text; c jsonb; span tstzrange; first_day text; last_day text; begin
  perform booking._require_permission('messages.edit'); r:=booking._training_work_rule(p_rule_id);
  foreach lng in array array['fi','en'] loop
    c:=p_content->lng;
    if coalesce(char_length(btrim(c->>'subject')),0) not between 1 and 200 or coalesce(char_length(btrim(c->>'body')),0) not between 1 and 4000 then perform booking._err('invalid_param','Täytä molempien kielten aihe ja viesti'); end if;
    if booking._event_message_blocked(c->>'subject') or booking._event_message_blocked(c->>'body') then perform booking._err('provider_name','Tarkista viestin sisältö'); end if;
  end loop;
  -- Sama aihe-normalisointi kuin nykyisessä sähköpostipohjassa. Päivä/nimi jäädytetään esikatseluun.
  foreach lng in array array['fi','en'] loop
    c:=p_content->lng;
    p_content:=jsonb_set(p_content,array[lng],jsonb_build_object('subject',btrim(regexp_replace(regexp_replace(c->>'subject','[<>]','','g'),'\s+',' ','g')),'body',btrim(c->>'body')));
  end loop;
  span:=booking._training_rule_range(r.id);
  first_day:=to_char(lower(span) at time zone booking._tz(),'DD.MM.YYYY');
  last_day:=to_char((upper(span)-interval '1 microsecond') at time zone booking._tz(),'DD.MM.YYYY');
  p_content:=jsonb_build_object('fi',p_content->'fi','en',p_content->'en','_context',
    jsonb_build_object('event_name',(select name from kb.products where id=r.product_id),
      'event_name_en',(select name_en from kb.products where id=r.product_id),
      'starts_at',lower(span),'when_text',first_day||case when last_day<>first_day then ' – '||last_day else '' end));
  delete from booking.training_message_previews where expires_at<now();
  recs:=booking._training_message_recipients(r.id);
  if jsonb_array_length(recs)=0 then perform booking._err('no_recipients','Jaksolla ei ole sähköpostivastaanottajia'); end if;
  insert into booking.training_message_previews(rule_id,created_by,content,recipients) values(r.id,auth.uid(),p_content,recs) returning id into mid;
  return jsonb_build_object('id',mid,'recipients',recs,'content',p_content,'signature',null);
end $$;
create function booking.admin_training_message_send(p_preview_id uuid,p_confirm boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare pv booking.training_message_previews; r booking.schedule_rules; rec jsonb; c jsonb; logid bigint; n int:=0; begin
  perform booking._require_permission('messages.edit');
  if p_confirm is not true then perform booking._err('no_confirm','Esikatsele ja vahvista viesti'); end if;
  select * into pv from booking.training_message_previews where id=p_preview_id and created_by=auth.uid() for update;
  if not found or pv.expires_at<now() then perform booking._err('preview_expired','Esikatsele viesti uudelleen'); end if;
  if pv.sent_at is not null then return jsonb_build_object('ok',true,'already_sent',true,'queued_count',0); end if;
  if pv.recipients is distinct from booking._training_message_recipients(pv.rule_id) then perform booking._err('preview_changed','Osallistujat ovat muuttuneet. Esikatsele uudelleen'); end if;
  r:=booking._training_work_rule(pv.rule_id);
  insert into booking.event_messages(product_id,rule_id,subject,body,recipient_count,queued_count,skipped_count,created_by)
  values(r.product_id,r.id,pv.content#>>'{fi,subject}',pv.content#>>'{fi,body}',jsonb_array_length(pv.recipients),0,0,auth.uid()) returning id into logid;
  for rec in select value from jsonb_array_elements(pv.recipients) loop
    c:=pv.content->(rec->>'language');
    if booking._enqueue_email('event_message',(rec->>'order_id')::bigint,null,null,'training_message:'||pv.id||':'||(rec->>'order_id'),
      (pv.content->'_context')||jsonb_build_object('message_id',logid,'subject',c->>'subject','body',c->>'body')) then
      update booking.email_outbox set locale=rec->>'language' where dedupe_key='training_message:'||pv.id||':'||(rec->>'order_id');
      n:=n+1;
    end if;
  end loop;
  update booking.event_messages set queued_count=n,skipped_count=jsonb_array_length(pv.recipients)-n where id=logid;
  update booking.training_message_previews set sent_at=now() where id=pv.id;
  return jsonb_build_object('ok',true,'queued_count',n);
end $$;

-- Kopioi valittu jakso ja kaikki sen osakerrat uudeksi piilotetuksi koulutukseksi.
-- Omat uudet kapasiteetit, ei osallistujia, maksuja, jonoa tai lähetyshistoriaa. Tilavaraukset lukitaan ja tarkistetaan.
create function booking.admin_training_session_copy(p_rule_id bigint,p_date date,p_name text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r booking.schedule_rules; src booking.schedule_rules; np kb.products; ids bigint[]; oldid bigint; newid bigint; anchor bigint; mp jsonb:='{}'; variants jsonb; delta int; begin
  perform booking._require_permission('catalog.edit'); r:=booking._training_work_rule(p_rule_id);
  if p_date is null or p_date< (now() at time zone booking._tz())::date or abs(p_date-r.valid_from)>3650 or char_length(btrim(p_name)) not between 2 and 200 then perform booking._err('invalid_param','Anna nimi ja uusi aloituspäivä'); end if;
  delta:=p_date-r.valid_from;
  with recursive deps(id) as (select p_rule_id union select s.segment_rule_id from booking.training_segments s join deps d on d.id=s.option_rule_id)
  select array_agg(id order by id) into ids from deps;
  perform sr.id from booking.schedule_rules sr where sr.id=any(ids) order by sr.id for update;
  perform booking._lock_resources(coalesce((select array_agg(distinct b.resource_id order by b.resource_id) from booking.event_resource_blocks b where b.rule_id=any(ids)),'{}'));
  np:=booking._product_copy_core(r.product_id);
  variants:=coalesce(nullif(current_setting('booking.m158_variant_map',true),''),'{}')::jsonb;
  update kb.products set name=btrim(p_name),name_en=btrim(p_name),active=false where id=np.id;
  insert into booking.training_product_groups(product_id,group_kind) values(np.id,coalesce((select group_kind from booking.training_product_groups where product_id=r.product_id),'training'));
  foreach oldid in array ids loop
    src:=booking._training_work_rule(oldid);
    newid:=booking._event_rule_copy_core(oldid,np.id,src.valid_from+delta,true,variants);
    update booking.schedule_rules set single_room_max=src.single_room_max,training_segment_only=(oldid<>r.id),label=to_char(src.valid_from+delta,'DD.MM.YYYY'),label_en=to_char(src.valid_from+delta,'DD Mon YYYY') where id=newid;
    mp:=mp||jsonb_build_object(oldid::text,newid);
    insert into booking.training_session_work(rule_id,templates) select newid,w.templates from booking.training_session_work w where w.rule_id=oldid;
    -- Kaikki sulut tarkistetaan, mukaan lukien käsisulut, eivät vain toisten tapahtumien sulut.
    if exists(select 1 from booking.event_resource_blocks b join booking.space_blocks own on own.event_block_id=b.id
      join booking.space_blocks other on other.space_id=own.space_id and other.active and other.during&&own.during and other.id<>own.id
      where b.rule_id=newid) then perform booking._err('conflict','Kopioitavan jakson tilavarauksella on päällekkäisyys'); end if;
    perform booking._event_raise_conflicts(newid);
  end loop;
  insert into booking.training_segments(option_rule_id,position,segment_rule_id)
  select (mp->>s.option_rule_id::text)::bigint,s.position,(mp->>s.segment_rule_id::text)::bigint from booking.training_segments s where s.option_rule_id=any(ids);
  anchor:=(mp->>r.id::text)::bigint;
  return jsonb_build_object('ok',true,'product_id',np.id,'rule_id',anchor,'rules_copied',cardinality(ids),'hidden',true);
end $$;

-- Loppumaksu lisätään vain nimenomaisella henkilökunnan teolla, nykyisen lisäostotoiminnon kautta.
-- Snapshot-hinnat ja alkuperäisen rivin ALV säilyvät, ei uutta hinnanlaskentaa. Toistokutsu ei lisää toista riviä.
create function booking.admin_training_prepare_balance(p_rule_id bigint,p_order_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$ declare tp booking.training_participants; rem numeric; vat numeric; result jsonb; begin
  perform booking._require_permission('payments.manage'); perform booking._training_work_rule(p_rule_id);
  if not exists(select 1 from booking._event_rule_res_ids(p_rule_id) ids join booking.reservations r on r.id=ids.id where r.order_id=p_order_id and r.status<>'cancelled') then perform booking._err('not_found','Osallistuja ei kuulu jaksoon'); end if;
  perform 1 from booking.orders where id=p_order_id for update;
  select * into tp from booking.training_participants where order_id=p_order_id order by id limit 1;
  if tp.total is null then perform booking._err('invalid_price','Kurssin kokonaishintaa ei ole tallennettu'); end if;
  if exists(select 1 from booking.order_items where order_id=p_order_id and price_breakdown->>'training_balance'='true') then return jsonb_build_object('ok',true,'already_prepared',true); end if;
  rem:=round(tp.total-tp.deposit_paid,2);
  if rem<=0 then return jsonb_build_object('ok',true,'already_prepared',true); end if;
  select vat_rate into vat from booking.order_items where order_id=p_order_id and kind='reservation' order by id limit 1;
  result:=booking.admin_add_to_order(p_order_id,jsonb_build_array(jsonb_build_object('type','custom','description',case when tp.language='en' then 'Course balance' else 'Koulutuksen loppumaksu' end,'amount',rem,'vat_rate',vat,'quantity',1)),false,false,null);
  update booking.order_items set price_breakdown=price_breakdown||jsonb_build_object('training_balance',true) where order_id=p_order_id and id=(result#>>'{added,0,item_id}')::bigint;
  return result;
end $$;

-- Maksulinkki vaatii esikatselussa nähdyn summan ja sähköpostin. Lukitus estää summan vaihtumisen lähetyksessä.
-- Nykyisen maksulinkin mahdollinen muistutusketju pysäytetään samassa transaktiossa.
create function booking.admin_training_payment_link(p_rule_id bigint,p_order_id bigint,p_expected_amount numeric,p_expected_email text,p_confirm boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$ declare amount numeric; email text; result jsonb; pid bigint; begin
  perform booking._require_permission('payments.manage'); perform booking._training_work_rule(p_rule_id);
  if p_confirm is not true then perform booking._err('no_confirm','Esikatsele maksulinkki ensin'); end if;
  if not exists(select 1 from booking._event_rule_res_ids(p_rule_id) ids join booking.reservations r on r.id=ids.id where r.order_id=p_order_id and r.status<>'cancelled') then perform booking._err('not_found','Osallistuja ei kuulu jaksoon'); end if;
  perform 1 from booking.orders where id=p_order_id for update;
  amount:=(booking._order_balance(p_order_id)->>'unpaid')::numeric;
  select c.email into email from booking.orders o join booking.customers c on c.id=o.customer_id where o.id=p_order_id;
  if p_expected_amount is null or amount<=0 or abs(amount-p_expected_amount)>0.004 or lower(email) is distinct from lower(p_expected_email) then perform booking._err('preview_changed','Maksu tai vastaanottaja on muuttunut. Esikatsele uudelleen'); end if;
  result:=booking.admin_create_payment_link(p_order_id,true,null,null); pid:=(result->>'payment_id')::bigint;
  if pid is not null then
    update booking.payments set reminders_paused_at=coalesce(reminders_paused_at,now()) where id=pid;
    update booking.email_outbox set status='skipped',last_error='reminders_paused',locked_at=null where payment_id=pid and kind='payment_link_reminder' and status in ('pending','failed');
  end if;
  return result;
end $$;

-- Valittujen maksulinkit yhdessä transaktiossa: virhe ei jätä puolta ryhmästä lähetetyksi.
create function booking.admin_training_payment_links(p_rule_id bigint,p_rows jsonb,p_confirm boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$ declare item jsonb; result jsonb:='[]'; begin
  perform booking._require_permission('payments.manage'); perform booking._training_work_rule(p_rule_id);
  if p_confirm is not true then perform booking._err('no_confirm','Esikatsele maksulinkit ensin'); end if;
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) not between 1 and 100 then perform booking._err('invalid_param','Valitse osallistujat'); end if;
  perform o.id from booking.orders o where o.id in(select (j->>'order_id')::bigint from jsonb_array_elements(p_rows) j) order by o.id for update;
  for item in select value from jsonb_array_elements(p_rows) loop
    result:=result||booking.admin_training_payment_link(p_rule_id,(item->>'order_id')::bigint,(item->>'amount')::numeric,item->>'email',true);
  end loop;
  return jsonb_build_object('ok',true,'payments',result);
end $$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure sig,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='booking' and p.proname = any (array['training_details_anonymize','_training_work_rule','admin_training_people','admin_training_work_get','admin_training_work_list','admin_training_work_save','admin_training_person_save','admin_training_space_add','admin_training_space_cancel','admin_calendar_space_blocks','admin_training_waitlist_add','admin_training_waitlist_update','admin_training_person_add','_training_message_recipients','admin_training_message_preview','admin_training_message_send','admin_training_session_copy','admin_training_prepare_balance','admin_training_payment_link','admin_training_payment_links']) loop
    execute format('revoke all on function %s from public, anon, authenticated',f.sig);
    if f.proname like 'admin_%' then execute format('grant execute on function %s to authenticated, service_role',f.sig);
    else execute format('grant execute on function %s to service_role',f.sig); end if;
  end loop;
end $$;
notify pgrst, 'reload schema';
