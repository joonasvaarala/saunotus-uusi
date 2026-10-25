-- 20261025173107_day_digest_fixes.sql  (ajettu tuotantoon 25.10.2026 versiona 20261025173107, PR #199; runko muuttumaton — vain kommenttirivejä saa muokata)
-- Päiväkoosteen (day_digest, saman päivän useampi vuoroasia samalle henkilölle yhdellä viestillä) korjaukset. EI yhdistämistä yli päivien.
-- Riippuvuus: horisonttimigraatio 20261025165813 (booking.shift_offer_in_horizon, horisonttiversio report_issues 2bf59cf8…) — history-sync PR #198 (main 3b63d72, migrations/20261025165813_shift_offer_horizon.sql).
--  #1 B2: lähetetty kooste jatkaa jokaisen yhdistetyn tarjous-/muistutusvastaanottajan määräaikaa kuten yksittäinen lähetys
--     (WhatsApp sender_complete → deadline_on_sent; sähköposti shift_offer_email_sent_trg → deadline_on_sent). Vain onnistuneesta
--     lähetyksestä, kerran per kooste ja kerran per yhdistetty viesti. Koosteen näyttämä määräaika = deadline_preview hetkellä, jona
--     lähetys sen kirjaa (merge piirtää jonossa olevat koosteet joka sender_claim-ajolla; claim now() = locked_at = email_outbox.created_at).
--  #2 resend_lost: kadonnut kooste lähetetään uudelleen, jos yksikin yhdistetty on henkilölle yhä auki; teksti ja rivit vain avoimista.
--  #3 wa_ready('day_digest') tarkistaa day_digest-pohjan hyväksynnän kuten tarjous → hyväksymätön/yö: sähköposti heti (edge whatsapp.ts).
--  #4 merge: horisontin ulkopuolinen jonossa oleva tarjous/muistutus/jo mennyt → skipped 'horizon' (fail-closed); samoin kooste,
--     jonka kaikki rivit ovat horisontin ulkopuolella.
--  report_issues: no_working_channel laskee koosteen jokaisena yhdistettynä tarjouksena.
-- Moottorin kytkimiin, allowlistiin, tervetuloon ja pohjiin ei kosketa (jälkitarkistus). Rollback: rollbacks/20261025173107_day_digest_fixes_ROLLBACK.sql
-- md5(pg_get_functiondef) ennen -> jälkeen:
--     booking.shift_offer_merge_same_day(timestamptz): 963eba4f116ca88cb7ab766533f5d05d -> 6f02c362e1708e7ebd96db25d0b680c9
--     booking.shift_offer_deadline_on_sent(bigint,timestamptz): 103efa77f733a3c5d42bac53d49a4b4e -> 82529d71053b2ef6ca0a77e56443cde7
--     booking.shift_offer_resend_lost(timestamptz): f73ac1325a2228d61fffe4ae42ca193d -> 97931068bf0322fd7d9afb8c453530e7
--     booking.shift_offer_wa_ready(uuid,text,text): d7148175ce2c9768ca8b807571f5fb72 -> 8f0532dce5b6a8ce00b7b61b323a9923
--     booking.shift_offer_report_issues(timestamptz): 2bf59cf81a7d8231c2fe0f550eaf5923 -> 6019cf1835e31ff11124b68a74407d76
--     booking.shift_offer_digest_items(bigint,timestamptz,boolean): (uusi) -> acb945537f8d9b01972aae746e7e27b9
--     booking.shift_offer_digest_body(uuid,date,text): (uusi) -> 86a8f7c5deae16b7b53e541f65824f1d
-- riippuvuudet (ennallaan): shift_offer_sender_claim d6a47aa4, shift_offer_sender_complete c29ed4d2, shift_offer_email_drain 0d8df863, shift_offer_email_sent_trg 5eacac69, shift_offer_deadline_preview 0b48a1ea, shift_offer_extend_deadline 956adca5, shift_offer_in_horizon d8b58a6e, shift_offer_horizon_until ef7f7227, shift_offer_queue_message 0982a948, shift_offer_email f17b064c, shift_staff_page_url 37f75772, shift_offer_cap_label 9c9c5d71, shift_offer_when 2231f8a1, shift_offer_is_bot_staff 5ec483f8, shift_offer_cfg a4c2bfd3, shift_offer_cfg_bool 0a030b5b, _valid_email 6775eff3, shift_offer_phone_e164 2a3b0dd7, shift_offer_wa_open fb743be3
set local lock_timeout = '5s';

do $g$
declare v text; ok boolean := true; msg text := '';
begin
  -- korvattavat (tuotannon nykyiset, luettu SELECTillä)
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_merge_same_day(timestamptz)')));
  if v is distinct from '963eba4f116ca88cb7ab766533f5d05d' then ok := false; msg := msg || ' shift_offer_merge_same_day=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_deadline_on_sent(bigint,timestamptz)')));
  if v is distinct from '103efa77f733a3c5d42bac53d49a4b4e' then ok := false; msg := msg || ' shift_offer_deadline_on_sent=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_resend_lost(timestamptz)')));
  if v is distinct from 'f73ac1325a2228d61fffe4ae42ca193d' then ok := false; msg := msg || ' shift_offer_resend_lost=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_wa_ready(uuid,text,text)')));
  if v is distinct from 'd7148175ce2c9768ca8b807571f5fb72' then ok := false; msg := msg || ' shift_offer_wa_ready=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_report_issues(timestamptz)')));
  if v is distinct from '2bf59cf81a7d8231c2fe0f550eaf5923' then ok := false; msg := msg || ' shift_offer_report_issues=' || coalesce(v, 'puuttuu'); end if;
  -- riippuvuudet (ei muuteta, mutta korjaus nojaa niiden nykyiseen toimintaan)
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_sender_claim(integer)')));
  if v is distinct from 'd6a47aa43feb0445f0bf00d549b60905' then ok := false; msg := msg || ' shift_offer_sender_claim=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_sender_complete(jsonb)')));
  if v is distinct from 'c29ed4d23f8ede7d1ae2ef1c283f9e03' then ok := false; msg := msg || ' shift_offer_sender_complete=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_email_drain(integer)')));
  if v is distinct from '0d8df86310ad86b3a6f43429274478ed' then ok := false; msg := msg || ' shift_offer_email_drain=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_email_sent_trg()')));
  if v is distinct from '5eacac6985c8f8b2d0efc3e888994965' then ok := false; msg := msg || ' shift_offer_email_sent_trg=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_deadline_preview(bigint,timestamptz)')));
  if v is distinct from '0b48a1eab2bb8df1a5393ba9978dd40e' then ok := false; msg := msg || ' shift_offer_deadline_preview=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_extend_deadline(bigint,timestamptz)')));
  if v is distinct from '956adca5d836c2c8ea7d34c7ebb2d05c' then ok := false; msg := msg || ' shift_offer_extend_deadline=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_in_horizon(timestamptz)')));
  if v is distinct from 'd8b58a6e68c3a6c63d96c6d2e0efebad' then ok := false; msg := msg || ' shift_offer_in_horizon=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_horizon_until()')));
  if v is distinct from 'ef7f7227e66834d002ee200613f79bbd' then ok := false; msg := msg || ' shift_offer_horizon_until=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_queue_message(uuid,bigint,uuid,text,text,text)')));
  if v is distinct from '0982a948c9e5fbe882f094c269afe31c' then ok := false; msg := msg || ' shift_offer_queue_message=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_email(uuid,text,text,text,text)')));
  if v is distinct from 'f17b064c82f56f3221cc0ea3570114e1' then ok := false; msg := msg || ' shift_offer_email=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_staff_page_url(uuid)')));
  if v is distinct from '37f75772b49103d866817ef1bf9b38e8' then ok := false; msg := msg || ' shift_staff_page_url=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_cap_label(text)')));
  if v is distinct from '9c9c5d717c6fa8114591a948c11345e3' then ok := false; msg := msg || ' shift_offer_cap_label=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_when(timestamptz,timestamptz)')));
  if v is distinct from '2231f8a1e4337e43edea6f7c2078ce4a' then ok := false; msg := msg || ' shift_offer_when=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_is_bot_staff(uuid)')));
  if v is distinct from '5ec483f8c82b3f59fd89af264444333a' then ok := false; msg := msg || ' shift_offer_is_bot_staff=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_cfg(text)')));
  if v is distinct from 'a4c2bfd3bb435703a0d728a737606394' then ok := false; msg := msg || ' shift_offer_cfg=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_cfg_bool(text,boolean)')));
  if v is distinct from '0a030b5b3c7fd55594b9d9aea66373e6' then ok := false; msg := msg || ' shift_offer_cfg_bool=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._valid_email(text)')));
  if v is distinct from '6775eff3f255a0388b3da493a4d730be' then ok := false; msg := msg || ' _valid_email=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_phone_e164(text)')));
  if v is distinct from '2a3b0dd7494447d1e80a92ba6b9965bd' then ok := false; msg := msg || ' shift_offer_phone_e164=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_wa_open(timestamptz)')));
  if v is distinct from 'fb743be3b998339628748ba29cfae48d' then ok := false; msg := msg || ' shift_offer_wa_open=' || coalesce(v, 'puuttuu'); end if;
  if to_regprocedure('booking.shift_offer_digest_items(bigint,timestamptz,boolean)') is not null then ok := false; msg := msg || ' shift_offer_digest_items on jo olemassa'; end if;
  if to_regprocedure('booking.shift_offer_digest_body(uuid,date,text)') is not null then ok := false; msg := msg || ' shift_offer_digest_body on jo olemassa'; end if;
  if not ok then raise exception 'digestfix: tuotannon määrittelyt poikkeavat odotetusta:%', msg; end if;
