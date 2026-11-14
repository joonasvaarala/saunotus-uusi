-- booking_305_refund_stuck_alerts: henkilökunnan hälytys jumiin jääneistä hyvityksistä (Joonaksen yötyöpyyntö t1731u, 14.11.2026).
-- Tausta: asiakkaan oma pienennys (booking_284) luo Montonio-hyvitysrivin tilaan requested (created_by null, reason customer_reduce),
--   mutta Edge montonio-refund käynnistyy vain hallinnasta (henkilökunnan JWT). Ilman valvontaa rivi voi jäädä requested-tilaan, vaikka
--   asiakkaalle on kerrottu "hyvitys käsittelyssä". Sama koskee henkilökunnan hyvityksiä, joiden lähetys katkesi, ja epäonnistuneita hyvityksiä.
-- Uudet:
--   booking.refunds_stuck_sweep()  hälytykset booking.notifications_outbox-jonoon (target 'tapio', topic 'refund_stuck', ref_table 'refunds'),
--                                   jota Työvuoro-Tapio lukee notifications_pull/ack-funktioilla. Ratkenneet hälytykset merkitään 'resolved'.
--   asetukset refund_stuck_requested_hours (24), refund_stuck_customer_hours (2), refund_stuck_processing_hours (48)
--   pg_cron-ajo booking_refunds_stuck_sweep (13 ja 43 yli joka tunti)
-- Kynnykset (aika = refunds.updated_at, kuten hallinnan Hyvitykset-listan "aging"):
--   requested > 24 h; asiakkaan oman pienennyksen hyvitys (created_by null + reason customer_reduce) requested > 2 h, koska kukaan henkilökunnasta
--   ei ole painanut lähetä-nappia; processing > 48 h (Montonio ei ole vahvistanut); failed heti (raha ei ole palautunut).
-- Ei lähetä asiakkaille mitään, ei muuta hyvityksiä eikä maksuja, ei kutsu maksupalvelua. Johku-tilaukset ohitetaan kuten Hyvitykset-listassa.
-- Yksi hälytys / hyvitys / tila / tilan alkuhetki (dedupe_key refund_stuck:<id>:<status>:<updated_at epoch>), joten uudelleenyritys voi hälyttää uudestaan.
-- Rollback: booking_305_ROLLBACK.sql
set local lock_timeout = '5s';

do $pre$
begin
  if to_regclass('booking.notifications_outbox') is null or to_regclass('booking.refunds') is null then
    raise exception 'booking_305: notifications_outbox tai refunds puuttuu. Ei muutoksia.';
  end if;
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then raise exception 'booking_305: pg_cron puuttuu. Ei muutoksia.'; end if;
  if exists (select 1 from booking.notifications_outbox where topic = 'refund_stuck') then raise exception 'booking_305: topic refund_stuck on jo käytössä. Ei muutoksia.'; end if;
end $pre$;

insert into booking.settings(key, value, description, is_public) values
  ('refund_stuck_requested_hours', '24'::jsonb, 'Hyvitysvalvonta: hälytys henkilökunnalle (topic refund_stuck), kun hyvitys on ollut tilassa requested näin monta tuntia.', false),
  ('refund_stuck_customer_hours', '2'::jsonb, 'Hyvitysvalvonta: asiakkaan oman pienennyksen hyvitys (customer_reduce), jota henkilökunta ei ole lähettänyt: hälytys näin monen tunnin jälkeen.', false),
  ('refund_stuck_processing_hours', '48'::jsonb, 'Hyvitysvalvonta: hälytys, kun maksupalvelu ei ole vahvistanut hyvitystä (processing) näin monessa tunnissa.', false)
on conflict (key) do nothing;

