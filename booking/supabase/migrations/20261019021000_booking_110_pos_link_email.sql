-- ============================================================
-- booking_110_pos_link_email: pikakassan maksulinkki asiakkaan sähköpostiin.
-- Uudet funktiot: admin_pos_send_link, admin_pos_email_status.
-- Ei muuta olemassa olevia funktioita, resend-tilaa eikä vismapay-tilaa.
-- Oikeus: booking._require_pos_operator() (pos.use tai settings.edit).
-- Grant: authenticated ja service_role, kuten admin_pos_status. Ei anonille eikä publicille.
-- Rollback: rollbacks/20261019021000_booking_110_ROLLBACK.sql
-- ============================================================
set local lock_timeout = '5s';

create function booking.admin_pos_send_link(p_order_id bigint, p_email text, p_resend boolean default false)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  o booking.orders;
  v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  v_cur text;
  v_cust bigint;
  v_pay jsonb;
  v_pid bigint;
  v_link jsonb;
  v_have int;
  v_prev timestamptz;
  v_n int;
  v_dedupe text;
  v_queued boolean;
  v_status text;
  v_local text;
  v_dom text;
  v_masked text;
begin
  perform booking._require_pos_operator();
  if p_order_id is null then perform booking._err('not_found', 'Kassatilausta ei löydy'); end if;
  select * into o from booking.orders where id = p_order_id and source_channel = 'pikakassa' for update;
  if not found then perform booking._err('not_found', 'Kassatilausta ei löydy'); end if;
  -- _create_link_payment siirtää payment_status-arvon pending-tilaan, joten uudelleenlähetys pitää sallia.
  if o.status is distinct from 'pending' or o.payment_status not in ('unpaid', 'pending') then
    perform booking._err('order_not_editable', 'Tilaukselle ei voi lähettää maksulinkkiä');
  end if;
  if v_email is null or not booking._valid_email(v_email) then
    perform booking._err('invalid_email', 'Sähköposti ei ole kelvollinen');
  end if;

  if o.customer_id is not null then
    select lower(btrim(coalesce(c.email, ''))) into v_cur
      from booking.customers c where c.id = o.customer_id;
  end if;
  -- Osoite ei päivitä olemassa olevan asiakkaan kenttää. Uusi osoite haetaan tai luodaan ja tilaus liitetään siihen.
  if o.customer_id is null or (o.payment_status in ('unpaid', 'pending') and v_cur is distinct from v_email) then
    select c.id into v_cust from booking.customers c
     where lower(c.email) = v_email and c.anonymized_at is null
     order by c.id desc limit 1;
    if v_cust is null then
      insert into booking.customers(name, email, language, marketing_consent, marketing_consent_source)
      values (v_email, v_email, case when o.locale in ('fi', 'en', 'sv') then o.locale else 'fi' end, false, 'pikakassa')
      returning id into v_cust;
    end if;
    if o.customer_id is distinct from v_cust then
      update booking.orders set customer_id = v_cust where id = o.id;
      o.customer_id := v_cust;
    end if;
  end if;

  v_pay := booking._create_link_payment(o.id, 1, 'pikakassa');
  v_pid := (v_pay ->> 'payment_id')::bigint;
  v_link := booking._link_json(v_pid);

  select count(*), max(e.created_at) into v_have, v_prev
    from booking.email_outbox e
   where e.payment_id = v_pid
     and e.dedupe_key like 'pos_link:' || v_pid::text || ':%';
  if coalesce(p_resend, false) then
    if v_have >= 3 then
      perform booking._err('rate_limited', 'Maksulinkki on lähetetty jo kolme kertaa');
    end if;
    if v_prev is not null and v_prev > now() - interval '60 seconds' then
      perform booking._err('rate_limited', 'Odota hetki ennen uutta lähetystä');
    end if;
    v_n := v_have;
  else
    v_n := 0;
  end if;

  v_dedupe := 'pos_link:' || v_pid::text || ':' || v_n::text;
  v_queued := booking._enqueue_email('payment_link', o.id, null, v_pid, v_dedupe);
  select e.status into v_status from booking.email_outbox e where e.dedupe_key = v_dedupe;

  v_local := split_part(v_email, '@', 1);
  v_dom := split_part(v_email, '@', 2);
  v_masked := left(v_local, 1) || '***@' || left(v_dom, 1) || '***' || coalesce(substring(v_dom from '\.[^.]*$'), '');

  return jsonb_build_object(
    'ok', true,
    'payment_id', v_pid,
    'link_path', v_link ->> 'link_path',
    'amount', v_link -> 'amount',
    'email_queued', coalesce(v_queued, false),
    'outbox_status', v_status,
    'masked_to', v_masked);
end $$;

create function booking.admin_pos_email_status(p_order_id bigint)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_email text;
  v_status text;
  v_attempts int;
  v_max int;
  v_sent timestamptz;
  v_err text;
  v_local text;
  v_dom text;
  v_masked text;
begin
  perform booking._require_pos_operator();
  if p_order_id is null or not exists (
    select 1 from booking.orders o where o.id = p_order_id and o.source_channel = 'pikakassa'
  ) then
    perform booking._err('not_found', 'Kassatilausta ei löydy');
  end if;
  select e.status, e.attempts, e.max_attempts, e.sent_at, left(e.last_error, 120), c.email
    into v_status, v_attempts, v_max, v_sent, v_err, v_email
    from booking.email_outbox e
    join booking.orders o on o.id = e.order_id
    left join booking.customers c on c.id = o.customer_id
   where e.order_id = p_order_id and e.kind = 'payment_link'
   order by e.id desc
   limit 1;
  if v_email is not null and booking._valid_email(lower(btrim(v_email))) then
    v_local := split_part(lower(btrim(v_email)), '@', 1);
    v_dom := split_part(lower(btrim(v_email)), '@', 2);
    v_masked := left(v_local, 1) || '***@' || left(v_dom, 1) || '***' || coalesce(substring(v_dom from '\.[^.]*$'), '');
  end if;
  return jsonb_build_object(
    'ok', true,
    'status', v_status,
    'attempts', v_attempts,
    'max_attempts', v_max,
    'sent_at', v_sent,
    'last_error', v_err,
    'masked_to', v_masked);
end $$;

revoke all on function booking.admin_pos_send_link(bigint, text, boolean) from public, anon;
revoke all on function booking.admin_pos_email_status(bigint) from public, anon;
grant execute on function booking.admin_pos_send_link(bigint, text, boolean) to authenticated, service_role;
grant execute on function booking.admin_pos_email_status(bigint) to authenticated, service_role;

comment on function booking.admin_pos_send_link(bigint, text, boolean) is
  'Pikakassa: luo tai käyttää maksulinkin ja jonottaa payment_link-viestin. Ei muuta resend- eikä vismapay-tilaa. Osoite palautetaan maskattuna.';
comment on function booking.admin_pos_email_status(bigint) is
  'Pikakassa: viimeisin payment_link-jonorivi. Ei palauta kokonaista sähköpostiosoitetta.';