end $g$;

create temp table digestfix_flags_before on commit drop as
select (select row_to_json(e)::jsonb - 'updated_at' from public.shift_offer_engine_settings e where e.id) as eng,
       (select jsonb_object_agg(role_type, enabled) from public.shift_offer_settings) as roles,
       (select value from booking.settings where key = 'shift_offer.welcome_enabled') as welcome,
       (select value from booking.settings where key = 'shift_offer.email_enabled') as email,
       (select value from booking.settings where key = 'shift_offer.wa_templates') as tpl;

CREATE OR REPLACE FUNCTION booking.shift_offer_digest_items(p_message bigint, p_at timestamp with time zone DEFAULT now(), p_only_open boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- digestfix #1/#2/#4: päiväkoosteen (day_digest) rivit alkuperäisistä viesteistä (meta.payload.merged_ids), samassa järjestyksessä ja
-- samassa muodossa kuin merge_same_day ne alun perin teki. Määräaika = se, jonka onnistunut lähetys hetkellä p_at kirjaisi
-- (booking.shift_offer_deadline_preview, kuten yksittäisessä tarjouksessa); jo jatkettu viesti → nykyinen deadline_at.
-- Vain horisontin sisällä alkavat vuorot (booking.shift_offer_in_horizon). p_only_open: vain yhä avoimet (tarjous active/paused,
-- vastaanottaja pending, vuoro alkaa p_at jälkeen) + alle 24 h vanhat "jo mennyt" -rivit (sama sääntö kuin resend_lost yksittäiselle).
-- Palauttaa {items, n, n_open, n_all, merged_ids, recipient_ids, first_offer_id} tai null, jos viesti ei ole päivän kooste.
declare v_p jsonb; v jsonb;
begin
  select mm.payload into v_p from booking.shift_offer_message_meta mm where mm.message_id = p_message and mm.subkind = 'day_digest';
  if v_p is null or jsonb_typeof(v_p -> 'merged_ids') is distinct from 'array' then return null; end if;
  p_at := coalesce(p_at, now());
  select jsonb_build_object(
           'items', string_agg(x.line, '; ' order by x.st, x.ord) filter (where x.keep),
           'n', count(*) filter (where x.keep),
           'n_open', count(*) filter (where x.keep and x.is_open),
           'n_all', count(*),
           'merged_ids', coalesce(jsonb_agg(x.id order by x.st, x.ord) filter (where x.keep), '[]'::jsonb),
           'recipient_ids', coalesce(jsonb_agg(x.recipient_id order by x.id) filter (where x.keep and x.recipient_id is not null), '[]'::jsonb),
           'first_offer_id', (array_agg(x.offer_id order by x.st, x.ord) filter (where x.keep and (x.is_open or not p_only_open)))[1])
    into v
    from (select y.*, y.in_h and (not p_only_open or y.is_open or (y.kind = 'filled' and y.created_at > p_at - interval '24 hours')) as keep
            from (select distinct on (m.offer_id) k.ord, m.id, m.offer_id, m.recipient_id, m.kind, m.created_at,
                         coalesce(o.window_starts_at, w.starts_at) as st,
                         booking.shift_offer_in_horizon(coalesce(o.window_starts_at, w.starts_at)) as in_h,
                         coalesce(m.kind in ('offer', 'reminder') and o.status in ('active', 'paused') and r.status = 'pending'
                                  and coalesce(o.window_starts_at, w.starts_at) > p_at, false) as is_open,
                         booking.shift_offer_cap_label(o.role_type) || ' ' || booking.shift_offer_when(coalesce(o.window_starts_at, w.starts_at), coalesce(o.window_ends_at, w.ends_at))
                         || case when m.kind = 'filled' then ' (jo mennyt)'
                                 when dl.at is not null then ' (vastaa viimeistään ' || to_char(dl.at at time zone 'Europe/Helsinki', 'DD.MM. HH24:MI') || ')'
                                 else '' end as line
                    from jsonb_array_elements_text(v_p -> 'merged_ids') with ordinality k(id, ord)
                    join public.shift_offer_messages m on m.id = k.id::bigint
                    join public.shift_offers o on o.id = m.offer_id
                    join public.work_shifts w on w.id = o.shift_id
                    left join public.shift_offer_recipients r on r.id = m.recipient_id
                    cross join lateral (select case when r.id is null then null
                                                    when m.kind in ('offer', 'reminder') and m.deadline_extended_at is null
                                                      then coalesce(booking.shift_offer_deadline_preview(r.id, p_at), r.deadline_at)
                                                    else r.deadline_at end as at) dl
                   order by m.offer_id, k.ord desc) y) x;
  return v;
end $function$;

CREATE OR REPLACE FUNCTION booking.shift_offer_digest_body(p_staff uuid, p_date date, p_items text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- digestfix: päiväkoosteen teksti, merkki merkiltä sama muoto kuin merge_same_day aiemmin (yksi linkki omalle sivulle).
declare v_name text; v_link text;
begin
  select split_part(btrim(st.name), ' ', 1) into v_name from public.staff st where st.id = p_staff;
  v_link := booking.shift_staff_page_url(p_staff);
  return 'Hei ' || coalesce(v_name, '') || E'.\nSinulle on useampi vuoroasia ' || coalesce(to_char(p_date, 'DD.MM.YYYY'), '') || ': ' || coalesce(p_items, '')
      || E'.\nVastaa omalla sivullasi: ' || coalesce(v_link, '(linkki puuttuu)') || E'\n\n–Tapio';
end $function$;

revoke all on function booking.shift_offer_digest_items(bigint,timestamptz,boolean) from public, anon, authenticated;
revoke all on function booking.shift_offer_digest_body(uuid,date,text) from public, anon, authenticated;
grant execute on function booking.shift_offer_digest_items(bigint,timestamptz,boolean) to service_role;
grant execute on function booking.shift_offer_digest_body(uuid,date,text) to service_role;

CREATE OR REPLACE FUNCTION booking.shift_offer_merge_same_day(p_now timestamp with time zone DEFAULT now())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- digestfix: #4 horisontti (fail-closed) ennen yhdistämistä; #1 koosteen rivit ja määräajat booking.shift_offer_digest_items:llä
-- (deadline_preview hetkellä p_now = sender_claimin now() = locked_at / email_outbox.created_at, eli näytetty = kirjattu);
-- jonossa olevat koosteet piirretään uudelleen joka ajolla.
declare g record; d record; v_body text; v_id bigint; v_it jsonb; v_n int := 0; v_first uuid;
begin
  p_now := coalesce(p_now, now());
  -- #4: horisontin ulkopuolella alkavan vuoron jonossa oleva tarjous/muistutus/jo mennyt → skipped 'horizon' (ei koosteeseen eikä yksittäin).
  -- Puuttuva/virheellinen horisonttiasetus → shift_offer_in_horizon false → kaikki ohitetaan (sama fail-closed kuin horisonttimigraatiossa).
  update public.shift_offer_messages m set status = 'skipped', last_error = 'horizon', locked_at = null
    from public.shift_offers o
    join public.work_shifts w on w.id = o.shift_id
   where o.id = m.offer_id and m.status = 'queued' and m.wamid is null
     and m.channel in ('whatsapp', 'email')
     and m.kind in ('offer', 'reminder', 'filled')
     and not public.shift_offer_is_bot_staff(m.staff_id)
     and not booking.shift_offer_in_horizon(coalesce(o.window_starts_at, w.starts_at));
  for g in
    select m.staff_id, (coalesce(o.window_starts_at, w.starts_at) at time zone 'Europe/Helsinki')::date as d,
           array_agg(m.id order by coalesce(o.window_starts_at, w.starts_at), m.id) as ids,
           array_agg(m.recipient_id order by m.id) filter (where m.recipient_id is not null) as recs
      from public.shift_offer_messages m
      join public.shift_offers o on o.id = m.offer_id
      join public.work_shifts w on w.id = o.shift_id
      left join booking.shift_offer_message_meta mm on mm.message_id = m.id
     where m.status = 'queued' and m.wamid is null and m.next_attempt_at <= p_now
       and m.channel in ('whatsapp','email')
       and m.kind in ('offer','reminder','filled')
       and coalesce(mm.subkind, '') <> 'day_digest'
       and not public.shift_offer_is_bot_staff(m.staff_id)
     group by m.staff_id, 2
    having count(distinct m.offer_id) > 1
  loop
    select m.offer_id into v_first from public.shift_offer_messages m where m.id = g.ids[1];
    -- teksti kirjoitetaan heti alla metan jälkeen (rivit luetaan metan merged_ids:stä)
    v_id := public.shift_offer_queue_message(v_first, null, g.staff_id, 'alert', '-',
              'b153:digest:' || g.staff_id::text || ':' || g.d::text || ':' || g.ids[1]::text);
    if v_id is null then continue; end if;
    insert into booking.shift_offer_message_meta (message_id, subkind, digest_key, payload)
    values (v_id, 'day_digest', g.staff_id::text || ':' || g.d::text,
            jsonb_build_object('merged_ids', to_jsonb(g.ids), 'recipient_ids', to_jsonb(coalesce(g.recs, '{}')), 'date', g.d,
                               'date_label', to_char(g.d, 'DD.MM.YYYY')))
    on conflict (message_id) do nothing;
    v_it := booking.shift_offer_digest_items(v_id, p_now, false);
    v_body := booking.shift_offer_digest_body(g.staff_id, g.d, v_it ->> 'items');
    update public.shift_offer_messages set body = v_body where id = v_id;
    update booking.shift_offer_message_meta set payload = payload || jsonb_build_object('items', v_it ->> 'items', 'rendered_at', p_now)
     where message_id = v_id;
    update public.shift_offer_messages set status = 'skipped', last_error = 'merged:' || v_id::text, locked_at = null
     where id = any (g.ids) and status = 'queued';
    v_n := v_n + 1;
  end loop;
  -- #1/#4: jonossa olevat (myös aiemmilla ajoilla tehdyt / uudelleenlähetetyt) koosteet piirretään hetkelle p_now;
  -- kaikki rivit horisontin ulkopuolella → skipped 'horizon'
  for d in
    select m.id, m.staff_id, mm.payload
      from public.shift_offer_messages m
      join booking.shift_offer_message_meta mm on mm.message_id = m.id and mm.subkind = 'day_digest'
     where m.status = 'queued' and m.wamid is null and m.next_attempt_at <= p_now
     order by m.id
     for update of m skip locked
  loop
    v_it := booking.shift_offer_digest_items(d.id, p_now, false);
    if v_it is null or coalesce((v_it ->> 'n_all')::int, 0) = 0 then continue; end if;
    if coalesce((v_it ->> 'n')::int, 0) = 0 then
      update public.shift_offer_messages set status = 'skipped', last_error = 'horizon', locked_at = null where id = d.id and status = 'queued';
      continue;
    end if;
    v_body := booking.shift_offer_digest_body(d.staff_id, (d.payload ->> 'date')::date, v_it ->> 'items');
    update public.shift_offer_messages set body = v_body where id = d.id and body is distinct from v_body;
    update booking.shift_offer_message_meta set payload = payload || jsonb_build_object('items', v_it ->> 'items', 'rendered_at', p_now)
     where message_id = d.id;
  end loop;
  return v_n;
end $function$;

CREATE OR REPLACE FUNCTION booking.shift_offer_deadline_on_sent(p_message bigint, p_at timestamp with time zone DEFAULT now())
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- soefix B2: määräajan jatko vain onnistuneesta lähetyksestä (WhatsApp wamid / email_outbox 'sent'), kerran per viesti
-- digestfix #1: päiväkooste (meta subkind 'day_digest') → jatketaan jokaisen yhdistetyn tarjous-/muistutusviestin vastaanottajaa
-- täsmälleen kuten yksittäinen lähetys (shift_offer_extend_deadline). Kerran per kooste (koosteen deadline_extended_at) ja
-- kerran per yhdistetty viesti (sen deadline_extended_at), joten uudelleenlähetetty kooste ei jatka toiseen kertaan.
declare v_r bigint; v_p jsonb; x record; v_one timestamptz; v_dl timestamptz;
begin
  select mm.payload into v_p from booking.shift_offer_message_meta mm where mm.message_id = p_message and mm.subkind = 'day_digest';
  if found then
    update public.shift_offer_messages set deadline_extended_at = now()
     where id = p_message and deadline_extended_at is null
    returning id into v_r;
    if v_r is null or jsonb_typeof(v_p -> 'merged_ids') is distinct from 'array' then return null; end if;
    for x in
      select m.id, m.recipient_id from public.shift_offer_messages m
       where m.id in (select e::bigint from jsonb_array_elements_text(v_p -> 'merged_ids') e)
         and m.recipient_id is not null and m.kind in ('offer','reminder') and m.deadline_extended_at is null
       order by m.id
       for update
    loop
      update public.shift_offer_messages set deadline_extended_at = now() where id = x.id and deadline_extended_at is null;
      if found then
        v_one := booking.shift_offer_extend_deadline(x.recipient_id, coalesce(p_at, now()));
        if v_one is not null and (v_dl is null or v_one > v_dl) then v_dl := v_one; end if;
      end if;
    end loop;
    return v_dl;
  end if;
  update public.shift_offer_messages set deadline_extended_at = now()
   where id = p_message and deadline_extended_at is null and recipient_id is not null and kind in ('offer','reminder')
  returning recipient_id into v_r;
  if v_r is null then return null; end if;
  return booking.shift_offer_extend_deadline(v_r, coalesce(p_at, now()));
end $function$;

CREATE OR REPLACE FUNCTION booking.shift_offer_resend_lost(p_now timestamp with time zone DEFAULT now())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- soefix B7/B8. Ajetaan sender_claimissa (vain kun sender_enabled). Idempotentti: dedupe_key 'resend:<id>' / 'b153:botcopy:<id>',
-- alkuperäiseen resent_message_id / bot_email_outbox_id. Enintään 1 uudelleenlähetys per alkuperäinen. Suljettuja ei lähetetä.
-- digestfix #2: päiväkooste (day_digest) päätetään kaikkien yhdistettyjen perusteella: lähetetään, jos yksikin on henkilölle yhä auki
-- (shift_offer_digest_items p_only_open); teksti, rivit, merged_ids ja recipient_ids rakennetaan uudelleen vain avoimista. Ei avoimia → ei lähetetä.
declare m record; v_id bigint; v_n int := 0; v_out bigint; v_email boolean := booking.shift_offer_cfg_bool('email_enabled', false);
        v_it jsonb; v_body text; v_offer uuid; v_payload jsonb;
begin
  p_now := coalesce(p_now, now());
  -- 1) unknown / failed (ei failed_no_contact) → kerran toista kanavaa pitkin, jos tarjous on yhä auki
  for m in
    select x.id, x.offer_id, x.recipient_id, x.staff_id, x.kind, x.channel, x.body, mm.subkind, mm.digest_key, mm.payload as meta_payload,
           st.email, st.phone_e164
      from public.shift_offer_messages x
      join public.staff st on st.id = x.staff_id and st.active
      join public.shift_offers o on o.id = x.offer_id
      join public.work_shifts w on w.id = o.shift_id
      left join public.shift_offer_recipients r on r.id = x.recipient_id
      left join booking.shift_offer_message_meta mm on mm.message_id = x.id
     where x.status in ('unknown', 'failed') and x.resent_message_id is null
       and x.kind in ('offer', 'reminder', 'filled', 'alert')
       and x.dedupe_key not like 'resend:%'
       and x.created_at > p_now - interval '7 days'
       and (w.starts_at > p_now or mm.subkind = 'day_digest')
       and not public.shift_offer_is_bot_staff(x.staff_id)
       and case when mm.subkind = 'day_digest' then coalesce((booking.shift_offer_digest_items(x.id, p_now, true) ->> 'n_open')::int, 0) > 0
                else case x.kind
             when 'offer' then o.status in ('active', 'paused') and r.status = 'pending'
             when 'reminder' then o.status in ('active', 'paused') and r.status = 'pending'
             when 'alert' then o.status in ('active', 'paused', 'escalated')
             else x.created_at > p_now - interval '24 hours'
           end end
       and ((x.channel = 'whatsapp' and v_email and booking._valid_email(btrim(coalesce(st.email, ''))))
            or (x.channel = 'email' and booking.shift_offer_wa_ready(x.staff_id, x.kind, mm.subkind)))
     order by x.id
     limit 50
     for update of x skip locked
  loop
    v_body := m.body; v_offer := m.offer_id; v_payload := coalesce(m.meta_payload, '{}'::jsonb);
    if m.subkind = 'day_digest' then
      v_it := booking.shift_offer_digest_items(m.id, p_now, true);
      if coalesce((v_it ->> 'n_open')::int, 0) = 0 then continue; end if;
      v_offer := coalesce((v_it ->> 'first_offer_id')::uuid, m.offer_id);
      v_body := booking.shift_offer_digest_body(m.staff_id, (m.meta_payload ->> 'date')::date, v_it ->> 'items');
      v_payload := v_payload || jsonb_build_object('merged_ids', v_it -> 'merged_ids', 'recipient_ids', v_it -> 'recipient_ids',
                                                   'items', v_it ->> 'items', 'rendered_at', p_now, 'resent_from', m.id);
    end if;
    insert into public.shift_offer_messages (offer_id, recipient_id, staff_id, kind, channel, to_address, body, dedupe_key)
    values (v_offer, m.recipient_id, m.staff_id, m.kind,
            case when m.channel = 'whatsapp' then 'email' else 'whatsapp' end,
            case when m.channel = 'whatsapp' then btrim(m.email) else public.shift_offer_phone_e164(m.phone_e164) end,
            v_body, 'resend:' || m.id::text)
    on conflict (dedupe_key) do nothing
    returning id into v_id;
    if v_id is null then select x.id into v_id from public.shift_offer_messages x where x.dedupe_key = 'resend:' || m.id::text; end if;
    if m.subkind is not null then
      insert into booking.shift_offer_message_meta (message_id, subkind, digest_key, payload)
      values (v_id, m.subkind, m.digest_key, v_payload)
      on conflict (message_id) do nothing;
    end if;
    update public.shift_offer_messages set resent_message_id = v_id where id = m.id and resent_message_id is null;
    v_n := v_n + 1;
  end loop;
  -- 2) bottikanava (Joonas / Otto): kuittaamaton (bot_acked_at tai botgw.inbox_ack) yli 2 h, vain 08–21 → sähköpostikopio kerran
  if v_email and booking.shift_offer_wa_open(p_now) then
    for m in
      select x.id, x.staff_id, x.kind, x.body, x.offer_id
        from public.shift_offer_messages x
        join public.staff st on st.id = x.staff_id and st.active
       where x.status = 'bot_channel' and x.bot_acked_at is null and x.bot_email_outbox_id is null
         and x.created_at < p_now - interval '2 hours' and x.created_at > p_now - interval '3 days'
         and booking._valid_email(btrim(coalesce(st.email, '')))
         and not exists (select 1 from botgw.inbox_ack a where a.message_id = x.id)
         and (x.offer_id is null or exists (select 1 from public.shift_offers o where o.id = x.offer_id and o.status in ('active', 'paused', 'escalated')))
         -- sama vaihe on jo mennyt sähköpostilla (vacant_notice.email_staff_ids) → ei toista
         and not exists (select 1 from booking.shift_offer_notices n1
                           join booking.shift_offer_notices n2 on n2.offer_id = n1.offer_id and n2.staff_id = n1.staff_id and n2.stage = n1.stage and n2.email_outbox_id is not null
                          where n1.message_id = x.id)
       order by x.id
       limit 50
       for update of x skip locked
    loop
      v_out := booking.shift_offer_email(m.staff_id,
                 case when m.kind = 'exhausted_ask' then 'Vuoro ilman tekijää' else 'Työvuoroilmoitus' end || ' (kuittaamaton) – Tapio',
                 m.body, 'botcopy:' || m.id::text);
      if v_out is null then select e.id into v_out from booking.email_outbox e where e.dedupe_key = 'b153:botcopy:' || m.id::text; end if;
      if v_out is not null then
        update public.shift_offer_messages set bot_email_outbox_id = v_out where id = m.id;
        v_n := v_n + 1;
      end if;
    end loop;
  end if;
  return v_n;