create or replace function booking.refunds_stuck_sweep()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_req int := greatest(coalesce((booking._setting('refund_stuck_requested_hours', '24'::jsonb) #>> '{}')::int, 24), 1);
  v_cust int := greatest(coalesce((booking._setting('refund_stuck_customer_hours', '2'::jsonb) #>> '{}')::int, 2), 1);
  v_proc int := greatest(coalesce((booking._setting('refund_stuck_processing_hours', '48'::jsonb) #>> '{}')::int, 48), 1);
  r record; v_open int := 0; v_new int := 0; v_n int; v_resolved int := 0; v_msg text; v_amt text; v_age numeric;
begin
  if booking._jwt_role() in ('anon', 'authenticated') then perform booking._err('forbidden', 'Vain palvelu'); end if;
  for r in
    select f.id, f.order_id, o.order_no, f.amount, f.provider, f.status, f.provider_status, f.reason, f.created_at, f.updated_at,
           (f.created_by is null and f.reason = 'customer_reduce') as customer_initiated, p.method,
           floor(extract(epoch from f.updated_at))::bigint as since_epoch
      from booking.refunds f
      join booking.orders o on o.id = f.order_id
      join booking.payments p on p.id = f.payment_id
     where o.external_source is null and o.johku_order_no is null and o.source_channel is distinct from 'johku_import' and p.external_source is null
       and ((f.status = 'requested'
             and f.updated_at < now() - make_interval(hours => case when f.created_by is null and f.reason = 'customer_reduce' then v_cust else v_req end))
         or (f.status = 'processing' and f.updated_at < now() - make_interval(hours => v_proc))
         or f.status = 'failed')
     order by f.id
  loop
    v_open := v_open + 1;
    v_amt := replace(to_char(r.amount, 'FM999999990.00'), '.', ',') || ' €';
    v_age := round(extract(epoch from (now() - r.updated_at)) / 3600.0, 1);
    v_msg := format('Hyvitys #%s (tilaus %s, %s, %s) ', r.id, r.order_no, v_amt, r.provider)
      || case r.status
           when 'requested' then format('on odottanut lähetystä maksupalveluun %s h (tila requested).', replace(v_age::text, '.', ','))
           when 'processing' then format('on ollut maksupalvelussa vahvistamatta %s h (tila processing%s).', replace(v_age::text, '.', ','), coalesce(', ' || r.provider_status, ''))
           else 'epäonnistui (tila failed): rahaa ei ole palautettu.' end
      || case when r.customer_initiated then ' Asiakkaan oma pienennys: asiakkaalle on kerrottu, että hyvitys on käsittelyssä.' else '' end
      || ' Avaa hallinta → Hyvitykset ja yritä uudelleen tai kirjaa käsin tehty hyvitys. Asiakkaalle ei ole lähetetty mitään tästä hälytyksestä.';
    insert into booking.notifications_outbox(topic, target, ref_table, ref_id, dedupe_key, payload)
    values ('refund_stuck', 'tapio', 'refunds', r.id, format('refund_stuck:%s:%s:%s', r.id, r.status, r.since_epoch),
            jsonb_build_object('refund_id', r.id, 'order_id', r.order_id, 'order_no', r.order_no, 'amount', r.amount, 'provider', r.provider,
                               'method', r.method, 'refund_status', r.status, 'provider_status', r.provider_status, 'reason', r.reason,
                               'customer_initiated', r.customer_initiated, 'since', r.updated_at, 'since_epoch', r.since_epoch,
                               'age_hours', v_age, 'created_at', r.created_at, 'message', v_msg))
    on conflict (dedupe_key) do nothing;
    get diagnostics v_n = row_count;
    v_new := v_new + v_n;
  end loop;
  -- hyvitys eteni (tila tai tilan alkuhetki muuttui): avoin hälytys merkitään ratkaistuksi
  update booking.notifications_outbox n
     set status = 'resolved', resolved_at = now(), resolved_reason = 'refund_' || f.status
    from booking.refunds f
   where n.topic = 'refund_stuck' and n.ref_table = 'refunds' and n.ref_id = f.id and n.status in ('new', 'acked')
     and (f.status is distinct from n.payload ->> 'refund_status'
          or floor(extract(epoch from f.updated_at))::bigint is distinct from (n.payload ->> 'since_epoch')::bigint);
  get diagnostics v_resolved = row_count;
  return jsonb_build_object('ok', true, 'open_stuck', v_open, 'alerts_queued', v_new, 'alerts_resolved', v_resolved,
                            'thresholds_hours', jsonb_build_object('requested', v_req, 'customer_requested', v_cust, 'processing', v_proc));
end $$;
comment on function booking.refunds_stuck_sweep() is
  'booking_305: hälyttää henkilökunnalle (notifications_outbox target tapio, topic refund_stuck) jumiin jääneet hyvitykset. Ei lähetä asiakkaille mitään eikä liikuta rahaa.';
revoke all on function booking.refunds_stuck_sweep() from public, anon, authenticated;
grant execute on function booking.refunds_stuck_sweep() to service_role;

do $cron$
begin
  perform cron.unschedule(j.jobid) from cron.job j where j.jobname = 'booking_refunds_stuck_sweep';
  perform cron.schedule('booking_refunds_stuck_sweep', '13,43 * * * *', 'select booking.refunds_stuck_sweep()');
end $cron$;