end $function$;

CREATE OR REPLACE FUNCTION booking.shift_offer_wa_ready(p_staff uuid, p_kind text, p_subkind text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- soefix C1: voiko viestin nyt lähettää WhatsAppilla (henkilö, moottori, allowlist, pohja). Kellonaikaa (08–21) ei katsota tässä.
-- Pohjasääntö = whatsapp.ts resolveTemplate: round_reminder → round_reminder-pohja; day_digest → day_digest-pohja (digestfix #3: kuten tarjous,
-- hyväksymätön → edge lähettää heti sähköpostilla myös yöllä); already_taken/vacant*/th_* → edge päättää;
-- muu offer/reminder → offer-pohja. Pohja kelpaa vain approved = true ja nimi [a-z0-9_]+.
declare st public.staff%rowtype; e public.shift_offer_engine_settings%rowtype; v_tpl jsonb; v_key text;
begin
  select * into st from public.staff s where s.id = p_staff;
  if not found or not st.active or not coalesce(st.whatsapp_enabled, false) or public.shift_offer_phone_e164(st.phone_e164) is null then return false; end if;
  if public.shift_offer_is_bot_staff(p_staff) then return false; end if;
  select * into e from public.shift_offer_engine_settings x where x.id;
  if not found or not coalesce(e.whatsapp_enabled, false) or not (p_staff = any (coalesce(e.whatsapp_allow_staff_ids, '{}'))) then return false; end if;
  if p_subkind = 'round_reminder' then v_key := 'round_reminder';
  elsif p_subkind = 'day_digest' then v_key := 'day_digest';
  elsif p_subkind = 'already_taken' or p_subkind ~ '^(vacant|th_)' then return true;
  elsif p_kind in ('offer', 'reminder') then v_key := 'offer';
  else return true;
  end if;
  v_tpl := booking.shift_offer_cfg('wa_templates') -> v_key;
  return coalesce(v_tpl ->> 'approved', '') = 'true' and coalesce(v_tpl ->> 'name', '') ~ '^[a-z0-9_]+$';
end $function$;

CREATE OR REPLACE FUNCTION booking.shift_offer_report_issues(p_since timestamp with time zone DEFAULT (now() - '1 day'::interval))
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  -- soefix B3/C2/B7 (+ digestfix: kooste = yhdistetyt tarjoukset): Työvuoro-Tapion päiväraportin koonti. Ei puhelinnumeroita, osoitteita eikä viestien sisältöä.
  select jsonb_build_object(
    'since', p_since,
    'offer_horizon_until', booking.shift_offer_horizon_until(),
    'no_rounds', coalesce((select jsonb_agg(jsonb_build_object('shift_id', k.shift_id, 'role_type', k.role_type, 'shift_date', k.shift_date,
                                                               'first_seen_at', k.first_seen_at, 'last_seen_at', k.last_seen_at)
                                            order by k.shift_date, k.role_type)
                             from booking.shift_offer_skips k join public.work_shifts w on w.id = k.shift_id
                            where k.reason = 'no_rounds' and k.last_seen_at >= p_since and w.starts_at > now()), '[]'::jsonb),
    'no_working_channel', coalesce((select jsonb_agg(jsonb_build_object('staff_id', q.staff_id, 'name', q.name, 'roles', q.roles, 'offers_skipped', q.n) order by q.name)
                                      -- digestfix: päiväkooste lasketaan jokaisena siihen yhdistettynä tarjouksena (meta.payload.merged_ids)
                                      from (select m.staff_id, st.name, count(distinct coalesce(f.offer_id::text, m.id::text)) n,
                                                   coalesce(jsonb_agg(distinct o.role_type) filter (where o.role_type is not null), '[]'::jsonb) roles
                                              from public.shift_offer_messages m
                                              left join booking.shift_offer_message_meta mm on mm.message_id = m.id and mm.subkind = 'day_digest'
                                                                                          and jsonb_typeof(mm.payload -> 'merged_ids') = 'array'
                                              cross join lateral (select m.offer_id
                                                                  union
                                                                  select x.offer_id from public.shift_offer_messages x
                                                                   where mm.message_id is not null
                                                                     and x.id in (select e::bigint from jsonb_array_elements_text(mm.payload -> 'merged_ids') e)) f
                                              left join public.staff st on st.id = m.staff_id
                                              left join public.shift_offers o on o.id = f.offer_id
                                             where m.status = 'failed_no_contact' and m.last_error like 'no_working_channel%' and m.created_at >= p_since
                                             group by m.staff_id, st.name) q), '[]'::jsonb),
    'skipped_inactive', (select count(*) from public.shift_offer_messages m where m.last_error = 'skipped_inactive' and m.created_at >= p_since),
    'lost_not_resent', (select count(*) from public.shift_offer_messages m where m.status in ('unknown', 'failed') and m.resent_message_id is null and m.created_at >= p_since),
    'resent', (select count(*) from public.shift_offer_messages m where m.dedupe_key like 'resend:%' and m.created_at >= p_since),
    'bot_unacked_over_2h', (select count(*) from public.shift_offer_messages m
                             where m.status = 'bot_channel' and m.bot_acked_at is null and m.created_at < now() - interval '2 hours' and m.created_at >= p_since
                               and not exists (select 1 from botgw.inbox_ack a where a.message_id = m.id)),
    'bot_email_copies', (select count(*) from public.shift_offer_messages m where m.bot_email_outbox_id is not null and m.created_at >= p_since))
$function$;

-- jälkitarkistus: uudet määrittelyt, oikeudet, kytkimet ennallaan
do $p$
declare v text; ok boolean := true; msg text := ''; s text;
begin
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_merge_same_day(timestamptz)')));
  if v is distinct from '6f02c362e1708e7ebd96db25d0b680c9' then ok := false; msg := msg || ' shift_offer_merge_same_day=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_deadline_on_sent(bigint,timestamptz)')));
  if v is distinct from '82529d71053b2ef6ca0a77e56443cde7' then ok := false; msg := msg || ' shift_offer_deadline_on_sent=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_resend_lost(timestamptz)')));
  if v is distinct from '97931068bf0322fd7d9afb8c453530e7' then ok := false; msg := msg || ' shift_offer_resend_lost=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_wa_ready(uuid,text,text)')));
  if v is distinct from '8f0532dce5b6a8ce00b7b61b323a9923' then ok := false; msg := msg || ' shift_offer_wa_ready=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_report_issues(timestamptz)')));
  if v is distinct from '6019cf1835e31ff11124b68a74407d76' then ok := false; msg := msg || ' shift_offer_report_issues=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_digest_items(bigint,timestamptz,boolean)')));
  if v is distinct from 'acb945537f8d9b01972aae746e7e27b9' then ok := false; msg := msg || ' shift_offer_digest_items=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_digest_body(uuid,date,text)')));
  if v is distinct from '86a8f7c5deae16b7b53e541f65824f1d' then ok := false; msg := msg || ' shift_offer_digest_body=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_sender_claim(integer)')));
  if v is distinct from 'd6a47aa43feb0445f0bf00d549b60905' then ok := false; msg := msg || ' shift_offer_sender_claim=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_sender_complete(jsonb)')));
  if v is distinct from 'c29ed4d23f8ede7d1ae2ef1c283f9e03' then ok := false; msg := msg || ' shift_offer_sender_complete=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_email_drain(integer)')));
  if v is distinct from '0d8df86310ad86b3a6f43429274478ed' then ok := false; msg := msg || ' shift_offer_email_drain=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_email_sent_trg()')));
  if v is distinct from '5eacac6985c8f8b2d0efc3e888994965' then ok := false; msg := msg || ' shift_offer_email_sent_trg=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_deadline_preview(bigint,timestamptz)')));
  if v is distinct from '0b48a1eab2bb8df1a5393ba9978dd40e' then ok := false; msg := msg || ' shift_offer_deadline_preview=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_extend_deadline(bigint,timestamptz)')));
  if v is distinct from '956adca5d836c2c8ea7d34c7ebb2d05c' then ok := false; msg := msg || ' shift_offer_extend_deadline=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_in_horizon(timestamptz)')));
  if v is distinct from 'd8b58a6e68c3a6c63d96c6d2e0efebad' then ok := false; msg := msg || ' shift_offer_in_horizon=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_horizon_until()')));
  if v is distinct from 'ef7f7227e66834d002ee200613f79bbd' then ok := false; msg := msg || ' shift_offer_horizon_until=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_queue_message(uuid,bigint,uuid,text,text,text)')));
  if v is distinct from '0982a948c9e5fbe882f094c269afe31c' then ok := false; msg := msg || ' shift_offer_queue_message=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_email(uuid,text,text,text,text)')));
  if v is distinct from 'f17b064c82f56f3221cc0ea3570114e1' then ok := false; msg := msg || ' shift_offer_email=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_staff_page_url(uuid)')));
  if v is distinct from '37f75772b49103d866817ef1bf9b38e8' then ok := false; msg := msg || ' shift_staff_page_url=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_cap_label(text)')));
  if v is distinct from '9c9c5d717c6fa8114591a948c11345e3' then ok := false; msg := msg || ' shift_offer_cap_label=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_when(timestamptz,timestamptz)')));
  if v is distinct from '2231f8a1e4337e43edea6f7c2078ce4a' then ok := false; msg := msg || ' shift_offer_when=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_is_bot_staff(uuid)')));
  if v is distinct from '5ec483f8c82b3f59fd89af264444333a' then ok := false; msg := msg || ' shift_offer_is_bot_staff=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_cfg(text)')));
  if v is distinct from 'a4c2bfd3bb435703a0d728a737606394' then ok := false; msg := msg || ' shift_offer_cfg=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_cfg_bool(text,boolean)')));
  if v is distinct from '0a030b5b3c7fd55594b9d9aea66373e6' then ok := false; msg := msg || ' shift_offer_cfg_bool=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._valid_email(text)')));
  if v is distinct from '6775eff3f255a0388b3da493a4d730be' then ok := false; msg := msg || ' _valid_email=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_phone_e164(text)')));
  if v is distinct from '2a3b0dd7494447d1e80a92ba6b9965bd' then ok := false; msg := msg || ' shift_offer_phone_e164=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_wa_open(timestamptz)')));
  if v is distinct from 'fb743be3b998339628748ba29cfae48d' then ok := false; msg := msg || ' shift_offer_wa_open=' || coalesce(v, 'puuttuu'); end if;
  foreach s in array array['booking.shift_offer_merge_same_day(timestamptz)', 'booking.shift_offer_deadline_on_sent(bigint,timestamptz)', 'booking.shift_offer_resend_lost(timestamptz)', 'booking.shift_offer_wa_ready(uuid,text,text)', 'booking.shift_offer_report_issues(timestamptz)', 'booking.shift_offer_digest_items(bigint,timestamptz,boolean)', 'booking.shift_offer_digest_body(uuid,date,text)', 'booking.shift_offer_digest_items(bigint,timestamptz,boolean)', 'booking.shift_offer_digest_body(uuid,date,text)'] loop
    if (select proacl::text from pg_proc where oid = to_regprocedure(s)) is distinct from '{postgres=X/postgres,service_role=X/postgres}' then
      ok := false; msg := msg || ' oikeudet:' || s;
    end if;
  end loop;
  if exists (select 1 from digestfix_flags_before b
              where b.eng is distinct from (select row_to_json(e)::jsonb - 'updated_at' from public.shift_offer_engine_settings e where e.id)
                 or b.roles is distinct from (select jsonb_object_agg(role_type, enabled) from public.shift_offer_settings)
                 or b.welcome is distinct from (select value from booking.settings where key = 'shift_offer.welcome_enabled')
                 or b.email is distinct from (select value from booking.settings where key = 'shift_offer.email_enabled')
                 or b.tpl is distinct from (select value from booking.settings where key = 'shift_offer.wa_templates')) then
    ok := false; msg := msg || ' moottorin kytkimet muuttuivat';
  end if;
  if coalesce((select sender_enabled from public.shift_offer_engine_settings where id), false) then ok := false; msg := msg || ' sender_enabled'; end if;
  if not ok then raise exception 'digestfix: jälkitarkistus epäonnistui:%', msg; end if;
end $p$;
