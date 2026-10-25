-- soefix (20261025153700 = tuotannon versio, Bottiavustus ajoi 25.10.2026): vuorotarjousmoottorin korjaukset
-- (/workspace/soe_review/koodari_fixes.md: B2, B4, C1, C2, B3, B7+B8, B9, T1 osin). EI B6:ta (Joonas 25.10. 16:59: alkuperäiset aikataulut;
-- hoitajavuoron 6 h lasketaan edelleen varoituksen luonnista). EI bot-gateway-edgeä. Moottori pysyy POIS: tämä ei koske
-- shift_offer_engine_settings-lippuihin (sender_enabled, whatsapp_enabled, whatsapp_dry_run, whatsapp_allow_staff_ids, dry_run,
-- whatsapp_inbound_enabled), shift_offer_settings.enabled-arvoihin eikä shift_offer.welcome_enabled-asetukseen (tarkistetaan lopussa).
--   B2  claim ja email_drain eivät enää jatka määräaikaa. Jatko vain onnistuneesta lähetyksestä, kerran per viesti
--       (shift_offer_messages.deadline_extended_at): sender_complete action='sent' (wamid) claimin hetkellä (locked_at = viestissä näytetty
--       aika, booking.shift_offer_deadline_preview) ja sähköposti vasta, kun booking.email_outbox-rivi siirtyy tilaan 'sent' (trigger
--       shift_offer_email_sent, aika = outbox-rivin luontihetki). skipped / failed / release / fail eivät jatka.
--       HUOM: onnistunut lähetys jatkaa yhä nykyisen kierroksen next_action_at:ia kuten ennenkin (booking.shift_offer_extend_deadline
--       ennallaan); uutta viivettä ei tule, lähettämättömien viive poistuu. Ks. PR (B2-liputus).
--   B4/C1 hyväksymätön pohja, henkilön/moottorin WhatsApp pois, ei allowlistillä → edge siirtää sähköpostiin heti (ei 360 min), muuten
--       failed_no_contact 'no_working_channel'. Claim poimii myös WhatsApp-rivit, joille WhatsApp ei nyt kelpaa (booking.shift_offer_wa_ready).
--       wa_templates.offer.fallback ('vuorotarjous') poistetaan asetuksesta.
--   C2  queue_message: ei toimivaa kanavaa → status failed_no_contact, last_error no_working_channel (sähköposti booking._valid_email).
--   B3  ensure: ei kierroksia roolille + viikonpäivälle (ei therapist) → skip 'no_rounds', kirjataan booking.shift_offer_skips;
--       raportti booking.shift_offer_report_issues(p_since).
--   B7/B8 booking.shift_offer_resend_lost (claimissa, vain sender_enabled): unknown/failed offer/reminder/filled/alert → kerran toista kanavaa
--       (dedupe 'resend:<id>', resent_message_id); bot_channel kuittaamaton > 2 h (08–21) → sähköpostikopio (bot_email_outbox_id).
--       Kuittaus: public.shift_offer_bot_ack(ids) (Bottiavustus) tai botgw.inbox_ack (Otto). botgw-funktioihin ei kosketa.
--   B9  booking.shift_staff_welcome ei aseta welcome_sent_at:ia; varaus welcome_claimed_at (10 min). welcome_sent_at vasta
--       booking.shift_staff_welcome_mark_sent(staff, wamid); epäonnistunut → booking.shift_staff_welcome_release(staff).
--   T1  parse_shift_title täsmää vain aktiiviseen henkilöön; queue_message / claim / email_drain / shift_offer_email eivät lähetä
--       deaktivoidulle (status skipped, last_error skipped_inactive).
--   Tervetuloteksti: booking.site_texts 'shift_offer.whatsapp.welcome' (fi) → Joonaksen hyväksymä teksti sellaisenaan ({nimi}/{linkki} =
--       {{var:name}}/{{var:link}}), uusi versio, max_len 280 → 600. welcome_enabled pysyy false.
--   muutetut funktiot (tuotanto sxbofnuisemspgquoxyv ennen, luettu SELECTillä 25.10.2026 -> tämän jälkeen):
--     public.shift_offer_sender_claim(integer): ddec4116885b70df02f4a1157440c2b3 -> d6a47aa43feb0445f0bf00d549b60905
--     public.shift_offer_sender_complete(jsonb): ce3424851a62060686be6f72926c4fb6 -> c29ed4d23f8ede7d1ae2ef1c283f9e03
--     booking.shift_offer_email_drain(integer): 2aeb4adbd0e247f1880d1451d7c09501 -> 0d8df86310ad86b3a6f43429274478ed
--     booking.shift_offer_email(uuid,text,text,text,text): 04e72c0cc48dde09eedab67aeaae8639 -> f17b064c82f56f3221cc0ea3570114e1
--     public.shift_offer_queue_message(uuid,bigint,uuid,text,text,text): 8705686f1c19fb67b5c15a702719de9d -> 0982a948c9e5fbe882f094c269afe31c
--     public.shift_offer_ensure(uuid,timestamptz,boolean): c11363b4820dded38d99e2424af9a5e5 -> c5d3d5a5d4048fcd4d525f5daa045893
--     booking.shift_staff_welcome(uuid): e615d22aea9ff2a7e822f53b2ffd179d -> c20b901d3e21cb27814a7c2b160af97e
--     public.parse_shift_title(text): c74e01c1ac62eaca941cd0fabfaa33c0 -> a894b3c7f749ca2cca559198ba92a42b
--   riippuvuudet, ei muuteta (tuotanto = vaadittu):
--     booking.shift_offer_extend_deadline(bigint,timestamptz) 956adca5d836c2c8ea7d34c7ebb2d05c
--     public.shift_offer_round_deadline(text,timestamptz,timestamptz,text,boolean) 6a9052240fbbf5f6bb4381e5384d80cc
--     booking.shift_offer_wa_open(timestamptz) fb743be3b998339628748ba29cfae48d
--     public.shift_offer_is_bot_staff(uuid) 5ec483f8c82b3f59fd89af264444333a
--     public.shift_offer_phone_e164(text) 2a3b0dd7494447d1e80a92ba6b9965bd
--     booking.shift_offer_merge_same_day(timestamptz) 963eba4f116ca88cb7ab766533f5d05d
--     booking.shift_offer_cfg(text) a4c2bfd3bb435703a0d728a737606394
--     booking.shift_offer_cfg_bool(text,boolean) 0a030b5b3c7fd55594b9d9aea66373e6
--     booking.shift_staff_page_url(uuid) 37f75772b49103d866817ef1bf9b38e8
--     booking.shift_staff_page_token(uuid,boolean) 81c4a8a9129553829874971d664d779c
--     public.shift_offer_sign_token(uuid,uuid,timestamptz) d16379e1b26afcfc0098d477401c0292
--     booking.shift_offer_notice(uuid,uuid,text,text,text,text,text,bigint,jsonb) b68606756fc2261292815d0ea4895121
--     booking.shift_offer_vacant_step(uuid,timestamptz,boolean) 33044714104d9460810969a89c7b528f
--     booking.shift_offer_therapist_step(uuid,timestamptz,boolean) c4298626269ec1146266417e93c6a9f0
--     public.shift_offer_on_exhausted(uuid,timestamptz,boolean) d0db0da4d3749e4f29f833827ed8d4bf
--     public.shift_offer_issue_recipients(uuid,text,timestamptz,timestamptz,timestamptz,integer,text,uuid[],text[],integer[]) 2d021e247de4102d41348e77d2fbb125
--     public.shift_offer_whatsapp_apply_status(text,text,text,timestamptz) 99ae85848a5a7caf9702468378241d84
--     public.shift_offer_sender_drain(integer) a0286c45f0644f29881e8ed638b6f6e4
--     booking._shift_offer_already_taken_mail() 6250e5fbdb4d8fb8b5f56efea2bbb12c
--     booking._valid_email(text) 6775eff3f255a0388b3da493a4d730be
--     booking._text_validate(text,text,integer,text[],text) 18cbb97a8e4d9a47fa23b4577a1c1b4d
--     booking._text_escalation(text,text) 1a72cee321b7f4d5a401b1ab7188460b
--     booking._text_refresh(bigint) 317efca841789dccd7933e831b164e29
--   uudet funktiot:
--     booking.shift_offer_deadline_preview(bigint,timestamptz) 0b48a1eab2bb8df1a5393ba9978dd40e
--     booking.shift_offer_deadline_on_sent(bigint,timestamptz) 103efa77f733a3c5d42bac53d49a4b4e
--     booking.shift_offer_email_sent_trg() 5eacac6985c8f8b2d0efc3e888994965
--     booking.shift_offer_wa_ready(uuid,text,text) d7148175ce2c9768ca8b807571f5fb72
--     booking.shift_offer_resend_lost(timestamptz) f73ac1325a2228d61fffe4ae42ca193d
--     public.shift_offer_bot_ack(bigint[]) 7357790f5d1eae7bb1fd50bcd7fe91e1
--     booking.shift_staff_welcome_mark_sent(uuid,text) 5a5bdaa5020efbc5b7a5f54587fd41b4
--     booking.shift_staff_welcome_release(uuid) 836d7590612932497a3571875d8a5ea8
--     booking.shift_offer_report_issues(timestamptz) edc1f3bda7fcd6c40e7ed9767a0c895a
-- Rollback: rollbacks/20261025153700_soefix_engine_fixes_ROLLBACK.sql. Testi: tests/vuorotarjous/tsoefix_engine_fixes.sql (BEGIN … ROLLBACK).
-- Ajojärjestys: (moottori pois) tämä migraatio -> shift-offer-engine deploy (sama PR) -> moottori pysyy pois, kunnes Joonas päättää.
set local lock_timeout = '5s';

do $g$
declare v text; ok boolean := true; msg text := '';
begin
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_sender_claim(integer)')));
  if v is null or v <> 'ddec4116885b70df02f4a1157440c2b3' then ok := false; msg := msg || ' shift_offer_sender_claim=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_sender_complete(jsonb)')));
  if v is null or v <> 'ce3424851a62060686be6f72926c4fb6' then ok := false; msg := msg || ' shift_offer_sender_complete=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_email_drain(integer)')));
  if v is null or v <> '2aeb4adbd0e247f1880d1451d7c09501' then ok := false; msg := msg || ' shift_offer_email_drain=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_email(uuid,text,text,text,text)')));
  if v is null or v <> '04e72c0cc48dde09eedab67aeaae8639' then ok := false; msg := msg || ' shift_offer_email=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_queue_message(uuid,bigint,uuid,text,text,text)')));
  if v is null or v <> '8705686f1c19fb67b5c15a702719de9d' then ok := false; msg := msg || ' shift_offer_queue_message=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_ensure(uuid,timestamptz,boolean)')));
  if v is null or v <> 'c11363b4820dded38d99e2424af9a5e5' then ok := false; msg := msg || ' shift_offer_ensure=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_staff_welcome(uuid)')));
  if v is null or v <> 'e615d22aea9ff2a7e822f53b2ffd179d' then ok := false; msg := msg || ' shift_staff_welcome=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.parse_shift_title(text)')));
  if v is null or v <> 'c74e01c1ac62eaca941cd0fabfaa33c0' then ok := false; msg := msg || ' parse_shift_title=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_extend_deadline(bigint,timestamptz)')));
  if v is null or v <> '956adca5d836c2c8ea7d34c7ebb2d05c' then ok := false; msg := msg || ' shift_offer_extend_deadline=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_round_deadline(text,timestamptz,timestamptz,text,boolean)')));
  if v is null or v <> '6a9052240fbbf5f6bb4381e5384d80cc' then ok := false; msg := msg || ' shift_offer_round_deadline=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_wa_open(timestamptz)')));
  if v is null or v <> 'fb743be3b998339628748ba29cfae48d' then ok := false; msg := msg || ' shift_offer_wa_open=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_is_bot_staff(uuid)')));
  if v is null or v <> '5ec483f8c82b3f59fd89af264444333a' then ok := false; msg := msg || ' shift_offer_is_bot_staff=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_phone_e164(text)')));
  if v is null or v <> '2a3b0dd7494447d1e80a92ba6b9965bd' then ok := false; msg := msg || ' shift_offer_phone_e164=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_merge_same_day(timestamptz)')));
  if v is null or v <> '963eba4f116ca88cb7ab766533f5d05d' then ok := false; msg := msg || ' shift_offer_merge_same_day=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_cfg(text)')));
  if v is null or v <> 'a4c2bfd3bb435703a0d728a737606394' then ok := false; msg := msg || ' shift_offer_cfg=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_cfg_bool(text,boolean)')));
  if v is null or v <> '0a030b5b3c7fd55594b9d9aea66373e6' then ok := false; msg := msg || ' shift_offer_cfg_bool=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_staff_page_url(uuid)')));
  if v is null or v <> '37f75772b49103d866817ef1bf9b38e8' then ok := false; msg := msg || ' shift_staff_page_url=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_staff_page_token(uuid,boolean)')));
  if v is null or v <> '81c4a8a9129553829874971d664d779c' then ok := false; msg := msg || ' shift_staff_page_token=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_sign_token(uuid,uuid,timestamptz)')));
  if v is null or v <> 'd16379e1b26afcfc0098d477401c0292' then ok := false; msg := msg || ' shift_offer_sign_token=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_notice(uuid,uuid,text,text,text,text,text,bigint,jsonb)')));
  if v is null or v <> 'b68606756fc2261292815d0ea4895121' then ok := false; msg := msg || ' shift_offer_notice=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_vacant_step(uuid,timestamptz,boolean)')));
  if v is null or v <> '33044714104d9460810969a89c7b528f' then ok := false; msg := msg || ' shift_offer_vacant_step=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_therapist_step(uuid,timestamptz,boolean)')));
  if v is null or v <> 'c4298626269ec1146266417e93c6a9f0' then ok := false; msg := msg || ' shift_offer_therapist_step=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_on_exhausted(uuid,timestamptz,boolean)')));
  if v is null or v <> 'd0db0da4d3749e4f29f833827ed8d4bf' then ok := false; msg := msg || ' shift_offer_on_exhausted=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_issue_recipients(uuid,text,timestamptz,timestamptz,timestamptz,integer,text,uuid[],text[],integer[])')));
  if v is null or v <> '2d021e247de4102d41348e77d2fbb125' then ok := false; msg := msg || ' shift_offer_issue_recipients=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_whatsapp_apply_status(text,text,text,timestamptz)')));
  if v is null or v <> '99ae85848a5a7caf9702468378241d84' then ok := false; msg := msg || ' shift_offer_whatsapp_apply_status=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_sender_drain(integer)')));
  if v is null or v <> 'a0286c45f0644f29881e8ed638b6f6e4' then ok := false; msg := msg || ' shift_offer_sender_drain=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._shift_offer_already_taken_mail()')));
  if v is null or v <> '6250e5fbdb4d8fb8b5f56efea2bbb12c' then ok := false; msg := msg || ' _shift_offer_already_taken_mail=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._valid_email(text)')));
  if v is null or v <> '6775eff3f255a0388b3da493a4d730be' then ok := false; msg := msg || ' _valid_email=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._text_validate(text,text,integer,text[],text)')));
  if v is null or v <> '18cbb97a8e4d9a47fa23b4577a1c1b4d' then ok := false; msg := msg || ' _text_validate=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._text_escalation(text,text)')));
  if v is null or v <> '1a72cee321b7f4d5a401b1ab7188460b' then ok := false; msg := msg || ' _text_escalation=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._text_refresh(bigint)')));
  if v is null or v <> '317efca841789dccd7933e831b164e29' then ok := false; msg := msg || ' _text_refresh=' || coalesce(v, 'puuttuu'); end if;
  foreach v in array array['public.shift_offer_sender_claim(integer)', 'public.shift_offer_sender_complete(jsonb)', 'booking.shift_offer_email_drain(integer)', 'booking.shift_offer_email(uuid,text,text,text,text)', 'public.shift_offer_queue_message(uuid,bigint,uuid,text,text,text)', 'public.shift_offer_ensure(uuid,timestamptz,boolean)', 'booking.shift_staff_welcome(uuid)', 'public.parse_shift_title(text)'] loop
    if (select proacl::text from pg_proc where oid = to_regprocedure(v)) is distinct from '{postgres=X/postgres,service_role=X/postgres}' then
      ok := false; msg := msg || ' oikeudet poikkeavat:' || v;
    end if;
  end loop;
  if to_regclass('botgw.inbox_ack') is null then ok := false; msg := msg || ' botgw.inbox_ack puuttuu (20261025145539)'; end if;
  if to_regclass('booking.shift_offer_skips') is not null then ok := false; msg := msg || ' booking.shift_offer_skips on jo olemassa'; end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'shift_offer_messages'
              and column_name in ('deadline_extended_at', 'bot_acked_at', 'resent_message_id', 'bot_email_outbox_id')) then
    ok := false; msg := msg || ' shift_offer_messages: uusi sarake on jo olemassa';
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'booking' and table_name = 'shift_staff_whatsapp_consent'
              and column_name in ('welcome_claimed_at', 'welcome_wamid')) then
    ok := false; msg := msg || ' shift_staff_whatsapp_consent: uusi sarake on jo olemassa';
  end if;
  if to_regprocedure('booking.shift_offer_deadline_preview(bigint,timestamptz)') is not null then ok := false; msg := msg || ' shift_offer_deadline_preview on jo olemassa'; end if;
  if to_regprocedure('booking.shift_offer_deadline_on_sent(bigint,timestamptz)') is not null then ok := false; msg := msg || ' shift_offer_deadline_on_sent on jo olemassa'; end if;
  if to_regprocedure('booking.shift_offer_email_sent_trg()') is not null then ok := false; msg := msg || ' shift_offer_email_sent_trg on jo olemassa'; end if;
  if to_regprocedure('booking.shift_offer_wa_ready(uuid,text,text)') is not null then ok := false; msg := msg || ' shift_offer_wa_ready on jo olemassa'; end if;
  if to_regprocedure('booking.shift_offer_resend_lost(timestamptz)') is not null then ok := false; msg := msg || ' shift_offer_resend_lost on jo olemassa'; end if;
  if to_regprocedure('public.shift_offer_bot_ack(bigint[])') is not null then ok := false; msg := msg || ' shift_offer_bot_ack on jo olemassa'; end if;
  if to_regprocedure('booking.shift_staff_welcome_mark_sent(uuid,text)') is not null then ok := false; msg := msg || ' shift_staff_welcome_mark_sent on jo olemassa'; end if;
  if to_regprocedure('booking.shift_staff_welcome_release(uuid)') is not null then ok := false; msg := msg || ' shift_staff_welcome_release on jo olemassa'; end if;
  if to_regprocedure('booking.shift_offer_report_issues(timestamptz)') is not null then ok := false; msg := msg || ' shift_offer_report_issues on jo olemassa'; end if;
  if (select value from booking.settings where key = 'shift_offer.wa_templates') is distinct from '{"offer": {"name": "tyovuoro_kysely", "approved": false, "fallback": "vuorotarjous"}, "day_digest": {"name": "tyovuoro_paivan_kooste", "approved": false}, "already_taken": {"name": "tyovuoro_jo_mennyt", "approved": false}, "round_reminder": {"name": "tyovuoro_muistutus", "approved": false}}'::jsonb then
    ok := false; msg := msg || ' shift_offer.wa_templates poikkeaa';
  end if;
  if (select md5(published_text) || ':' || published_version || ':' || latest_version || ':' || max_len from booking.site_texts
       where key = 'shift_offer.whatsapp.welcome' and lang = 'fi') is distinct from '51ae254f911b802cb2d969640d73201b:1:1:280' then
    ok := false; msg := msg || ' site_texts shift_offer.whatsapp.welcome (fi) poikkeaa';
  end if;
  if not ok then raise exception 'soefix: tuotannon määrittelyt eivät vastaa odotettua:%. Ei muutoksia.', msg; end if;
end $g$;

-- moottorin kytkimet ennen (verrataan lopussa)
create temp table soefix_flags_before on commit drop as
  select (select row_to_json(e)::jsonb - 'updated_at' from public.shift_offer_engine_settings e where e.id) as eng,
         (select jsonb_object_agg(role_type, enabled) from public.shift_offer_settings) as roles,
         (select value from booking.settings where key = 'shift_offer.welcome_enabled') as welcome,
         (select value from booking.settings where key = 'shift_offer.email_enabled') as email;

alter table public.shift_offer_messages
  add column deadline_extended_at timestamptz,
  add column bot_acked_at timestamptz,
  add column resent_message_id bigint references public.shift_offer_messages(id) on delete set null,
  add column bot_email_outbox_id bigint;
comment on column public.shift_offer_messages.deadline_extended_at is 'soefix B2: määräaika jatkettu tämän viestin onnistuneesta lähetyksestä (kerran).';
comment on column public.shift_offer_messages.bot_acked_at is 'soefix B7: bot_channel-rivi kuitattu (public.shift_offer_bot_ack). Oton botti: botgw.inbox_ack.';
comment on column public.shift_offer_messages.resent_message_id is 'soefix B7/B8: uudelleenlähetys toista kanavaa pitkin (dedupe resend:<id>), enintään 1.';
comment on column public.shift_offer_messages.bot_email_outbox_id is 'soefix B7: kuittaamattoman bot_channel-rivin sähköpostikopio (booking.email_outbox.id).';
create index shift_offer_messages_lost_idx on public.shift_offer_messages (id)
  where status in ('unknown', 'failed', 'bot_channel') and resent_message_id is null;

alter table booking.shift_staff_whatsapp_consent
  add column welcome_claimed_at timestamptz,
  add column welcome_wamid text;
comment on column booking.shift_staff_whatsapp_consent.welcome_claimed_at is 'soefix B9: tervetuloviestin lähetysvaraus (vanhenee 10 min).';

create table booking.shift_offer_skips (
  shift_id uuid not null references public.work_shifts(id) on delete cascade,
  reason text not null check (reason in ('no_rounds')),
  role_type text,
  shift_date date,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  seen_count integer not null default 1,
  primary key (shift_id, reason)
);
comment on table booking.shift_offer_skips is 'soefix B3: vuorot, joita moottori ei käsittele (no_rounds = ei kierroksia roolille + viikonpäivälle). Raportti: booking.shift_offer_report_issues.';
alter table booking.shift_offer_skips enable row level security;
revoke all on booking.shift_offer_skips from public, anon, authenticated;
grant select, insert, update, delete on booking.shift_offer_skips to service_role;

CREATE OR REPLACE FUNCTION booking.shift_offer_deadline_preview(p_recipient bigint, p_at timestamp with time zone DEFAULT now())
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- soefix B2: sama laskenta kuin booking.shift_offer_extend_deadline, mutta ei kirjoita mitään (claimin näyttämä määräaika)
declare r public.shift_offer_recipients%rowtype; o public.shift_offers%rowtype; w public.work_shifts%rowtype;
        v_max int; v_last boolean; v_dl timestamptz; v_date date; v_starts timestamptz;
begin
  select * into r from public.shift_offer_recipients x where x.id = p_recipient;
  if not found or r.status <> 'pending' or r.round_no >= 100 or r.deadline_at is null then return null; end if;
  select * into o from public.shift_offers x where x.id = r.offer_id;
  if o.status not in ('active','paused') then return r.deadline_at; end if;
  select * into w from public.work_shifts x where x.id = o.shift_id;
  v_starts := coalesce(o.window_starts_at, w.starts_at);
  v_date := (v_starts at time zone 'Europe/Helsinki')::date;
  select max(rnd.round_no) into v_max from public.shift_offer_rounds rnd
   where rnd.role_type = o.role_type and rnd.scenario = o.scenario and extract(isodow from v_date)::smallint = any (rnd.weekdays)
     and v_date >= rnd.valid_from and (rnd.valid_to is null or v_date <= rnd.valid_to);
  v_last := r.round_kind = 'all' or r.round_no >= coalesce(v_max, r.round_no);
  v_dl := public.shift_offer_round_deadline(o.role_type, v_starts, coalesce(p_at, now()), r.round_kind, v_last);
  if v_dl is null or v_dl <= r.deadline_at then return r.deadline_at; end if;
  return v_dl;
end $function$;

CREATE OR REPLACE FUNCTION booking.shift_offer_deadline_on_sent(p_message bigint, p_at timestamp with time zone DEFAULT now())
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- soefix B2: määräajan jatko vain onnistuneesta lähetyksestä (WhatsApp wamid / email_outbox 'sent'), kerran per viesti
declare v_r bigint;
begin
  update public.shift_offer_messages set deadline_extended_at = now()
   where id = p_message and deadline_extended_at is null and recipient_id is not null and kind in ('offer','reminder')
  returning recipient_id into v_r;
  if v_r is null then return null; end if;
  return booking.shift_offer_extend_deadline(v_r, coalesce(p_at, now()));
end $function$;

CREATE OR REPLACE FUNCTION booking.shift_offer_email_sent_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- soefix B2: vuoroviestin sähköposti lähti (Resend-id saatu) → määräaika jatkuu kerran. Ei koskaan kaada sähköpostin kuittausta.
begin
  if new.kind = 'staff_shift_notice' and new.dedupe_key ~ '^b153:msg:[0-9]{1,18}$' then
    begin
      perform booking.shift_offer_deadline_on_sent(substring(new.dedupe_key from 10)::bigint, coalesce(new.created_at, now()));
    exception when others then
      raise warning 'soefix: shift_offer_deadline_on_sent epäonnistui (email_outbox %, %)', new.id, sqlstate;
    end;
  end if;
  return null;
end $function$;

CREATE OR REPLACE FUNCTION booking.shift_offer_wa_ready(p_staff uuid, p_kind text, p_subkind text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- soefix C1: voiko viestin nyt lähettää WhatsAppilla (henkilö, moottori, allowlist, pohja). Kellonaikaa (08–21) ei katsota tässä.
-- Pohjasääntö = whatsapp.ts resolveTemplate: round_reminder → round_reminder-pohja; already_taken/day_digest/vacant*/th_* → edge päättää;
-- muu offer/reminder → offer-pohja. Pohja kelpaa vain approved = true ja nimi [a-z0-9_]+.
declare st public.staff%rowtype; e public.shift_offer_engine_settings%rowtype; v_tpl jsonb; v_key text;
begin
  select * into st from public.staff s where s.id = p_staff;
  if not found or not st.active or not coalesce(st.whatsapp_enabled, false) or public.shift_offer_phone_e164(st.phone_e164) is null then return false; end if;
  if public.shift_offer_is_bot_staff(p_staff) then return false; end if;
  select * into e from public.shift_offer_engine_settings x where x.id;
  if not found or not coalesce(e.whatsapp_enabled, false) or not (p_staff = any (coalesce(e.whatsapp_allow_staff_ids, '{}'))) then return false; end if;
  if p_subkind = 'round_reminder' then v_key := 'round_reminder';
  elsif p_subkind in ('already_taken', 'day_digest') or p_subkind ~ '^(vacant|th_)' then return true;
  elsif p_kind in ('offer', 'reminder') then v_key := 'offer';
  else return true;
  end if;
  v_tpl := booking.shift_offer_cfg('wa_templates') -> v_key;
  return coalesce(v_tpl ->> 'approved', '') = 'true' and coalesce(v_tpl ->> 'name', '') ~ '^[a-z0-9_]+$';
end $function$;

CREATE OR REPLACE FUNCTION booking.shift_offer_resend_lost(p_now timestamp with time zone DEFAULT now())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- soefix B7/B8. Ajetaan sender_claimissa (vain kun sender_enabled). Idempotentti: dedupe_key 'resend:<id>' / 'b153:botcopy:<id>',
-- alkuperäiseen resent_message_id / bot_email_outbox_id. Enintään 1 uudelleenlähetys per alkuperäinen. Suljettuja ei lähetetä.
declare m record; v_id bigint; v_n int := 0; v_out bigint; v_email boolean := booking.shift_offer_cfg_bool('email_enabled', false);
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
       and w.starts_at > p_now
       and not public.shift_offer_is_bot_staff(x.staff_id)
       and case x.kind
             when 'offer' then o.status in ('active', 'paused') and r.status = 'pending'
             when 'reminder' then o.status in ('active', 'paused') and r.status = 'pending'
             when 'alert' then o.status in ('active', 'paused', 'escalated')
             else x.created_at > p_now - interval '24 hours'
           end
       and ((x.channel = 'whatsapp' and v_email and booking._valid_email(btrim(coalesce(st.email, ''))))
            or (x.channel = 'email' and booking.shift_offer_wa_ready(x.staff_id, x.kind, mm.subkind)))
     order by x.id
     limit 50
     for update of x skip locked
  loop
    insert into public.shift_offer_messages (offer_id, recipient_id, staff_id, kind, channel, to_address, body, dedupe_key)
    values (m.offer_id, m.recipient_id, m.staff_id, m.kind,
            case when m.channel = 'whatsapp' then 'email' else 'whatsapp' end,
            case when m.channel = 'whatsapp' then btrim(m.email) else public.shift_offer_phone_e164(m.phone_e164) end,
            m.body, 'resend:' || m.id::text)
    on conflict (dedupe_key) do nothing
    returning id into v_id;
    if v_id is null then select x.id into v_id from public.shift_offer_messages x where x.dedupe_key = 'resend:' || m.id::text; end if;
    if m.subkind is not null then
      insert into booking.shift_offer_message_meta (message_id, subkind, digest_key, payload)
      values (v_id, m.subkind, m.digest_key, coalesce(m.meta_payload, '{}'::jsonb))
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

CREATE OR REPLACE FUNCTION public.shift_offer_bot_ack(p_ids bigint[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- soefix B7: Bottiavustuksen (Joonas) kuittaus luetuille bot_channel-riveille. Oton botti kuittaa botgw.inbox_ackilla.
declare n int;
begin
  if p_ids is null or cardinality(p_ids) = 0 then return 0; end if;
  if cardinality(p_ids) > 500 then raise exception 'shift_offer_bot_ack: enintään 500 id:tä' using errcode = '22023'; end if;
  update public.shift_offer_messages set bot_acked_at = now()
   where id = any (p_ids) and status = 'bot_channel' and bot_acked_at is null;
  get diagnostics n = row_count;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION booking.shift_staff_welcome_mark_sent(p_staff uuid, p_wamid text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- soefix B9: welcome_sent_at vasta, kun Meta palautti wamidin
begin
  if p_staff is null or nullif(btrim(coalesce(p_wamid, '')), '') is null then return false; end if;
  update booking.shift_staff_whatsapp_consent
     set welcome_sent_at = now(), welcome_wamid = left(btrim(p_wamid), 200), welcome_claimed_at = null
   where staff_id = p_staff and welcome_sent_at is null;
  return found;
end $function$;

CREATE OR REPLACE FUNCTION booking.shift_staff_welcome_release(p_staff uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- soefix B9: lähetys epäonnistui → varaus pois, jotta Metan uudelleentoimitus voi yrittää uudelleen (24 h ikkunassa)
begin
  update booking.shift_staff_whatsapp_consent set welcome_claimed_at = null
   where staff_id = p_staff and welcome_sent_at is null and welcome_claimed_at is not null;
  return found;
end $function$;

CREATE OR REPLACE FUNCTION booking.shift_offer_report_issues(p_since timestamp with time zone DEFAULT (now() - '1 day'::interval))
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  -- soefix B3/C2/B7: Työvuoro-Tapion päiväraportin koonti. Ei puhelinnumeroita, osoitteita eikä viestien sisältöä.
  select jsonb_build_object(
    'since', p_since,
    'no_rounds', coalesce((select jsonb_agg(jsonb_build_object('shift_id', k.shift_id, 'role_type', k.role_type, 'shift_date', k.shift_date,
                                                               'first_seen_at', k.first_seen_at, 'last_seen_at', k.last_seen_at)
                                            order by k.shift_date, k.role_type)
                             from booking.shift_offer_skips k join public.work_shifts w on w.id = k.shift_id
                            where k.reason = 'no_rounds' and k.last_seen_at >= p_since and w.starts_at > now()), '[]'::jsonb),
    'no_working_channel', coalesce((select jsonb_agg(jsonb_build_object('staff_id', q.staff_id, 'name', q.name, 'roles', q.roles, 'offers_skipped', q.n) order by q.name)
                                      from (select m.staff_id, st.name, count(distinct coalesce(m.offer_id::text, m.id::text)) n,
                                                   coalesce(jsonb_agg(distinct o.role_type) filter (where o.role_type is not null), '[]'::jsonb) roles
                                              from public.shift_offer_messages m
                                              left join public.staff st on st.id = m.staff_id
                                              left join public.shift_offers o on o.id = m.offer_id
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

CREATE OR REPLACE FUNCTION public.shift_offer_sender_claim(p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  e public.shift_offer_engine_settings%rowtype;
  v_limit int;
  v_messages jsonb;
  v_open boolean; v_merged int := 0; v_emailed int := 0; v_resent int := 0;
begin
  select * into e from public.shift_offer_engine_settings where id;
  update public.shift_offer_messages m
     set status = 'bot_channel',
         channel = 'bot',
         to_address = null,
         locked_at = null,
         last_error = null
   where m.wamid is null
     and m.status in ('queued', 'sending')
     and public.shift_offer_is_bot_staff(m.staff_id);
  if not coalesce(e.sender_enabled, false) then
    return jsonb_build_object('ok', true, 'sender_enabled', false, 'messages', '[]'::jsonb);
  end if;
  update public.shift_offer_messages
     set status = 'unknown',
         locked_at = null,
         last_error = 'unknown_delivery'
   where status = 'sending' and wamid is null and locked_at is not null
     and locked_at < now() - interval '10 minutes'
     and not public.shift_offer_is_bot_staff(staff_id);
  -- soefix T1: tarjouksen jälkeen deaktivoidulle ei lähetetä (kaikki kanavat)
  update public.shift_offer_messages m
     set status = 'skipped', last_error = 'skipped_inactive', locked_at = null
    from public.staff st
   where st.id = m.staff_id and not st.active
     and m.status = 'queued' and m.wamid is null;
  v_limit := greatest(1, least(coalesce(p_limit, 20), 50));
  -- booking_153: saman päivän viestit yhdeksi (4), sähköpostikanava (asetus), WhatsApp vain 08–21 (d)
  v_merged := booking.shift_offer_merge_same_day(now());
  -- soefix B7/B8: kadonneet ilmoitukset kerran toista kanavaa pitkin + kuittaamaton bottirivi sähköpostiin (2 h, 8–21)
  v_resent := booking.shift_offer_resend_lost(now());
  v_emailed := booking.shift_offer_email_drain(50);
  v_open := booking.shift_offer_wa_open(now());
  with picked as (
    select m.id
      from public.shift_offer_messages m
      left join public.staff st on st.id = m.staff_id
      left join booking.shift_offer_message_meta mm0 on mm0.message_id = m.id
      cross join lateral (select booking.shift_offer_wa_ready(m.staff_id, m.kind, mm0.subkind) as ok) rd
     where m.status = 'queued' and m.next_attempt_at <= now() and m.wamid is null
       and m.channel is distinct from 'bot'
       and not public.shift_offer_is_bot_staff(m.staff_id)
       and (
         m.channel = 'none'
         -- soefix C1: WhatsApp-rivi, jolle WhatsApp ei ole nyt käytettävissä (henkilö/moottori/allowlist/pohja) → planMessage siirtää sähköpostiin
         or (m.channel = 'whatsapp' and not rd.ok)
         or (v_open and rd.ok)
       )
     order by m.id
     limit v_limit
     for update of m skip locked
  ), upd as (
    update public.shift_offer_messages m
       set status = 'sending', locked_at = now()
      from picked
     where m.id = picked.id
    returning m.*
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', u.id,
    'kind', u.kind,
    'channel', u.channel,
    'staff_id', u.staff_id,
    'attempts', u.attempts,
    'wamid', u.wamid,
    'status', u.status,
    'phone_raw', st.phone_e164,
    'email', st.email,
    'staff_whatsapp_enabled', coalesce(st.whatsapp_enabled, false),
    'bot_channel', public.shift_offer_is_bot_staff(u.staff_id),
    'role_type', o.role_type,
    'starts_at', w.starts_at,
    'ends_at', w.ends_at,
    -- soefix B2: claim ei enää jatka määräaikaa; näytetään sama aika, joka kirjataan vasta onnistuneessa lähetyksessä (sender_complete, locked_at)
    'deadline_at', case when u.recipient_id is not null and u.kind in ('offer','reminder') then booking.shift_offer_deadline_preview(u.recipient_id, u.locked_at) else r.deadline_at end,
    'subkind', mm.subkind,
    'digest_key', mm.digest_key,
    'digest', case when mm.subkind = 'day_digest' then mm.payload end,
    'body', u.body,
    'session_open', exists (select 1 from public.whatsapp_messages wm where wm.staff_id = u.staff_id and wm.direction = 'inbound'
                             and coalesce(wm.received_at, wm.created_at) > now() - interval '23 hours 50 minutes'),
    'page_token', case when mm.subkind = 'day_digest' then booking.shift_staff_page_token(u.staff_id, true) end,
    'ask_no', case when u.kind = 'exhausted_ask' then nullif(substring(u.dedupe_key from ':ask:([0-9]+)$'), '')::int else null end,
    'ask_count', s.exhausted_ask_count,
    'token', public.shift_offer_sign_token(u.offer_id, u.staff_id, coalesce(w.starts_at, now() + interval '14 days'))
  ) order by u.id), '[]'::jsonb)
    into v_messages
    from upd u
    left join public.staff st on st.id = u.staff_id
    left join public.shift_offers o on o.id = u.offer_id
    left join public.work_shifts w on w.id = o.shift_id
    left join public.shift_offer_recipients r on r.id = u.recipient_id
    left join public.shift_offer_settings s on s.role_type = o.role_type
    left join booking.shift_offer_message_meta mm on mm.message_id = u.id;
  v_messages := coalesce(v_messages, '[]'::jsonb);
  return jsonb_build_object(
    'ok', true,
    'sender_enabled', true,
    'whatsapp_enabled', e.whatsapp_enabled,
    'whatsapp_dry_run', e.whatsapp_dry_run,
    'allow_staff_ids', to_jsonb(e.whatsapp_allow_staff_ids),
    'templates', coalesce(booking.shift_offer_cfg('wa_templates'), '{}'::jsonb),
    'whatsapp_hours_open', v_open,
    'email_enabled', booking.shift_offer_cfg_bool('email_enabled', false),
    'merged', v_merged,
    'emailed', v_emailed,
    'resent', v_resent,
    'messages', v_messages);
end $function$;

CREATE OR REPLACE FUNCTION public.shift_offer_sender_complete(p_result jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v public.shift_offer_messages%rowtype;
  v_action text; v_wamid text; v_err text; v_channel text; v_to text;
  v_attempts int; v_retry timestamptz; v_payload jsonb; v_status text;
begin
  if p_result is null or jsonb_typeof(p_result) <> 'object' then
    return jsonb_build_object('ok', false, 'error', 'bad_result');
  end if;
  if coalesce(p_result->>'id', '') !~ '^[0-9]+$' then
    return jsonb_build_object('ok', false, 'error', 'bad_id');
  end if;
  v_action := p_result->>'action';
  if v_action not in ('sent','retry','fail','fail_no_contact','release','already_sent','bot_channel') then
    return jsonb_build_object('ok', false, 'error', 'bad_action');
  end if;
  select * into v from public.shift_offer_messages where id = (p_result->>'id')::bigint for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'missing'); end if;
  if public.shift_offer_is_bot_staff(v.staff_id) and v.wamid is null then
    update public.shift_offer_messages set
      status = 'bot_channel', channel = 'bot', to_address = null,
      locked_at = null, last_error = null, last_payload = null
     where id = v.id and wamid is null;
    return jsonb_build_object('ok', true, 'status', 'bot_channel');
  end if;
  v_wamid := nullif(p_result->>'wamid', '');
  if v_action = 'already_sent' or (v.wamid is not null and v_action = 'sent') then
    return jsonb_build_object('ok', true, 'duplicate', v.wamid is not null, 'status', v.status, 'wamid', v.wamid);
  end if;
  if v.status is distinct from 'sending' or v.wamid is not null then
    return jsonb_build_object('ok', false, 'error', 'not_locked', 'status', v.status, 'wamid', v.wamid);
  end if;
  v_err := left(nullif(p_result->>'error', ''), 500);
  v_channel := case when p_result->>'channel' in ('whatsapp','email','none') then p_result->>'channel' else null end;
  v_to := nullif(p_result->>'to', '');
  v_payload := p_result->'payload';
  if jsonb_typeof(v_payload) = 'null' then v_payload := null; end if;
  v_payload := public.shift_offer_mask_payload(v_payload);
  if coalesce(p_result->>'attempts', '') ~ '^[0-9]+$' then
    v_attempts := (p_result->>'attempts')::int;
  else
    v_attempts := v.attempts;
  end if;
  if coalesce(p_result->>'retry_at', '') <> '' then
    v_retry := (p_result->>'retry_at')::timestamptz;
  end if;
  if v_action = 'sent' then
    if v_wamid is null then return jsonb_build_object('ok', false, 'error', 'no_wamid'); end if;
    update public.shift_offer_messages set
      status = 'sent', wamid = v_wamid, sent_at = now(), provider_status = 'sent',
      channel = coalesce(v_channel, 'whatsapp'), to_address = coalesce(v_to, to_address),
      attempts = v_attempts, last_error = null, last_payload = v_payload, locked_at = null
     where id = v.id and status = 'sending' and wamid is null;
    if not found then return jsonb_build_object('ok', false, 'error', 'not_locked'); end if;
    -- soefix B2: määräaika jatkuu vain onnistuneesta lähetyksestä, kerran per viesti, claimin hetkellä (= viestissä näytetty aika)
    perform booking.shift_offer_deadline_on_sent(v.id, coalesce(v.locked_at, now()));
    v_status := 'sent';
  elsif v_action = 'fail_no_contact' then
    update public.shift_offer_messages set
      status = 'failed_no_contact', channel = 'none', to_address = null,
      last_error = coalesce(v_err, 'no_phone'), locked_at = null, last_payload = null
     where id = v.id and status = 'sending' and wamid is null;
    v_status := 'failed_no_contact';
  elsif v_action = 'fail' then
    update public.shift_offer_messages set
      status = 'failed', provider_status = 'failed',
      channel = coalesce(v_channel, channel), to_address = coalesce(v_to, to_address),
      attempts = v_attempts, last_error = coalesce(v_err, 'failed'), last_payload = v_payload, locked_at = null
     where id = v.id and status = 'sending' and wamid is null;
    v_status := 'failed';
  elsif v_action = 'retry' then
    update public.shift_offer_messages set
      status = 'queued', attempts = v_attempts, last_error = v_err,
      next_attempt_at = coalesce(v_retry, now() + interval '1 minute'),
      channel = coalesce(v_channel, channel), to_address = coalesce(v_to, to_address),
      last_payload = v_payload, locked_at = null
     where id = v.id and status = 'sending' and wamid is null;
    v_status := 'queued';
  else
    update public.shift_offer_messages set
      status = 'queued', last_error = v_err,
      next_attempt_at = coalesce(v_retry, now() + interval '15 minutes'),
      channel = coalesce(v_channel, channel), to_address = case when v_channel = 'none' then null else coalesce(v_to, to_address) end,
      last_payload = v_payload, locked_at = null
     where id = v.id and status = 'sending' and wamid is null;
    v_status := 'queued';
  end if;
  return jsonb_build_object('ok', true, 'status', v_status, 'wamid', case when v_action = 'sent' then v_wamid else null end);
end $function$;

CREATE OR REPLACE FUNCTION booking.shift_offer_email_drain(p_limit integer DEFAULT 50)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare m record; v_out bigint; v_n int := 0; v_subj text;
begin
  if not booking.shift_offer_cfg_bool('email_enabled', false) then return 0; end if;
  for m in
    select x.*, mm.subkind from public.shift_offer_messages x
      left join booking.shift_offer_message_meta mm on mm.message_id = x.id
     where x.status = 'queued' and x.channel = 'email' and x.wamid is null and x.next_attempt_at <= now()
       and not public.shift_offer_is_bot_staff(x.staff_id)
     order by x.id limit greatest(1, least(coalesce(p_limit, 50), 200))
     for update of x skip locked
  loop
    -- booking_155: "jo mennyt" -ilmoituksesta lähti jo sähköpostikopio (trigger), joten WhatsAppin sähköpostivarapolku ei lähetä toista
    if m.subkind = 'already_taken' and m.offer_id is not null and exists (
         select 1 from booking.email_outbox e where e.dedupe_key = 'b153:at-mail:' || m.offer_id::text || ':' || m.staff_id::text) then
      update public.shift_offer_messages set status = 'skipped', last_error = 'email_copy_sent', locked_at = null where id = m.id;
      v_n := v_n + 1;
      continue;
    end if;
    v_subj := case
      when m.subkind = 'day_digest' then 'Vuoroasiat yhdellä viestillä'
      when m.kind = 'offer' then 'Vapaa työvuoro'
      when m.kind = 'reminder' then 'Muistutus työvuorosta'
      when m.kind = 'filled' then 'Vuoro on jo mennyt'
      when m.kind = 'cancelled' then 'Työvuoro peruttu'
      else 'Työvuoroilmoitus' end;
    -- soefix T1: tarjouksen jälkeen deaktivoidulle ei lähetetä
    if exists (select 1 from public.staff st where st.id = m.staff_id and not st.active) then
      update public.shift_offer_messages set status = 'skipped', last_error = 'skipped_inactive', locked_at = null where id = m.id;
      v_n := v_n + 1;
      continue;
    end if;
    v_out := booking.shift_offer_email(m.staff_id, v_subj || ' – Tapio', m.body, 'msg:' || m.id::text,
                                       case when m.subkind = 'day_digest' then booking.shift_staff_page_url(m.staff_id) end);
    if v_out is null then
      update public.shift_offer_messages set status = 'failed_no_contact', last_error = 'email_unavailable', locked_at = null where id = m.id;
    else
      update public.shift_offer_messages set status = 'sent', sent_at = now(), to_address = coalesce(to_address, (select payload->>'to_email' from booking.email_outbox where id = v_out)),
             last_error = 'email_outbox:' || v_out::text, locked_at = null where id = m.id;
      -- soefix B2: määräaika jatkuu vasta, kun email_outbox-rivi on 'sent' (trigger booking.shift_offer_email_sent_trg); skipped/failed ei jatka
    end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $function$;

CREATE OR REPLACE FUNCTION booking.shift_offer_email(p_staff uuid, p_subject text, p_text text, p_dedupe text, p_link text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare st public.staff%rowtype; v_mode text; v_id bigint;
begin
  if not booking.shift_offer_cfg_bool('email_enabled', false) then return null; end if;
  -- soefix T1: deaktivoidulle ei lähetetä
  select * into st from public.staff s where s.id = p_staff and s.active;
  if not found or not booking._valid_email(btrim(coalesce(st.email, ''))) then return null; end if;
  select mode into v_mode from booking.integration_config where key = 'resend';
  insert into booking.email_outbox (kind, locale, dedupe_key, status, payload)
  values ('staff_shift_notice', 'fi', 'b153:' || p_dedupe,
          case when coalesce(v_mode, 'off') = 'off' then 'skipped' else 'pending' end,
          jsonb_build_object('to_email', btrim(st.email), 'to_name', st.name, 'subject', left(p_subject, 200), 'text', p_text, 'link_url', p_link))
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  return v_id;
end $function$;

CREATE OR REPLACE FUNCTION public.shift_offer_queue_message(p_offer uuid, p_recipient bigint, p_staff uuid, p_kind text, p_body text, p_dedupe text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id bigint; v_channel text; v_to text; v_phone text; st public.staff%rowtype;
begin
  if p_body is null or p_dedupe is null then return null; end if;
  select * into st from public.staff s where s.id = p_staff;
  if not found then
    v_channel := 'none'; v_to := null;
  elsif not st.active then
    -- soefix T1: deaktivoitu henkilö (esim. tarjouksen jälkeen): ei lähetystä, ei claimia
    insert into public.shift_offer_messages (offer_id, recipient_id, staff_id, kind, channel, to_address, body, dedupe_key, status, last_error)
    values (p_offer, p_recipient, p_staff, p_kind, 'none', null, p_body, p_dedupe, 'skipped', 'skipped_inactive')
    on conflict (dedupe_key) do nothing
    returning id into v_id;
    return v_id;
  elsif public.shift_offer_is_bot_staff(p_staff) then
    insert into public.shift_offer_messages (offer_id, recipient_id, staff_id, kind, channel, to_address, body, dedupe_key, status)
    values (p_offer, p_recipient, p_staff, p_kind, 'bot', null, p_body, p_dedupe, 'bot_channel')
    on conflict (dedupe_key) do nothing
    returning id into v_id;
    return v_id;
  else
    v_phone := public.shift_offer_phone_e164(st.phone_e164);
    if st.whatsapp_enabled and v_phone is not null then
      v_channel := 'whatsapp'; v_to := v_phone;
    elsif booking._valid_email(btrim(coalesce(st.email, ''))) then
      v_channel := 'email'; v_to := btrim(st.email);
    else
      v_channel := 'none'; v_to := null;
    end if;
  end if;
  -- soefix C2: ei toimivaa kanavaa → failed_no_contact / no_working_channel heti (ei claimia, ei määräajan jatkoa; kierros etenee normaalisti)
  insert into public.shift_offer_messages (offer_id, recipient_id, staff_id, kind, channel, to_address, body, dedupe_key, status, last_error)
  values (p_offer, p_recipient, p_staff, p_kind, v_channel, v_to, p_body, p_dedupe,
          case when v_channel = 'none' then 'failed_no_contact' else 'queued' end,
          case when v_channel = 'none' then 'no_working_channel' end)
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  return v_id;
end $function$;

CREATE OR REPLACE FUNCTION public.shift_offer_ensure(p_shift_id uuid, p_now timestamp with time zone DEFAULT now(), p_dry boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  w public.work_shifts%rowtype;
  s public.shift_offer_settings%rowtype;
  o public.shift_offers%rowtype;
  v_date date; v_direct boolean; v_round int; v_max int; v_kind text;
  v_staff uuid[]; v_names text[]; v_sorts int[]; v_n int; v_pending int; v_snooze timestamptz;
  v_declined boolean; v_due boolean; r record; v_dl timestamptz;
begin
  select * into w from public.work_shifts x where x.id = p_shift_id;
  if not found or w.status <> 'active' then return jsonb_build_object('action', 'skip', 'reason', 'shift'); end if;
  select * into s from public.shift_offer_settings x where x.role_type = w.role_type;
  if not found or not s.enabled then return jsonb_build_object('action', 'skip', 'reason', 'disabled'); end if;
  v_date := (w.starts_at at time zone s.timezone)::date;
  if not public.shift_offer_allowed(w.role_type, v_date) then return jsonb_build_object('action', 'skip', 'reason', 'not_allowed'); end if;
  -- booking_153 e/f: ?-vuoro asetuksella, poissaolo vapauttaa vuoron
  if not booking.shift_offer_is_vacant(w.id) then
    if w.staffing_status is distinct from 'open' and not exists (select 1 from public.shift_assignments a where a.shift_id = w.id and a.status in ('assigned','confirmed')) then
      return jsonb_build_object('action', 'skip', 'reason', 'staffing');
    end if;
    return jsonb_build_object('action', 'skip', 'reason', 'assigned');
  end if;
  if w.starts_at <= p_now or w.starts_at > p_now + s.start_before then
    return jsonb_build_object('action', 'skip', 'reason', 'window');
  end if;
  if public.shift_offer_blocked_by_closure(w.role_type, w.starts_at, w.ends_at, 'vacant_shift') then
    return jsonb_build_object('action', 'skip', 'reason', 'treatment_closed');
  end if;

  select * into o from public.shift_offers x
   where x.shift_id = w.id and x.scenario = 'vacant_shift' and x.status in ('active','paused','escalated')
   for update;
  if not found then
    if exists (select 1 from public.shift_offers x where x.shift_id = w.id and x.scenario = 'vacant_shift' and x.status in ('filled','closed')) then
      return jsonb_build_object('action', 'skip', 'reason', 'finished');
    end if;
    select q.direct_to_all into v_direct from public.shift_offer_wait(w.role_type, w.starts_at, p_now, false) q;
    select coalesce(max(rnd.round_no), 0) into v_max from public.shift_offer_rounds rnd
     where rnd.role_type = w.role_type and rnd.scenario = 'vacant_shift' and extract(isodow from v_date)::smallint = any (rnd.weekdays)
       and v_date >= rnd.valid_from and (rnd.valid_to is null or v_date <= rnd.valid_to);
    -- soefix B3: roolille ja viikonpäivälle ei ole kierroksia → ei eskalointia, vaan skip no_rounds (kirjataan raporttia varten).
    -- Hoitajavuoro (therapist) ei kuulu tähän: sen eskalointi/varoitus/6 h sulku pysyy ennallaan (B6 pudotettu, Joonas 25.10. 16:59).
    if coalesce(v_max, 0) = 0 and w.role_type <> 'therapist' then
      if not p_dry then
        insert into booking.shift_offer_skips (shift_id, reason, role_type, shift_date, first_seen_at, last_seen_at, seen_count)
        values (w.id, 'no_rounds', w.role_type, v_date, p_now, p_now, 1)
        on conflict (shift_id, reason) do update set last_seen_at = excluded.last_seen_at, seen_count = booking.shift_offer_skips.seen_count + 1;
      end if;
      return jsonb_build_object('action', 'skip', 'reason', 'no_rounds', 'shift_id', w.id, 'role_type', w.role_type, 'shift_date', v_date);
    end if;
    v_staff := '{}'; v_names := '{}'; v_sorts := '{}'; v_round := 1; v_kind := null;
    if v_direct then
      select array_agg(p.staff_id), array_agg(p.staff_name), array_agg(p.sort_order), min(p.round_no), min(p.round_kind)
        into v_staff, v_names, v_sorts, v_round, v_kind
        from public.shift_offer_pick_staff(w.role_type, v_date, 1, 'vacant_shift', w.starts_at, w.ends_at, true) p;
    else
      for v_round in 1 .. v_max loop
        select array_agg(p.staff_id order by p.sort_order, p.staff_name), array_agg(p.staff_name order by p.sort_order, p.staff_name),
               array_agg(p.sort_order order by p.sort_order, p.staff_name), min(p.round_kind)
          into v_staff, v_names, v_sorts, v_kind
          from public.shift_offer_pick_staff(w.role_type, v_date, v_round, 'vacant_shift', w.starts_at, w.ends_at, false) p;
        exit when coalesce(cardinality(v_staff), 0) > 0;
      end loop;
    end if;
    if coalesce(cardinality(v_staff), 0) = 0 then
      if p_dry then return jsonb_build_object('action', 'would_exhaust', 'shift_id', w.id); end if;
      insert into public.shift_offers (shift_id, role_type, scenario, status, current_round_no, created_by)
      values (w.id, w.role_type, 'vacant_shift', 'escalated', coalesce(v_max, 1), 'tyovuoro-tapio')
      returning * into o;
      return public.shift_offer_on_exhausted(o.id, p_now, false) || jsonb_build_object('shift_id', w.id);
    end if;
    if p_dry then
      return jsonb_build_object('action', 'would_offer', 'shift_id', w.id, 'role_type', w.role_type, 'starts_at', w.starts_at,
        'round_no', v_round, 'round_kind', v_kind, 'staff_ids', to_jsonb(v_staff), 'staff_names', to_jsonb(v_names));
    end if;
    begin
      insert into public.shift_offers (shift_id, role_type, scenario, status, current_round_no, round_started_at, created_by)
      values (w.id, w.role_type, 'vacant_shift', 'active', v_round, p_now, 'tyovuoro-tapio')
      returning * into o;
    exception when unique_violation then
      return jsonb_build_object('action', 'skip', 'reason', 'concurrent', 'shift_id', w.id);
    end;
    v_n := public.shift_offer_issue_recipients(o.id, w.role_type, w.starts_at, w.ends_at, p_now, v_round, v_kind, v_staff, v_names, v_sorts);
    update public.shift_open_events set status = 'done', processed_at = p_now where shift_id = w.id and status in ('new','processing');
    return jsonb_build_object('action', 'offered', 'shift_id', w.id, 'offer_id', o.id, 'round_no', v_round, 'round_kind', v_kind, 'recipients', v_n);
  end if;

  -- tyhjä kierros on jo kysytty Joonakselta / sulku on ajastettu: älä etene tavallisia kierroksia
  if o.status = 'escalated' then
    if o.next_action_at is not null and o.next_action_at > p_now and o.role_type <> 'therapist' then
      return jsonb_build_object('action', 'waiting', 'offer_id', o.id, 'shift_id', w.id);
    end if;
    if p_dry then return jsonb_build_object('action', 'would_exhausted_step', 'offer_id', o.id, 'shift_id', w.id); end if;
    return public.shift_offer_on_exhausted(o.id, p_now, false) || jsonb_build_object('shift_id', w.id);
  end if;

  for r in select * from public.shift_offer_recipients x where x.offer_id = o.id and x.status = 'snoozed' and x.snooze_until <= p_now loop
    v_dl := public.shift_offer_round_deadline(w.role_type, w.starts_at, p_now, r.round_kind, false);
    if p_dry then return jsonb_build_object('action', 'would_remind', 'offer_id', o.id, 'staff_id', r.staff_id); end if;
    update public.shift_offer_recipients set status = 'pending', snooze_until = null, deadline_at = v_dl, reminder_sent_at = p_now where id = r.id;
    perform public.shift_offer_queue_message(o.id, r.id, r.staff_id, 'reminder',
      public.shift_offer_compose('reminder', r.staff_id, o.id, w.role_type, w.starts_at, w.ends_at, v_dl, null),
      'offer:' || o.id::text || ':staff:' || r.staff_id::text || ':reminder:' || to_char(p_now at time zone 'UTC', 'YYYYMMDDHH24MI'));
  end loop;

  -- Kaikille-hetki on ohitettu: älä etene kierros kerrallaan (se saisi 6 h / all_round_wait jokaiselle).
  -- Hyppää suoraan all-kierrokseen ja named_lastiin, jätä aiemmat vastaanottajat voimaan.
  if o.all_sent_at is null and public.shift_offer_all_by_at(w.role_type, w.starts_at) <= p_now then
    v_staff := null; v_names := null; v_sorts := null; v_round := null; v_kind := null;
    select array_agg(p.staff_id order by p.sort_order, p.staff_name),
           array_agg(p.staff_name order by p.sort_order, p.staff_name),
           array_agg(p.sort_order order by p.sort_order, p.staff_name),
           min(p.round_no), min(p.round_kind)
      into v_staff, v_names, v_sorts, v_round, v_kind
      from public.shift_offer_pick_staff(w.role_type, v_date, 1, o.scenario, w.starts_at, w.ends_at, true) p
     where not exists (
       select 1 from public.shift_offer_recipients x where x.offer_id = o.id and x.staff_id = p.staff_id);
    if coalesce(cardinality(v_staff), 0) > 0 then
      if p_dry then
        return jsonb_build_object('action', 'would_advance', 'offer_id', o.id, 'shift_id', w.id,
          'round_no', v_round, 'round_kind', coalesce(v_kind, 'all'), 'staff_ids', to_jsonb(v_staff));
      end if;
      v_n := public.shift_offer_issue_recipients(o.id, w.role_type, w.starts_at, w.ends_at, p_now,
        v_round, coalesce(v_kind, 'all'), v_staff, v_names, v_sorts);
      return jsonb_build_object('action', 'advanced', 'offer_id', o.id, 'shift_id', w.id,
        'round_no', v_round, 'round_kind', coalesce(v_kind, 'all'), 'recipients', v_n);
    end if;
    if not p_dry then
      update public.shift_offers set all_sent_at = p_now, updated_at = p_now where id = o.id and all_sent_at is null;
    end if;
    o.all_sent_at := p_now;
  end if;

  select count(*) filter (where status = 'pending'), min(snooze_until) filter (where status = 'snoozed' and snooze_until > p_now)
    into v_pending, v_snooze
    from public.shift_offer_recipients where offer_id = o.id and round_no = o.current_round_no;
  if v_pending = 0 and v_snooze is not null then
    if not p_dry then update public.shift_offers set status = 'paused', next_action_at = v_snooze, updated_at = p_now where id = o.id; end if;
    return jsonb_build_object('action', 'paused', 'offer_id', o.id, 'until', v_snooze);
  end if;

  v_declined := v_pending = 0 and v_snooze is null and exists (
    select 1 from public.shift_offer_recipients x where x.offer_id = o.id and x.round_no = o.current_round_no);
  v_due := o.next_action_at is not null and o.next_action_at <= p_now
        or exists (select 1 from public.shift_offer_recipients x where x.offer_id = o.id and x.round_no = o.current_round_no and x.status = 'pending' and x.deadline_at <= p_now);
  if not v_declined and not v_due then
    -- booking_153 sääntö 7: loppumuistutus vastaamattomille
    v_n := booking.shift_offer_round_reminders(o.id, p_now, p_dry);
    if v_n > 0 then
      return jsonb_build_object('action', case when p_dry then 'would_round_remind' else 'round_reminded' end, 'offer_id', o.id, 'shift_id', w.id, 'count', v_n);
    end if;
    return jsonb_build_object('action', 'waiting', 'offer_id', o.id, 'shift_id', w.id);
  end if;

  select coalesce(max(rnd.round_no), o.current_round_no) into v_max from public.shift_offer_rounds rnd
   where rnd.role_type = w.role_type and rnd.scenario = o.scenario and extract(isodow from v_date)::smallint = any (rnd.weekdays)
     and v_date >= rnd.valid_from and (rnd.valid_to is null or v_date <= rnd.valid_to);
  v_round := o.current_round_no;
  loop
    v_round := v_round + 1;
    if v_round > v_max then
      if p_dry then return jsonb_build_object('action', 'would_exhaust', 'offer_id', o.id, 'shift_id', w.id); end if;
      return public.shift_offer_on_exhausted(o.id, p_now, false) || jsonb_build_object('shift_id', w.id);
    end if;
    select array_agg(p.staff_id order by p.sort_order, p.staff_name), array_agg(p.staff_name order by p.sort_order, p.staff_name),
           array_agg(p.sort_order order by p.sort_order, p.staff_name), min(p.round_kind)
      into v_staff, v_names, v_sorts, v_kind
      from public.shift_offer_pick_staff(w.role_type, v_date, v_round, o.scenario, w.starts_at, w.ends_at, false) p
     where not exists (select 1 from public.shift_offer_recipients x where x.offer_id = o.id and x.staff_id = p.staff_id);
    if coalesce(cardinality(v_staff), 0) = 0 then continue; end if;
    if p_dry then
      return jsonb_build_object('action', 'would_advance', 'offer_id', o.id, 'shift_id', w.id, 'round_no', v_round, 'round_kind', v_kind, 'staff_ids', to_jsonb(v_staff));
    end if;
    v_n := public.shift_offer_issue_recipients(o.id, w.role_type, w.starts_at, w.ends_at, p_now, v_round, v_kind, v_staff, v_names, v_sorts);
    return jsonb_build_object('action', 'advanced', 'offer_id', o.id, 'shift_id', w.id, 'round_no', v_round, 'recipients', v_n);
  end loop;
end $function$;

CREATE OR REPLACE FUNCTION booking.shift_staff_welcome(p_message_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare m public.whatsapp_messages%rowtype; st public.staff%rowtype; c booking.shift_staff_whatsapp_consent%rowtype;
        v_first timestamptz; v_text text; v_link text; v_name text;
begin
  select * into m from public.whatsapp_messages x where x.id = p_message_id and x.direction = 'inbound';
  if not found or m.staff_id is null then return jsonb_build_object('send', false, 'reason', 'unknown'); end if;
  select * into st from public.staff s where s.id = m.staff_id and s.active;
  if not found then return jsonb_build_object('send', false, 'reason', 'unknown'); end if;
  select min(coalesce(x.received_at, x.created_at)) into v_first from public.whatsapp_messages x where x.staff_id = st.id and x.direction = 'inbound';
  insert into booking.shift_staff_whatsapp_consent (staff_id, first_inbound_at, first_message_id)
  values (st.id, coalesce(v_first, m.received_at, now()), case when coalesce(m.received_at, m.created_at) <= coalesce(v_first, m.received_at) then m.id end)
  on conflict (staff_id) do nothing;
  select * into c from booking.shift_staff_whatsapp_consent x where x.staff_id = st.id for update;
  if not booking.shift_offer_cfg_bool('welcome_enabled', false) then return jsonb_build_object('send', false, 'reason', 'disabled'); end if;
  if public.shift_offer_is_bot_staff(st.id) then return jsonb_build_object('send', false, 'reason', 'bot_channel'); end if;
  if c.welcome_sent_at is not null then return jsonb_build_object('send', false, 'reason', 'already_sent'); end if;
  -- soefix B9: rinnakkainen käsittely (sama viesti kahdesti) → vain yksi lähettää; varaus vanhenee 10 min
  if c.welcome_claimed_at is not null and c.welcome_claimed_at > now() - interval '10 minutes' then return jsonb_build_object('send', false, 'reason', 'claimed'); end if;
  if c.first_message_id is distinct from m.id then return jsonb_build_object('send', false, 'reason', 'not_first'); end if;
  if coalesce(m.received_at, m.created_at) < now() - interval '24 hours' then return jsonb_build_object('send', false, 'reason', 'window_closed'); end if;
  if m.phone_e164 is null then return jsonb_build_object('send', false, 'reason', 'no_phone'); end if;
  v_link := booking.shift_staff_page_url(st.id);
  if v_link is null then return jsonb_build_object('send', false, 'reason', 'no_link'); end if;
  v_name := split_part(btrim(st.name), ' ', 1);
  select t.published_text into v_text from booking.site_texts t
   where t.key = 'shift_offer.whatsapp.welcome' and t.lang = 'fi' and nullif(btrim(t.published_text), '') is not null;
  v_text := coalesce(v_text, 'Hei {{var:name}}! Tervetuloa Sipoonjoen perinnesaunan vuoroviesteihin. Saat tästä numerosta tarjouksia avoimista vuoroista, jotka sopivat sinulle. Vastaa tarjoukseen painamalla viestin "Avaa vastaus" -painiketta, ja valitse sivulla hyväksy tai kieltäydy. Kirjautumista ei tarvita. Jos useampi ehtii hyväksyä saman vuoron, se menee ensimmäiselle. Omalla sivullasi näet avoimet ja jo vastatut päiväsi, ja voit muuttaa vastaustasi siellä: {{var:link}} Viestejä lähetetään vain klo 8–21. Tapio');
  -- {nimi}/{linkki} (hyväksytyn tekstin muoto) ja {{var:name}}/{{var:link}} (site_texts-muoto) täytetään molemmat
  v_text := replace(replace(replace(replace(v_text, '{{var:name}}', coalesce(v_name, '')), '{{var:link}}', v_link), '{nimi}', coalesce(v_name, '')), '{linkki}', v_link);
  -- soefix B9: welcome_sent_at vasta shift_staff_welcome_mark_sent():ssä (wamid saatu); tässä vain varaus
  update booking.shift_staff_whatsapp_consent set welcome_claimed_at = now() where staff_id = st.id;
  return jsonb_build_object('send', true, 'body', v_text, 'to', m.phone_e164, 'staff_id', st.id);
end $function$;

CREATE OR REPLACE FUNCTION public.parse_shift_title(p_title text, OUT staffing_status text, OUT staff_ids uuid[])
 RETURNS record
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  t text := btrim(coalesce(p_title, ''));
  parts text[];
  part text;
  sid uuid;
  ids uuid[] := '{}';
begin
  if t = '' or t = '-' then
    staffing_status := 'open'; staff_ids := '{}'; return;
  elsif t = '?' then
    staffing_status := 'uncertain'; staff_ids := '{}'; return;
  end if;

  select id into sid from public.staff where calendar_name = t and active;  -- soefix T1
  if found then
    staffing_status := 'assigned'; staff_ids := array[sid]; return;
  end if;

  if position('&' in t) > 0 then
    parts := string_to_array(t, '&');
    foreach part in array parts loop
      sid := null;
      select id into sid from public.staff where calendar_name = btrim(part) and active;  -- soefix T1
      if sid is null then
        staffing_status := 'unresolved'; staff_ids := '{}'; return;
      end if;
      if not sid = any(ids) then ids := ids || sid; end if;
    end loop;
    staffing_status := 'assigned'; staff_ids := ids; return;
  end if;

  staffing_status := 'unresolved'; staff_ids := '{}';
end $function$;

create trigger shift_offer_email_sent after update of status on booking.email_outbox
  for each row when (new.status = 'sent' and old.status is distinct from 'sent')
  execute function booking.shift_offer_email_sent_trg();

revoke all on function booking.shift_offer_deadline_preview(bigint,timestamptz) from public, anon, authenticated;
grant execute on function booking.shift_offer_deadline_preview(bigint,timestamptz) to service_role;
revoke all on function booking.shift_offer_deadline_on_sent(bigint,timestamptz) from public, anon, authenticated;
grant execute on function booking.shift_offer_deadline_on_sent(bigint,timestamptz) to service_role;
revoke all on function booking.shift_offer_email_sent_trg() from public, anon, authenticated;
grant execute on function booking.shift_offer_email_sent_trg() to service_role;
revoke all on function booking.shift_offer_wa_ready(uuid,text,text) from public, anon, authenticated;
grant execute on function booking.shift_offer_wa_ready(uuid,text,text) to service_role;
revoke all on function booking.shift_offer_resend_lost(timestamptz) from public, anon, authenticated;
grant execute on function booking.shift_offer_resend_lost(timestamptz) to service_role;
revoke all on function public.shift_offer_bot_ack(bigint[]) from public, anon, authenticated;
grant execute on function public.shift_offer_bot_ack(bigint[]) to service_role;
revoke all on function booking.shift_staff_welcome_mark_sent(uuid,text) from public, anon, authenticated;
grant execute on function booking.shift_staff_welcome_mark_sent(uuid,text) to service_role;
revoke all on function booking.shift_staff_welcome_release(uuid) from public, anon, authenticated;
grant execute on function booking.shift_staff_welcome_release(uuid) to service_role;
revoke all on function booking.shift_offer_report_issues(timestamptz) from public, anon, authenticated;
grant execute on function booking.shift_offer_report_issues(timestamptz) to service_role;

-- B4: vanha 'vuorotarjous'-varapohja pois asetuksesta
update booking.settings set value = value #- '{offer,fallback}' where key = 'shift_offer.wa_templates';

-- Tervetuloteksti (Joonas hyväksyi 25.10.2026 17:00), versio 2, julkaistu
do $t$
declare t booking.site_texts; v_new text := 'Hei {{var:name}}! Tervetuloa Sipoonjoen perinnesaunan vuoroviesteihin. Saat tästä numerosta tarjouksia avoimista vuoroista, jotka sopivat sinulle. Vastaa tarjoukseen painamalla viestin "Avaa vastaus" -painiketta, ja valitse sivulla hyväksy tai kieltäydy. Kirjautumista ei tarvita. Jos useampi ehtii hyväksyä saman vuoron, se menee ensimmäiselle. Omalla sivullasi näet avoimet ja jo vastatut päiväsi, ja voit muuttaa vastaustasi siellä: {{var:link}} Viestejä lähetetään vain klo 8–21. Tapio'; v_ver int; v_id bigint;
begin
  select * into t from booking.site_texts where key = 'shift_offer.whatsapp.welcome' and lang = 'fi' for update;
  perform booking._text_validate(t.class, t.kind, 600, t.placeholders, v_new);
  v_ver := t.latest_version + 1;
  update booking.site_text_versions set status = 'superseded' where text_id = t.id and status = 'published';
  insert into booking.site_text_versions (text_id, version, text, status, base_version, author, author_kind, author_label, reason,
                                          escalation, protected, approved_at, note, published_by, published_at)
  values (t.id, v_ver, v_new, 'published', t.published_version, null, 'system', 'migraatio soefix',
          'soefix: Joonaksen hyväksymä WhatsApp-tervetuloteksti sellaisenaan ({nimi} = {{var:name}}, {linkki} = {{var:link}} = oma sivu)',
          booking._text_escalation(t.published_text, v_new), false, now(), 'Joonas hyväksyi 25.10.2026 17:00', null, now())
  returning id into v_id;
  update booking.site_texts set max_len = 600, published_text = v_new, published_version = v_ver, published_at = now(),
         needs_review = false, review_note = null where id = t.id;
  update booking.site_texts set needs_translation = true where key = t.key and lang = 'en' and published_version > 0;
  perform booking._text_refresh(t.id);
end $t$;

-- jälkitarkistus: uudet määrittelyt, oikeudet, kytkimet ennallaan
do $p$
declare v text; ok boolean := true; msg text := ''; s text;
begin
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_sender_claim(integer)')));
  if v is distinct from 'd6a47aa43feb0445f0bf00d549b60905' then ok := false; msg := msg || ' shift_offer_sender_claim=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_sender_complete(jsonb)')));
  if v is distinct from 'c29ed4d23f8ede7d1ae2ef1c283f9e03' then ok := false; msg := msg || ' shift_offer_sender_complete=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_email_drain(integer)')));
  if v is distinct from '0d8df86310ad86b3a6f43429274478ed' then ok := false; msg := msg || ' shift_offer_email_drain=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_email(uuid,text,text,text,text)')));
  if v is distinct from 'f17b064c82f56f3221cc0ea3570114e1' then ok := false; msg := msg || ' shift_offer_email=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_queue_message(uuid,bigint,uuid,text,text,text)')));
  if v is distinct from '0982a948c9e5fbe882f094c269afe31c' then ok := false; msg := msg || ' shift_offer_queue_message=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_ensure(uuid,timestamptz,boolean)')));
  if v is distinct from 'c5d3d5a5d4048fcd4d525f5daa045893' then ok := false; msg := msg || ' shift_offer_ensure=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_staff_welcome(uuid)')));
  if v is distinct from 'c20b901d3e21cb27814a7c2b160af97e' then ok := false; msg := msg || ' shift_staff_welcome=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.parse_shift_title(text)')));
  if v is distinct from 'a894b3c7f749ca2cca559198ba92a42b' then ok := false; msg := msg || ' parse_shift_title=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_deadline_preview(bigint,timestamptz)')));
  if v is distinct from '0b48a1eab2bb8df1a5393ba9978dd40e' then ok := false; msg := msg || ' shift_offer_deadline_preview=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_deadline_on_sent(bigint,timestamptz)')));
  if v is distinct from '103efa77f733a3c5d42bac53d49a4b4e' then ok := false; msg := msg || ' shift_offer_deadline_on_sent=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_email_sent_trg()')));
  if v is distinct from '5eacac6985c8f8b2d0efc3e888994965' then ok := false; msg := msg || ' shift_offer_email_sent_trg=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_wa_ready(uuid,text,text)')));
  if v is distinct from 'd7148175ce2c9768ca8b807571f5fb72' then ok := false; msg := msg || ' shift_offer_wa_ready=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_resend_lost(timestamptz)')));
  if v is distinct from 'f73ac1325a2228d61fffe4ae42ca193d' then ok := false; msg := msg || ' shift_offer_resend_lost=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('public.shift_offer_bot_ack(bigint[])')));
  if v is distinct from '7357790f5d1eae7bb1fd50bcd7fe91e1' then ok := false; msg := msg || ' shift_offer_bot_ack=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_staff_welcome_mark_sent(uuid,text)')));
  if v is distinct from '5a5bdaa5020efbc5b7a5f54587fd41b4' then ok := false; msg := msg || ' shift_staff_welcome_mark_sent=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_staff_welcome_release(uuid)')));
  if v is distinct from '836d7590612932497a3571875d8a5ea8' then ok := false; msg := msg || ' shift_staff_welcome_release=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.shift_offer_report_issues(timestamptz)')));
  if v is distinct from 'edc1f3bda7fcd6c40e7ed9767a0c895a' then ok := false; msg := msg || ' shift_offer_report_issues=' || coalesce(v, 'puuttuu'); end if;
  foreach s in array array['public.shift_offer_sender_claim(integer)', 'public.shift_offer_sender_complete(jsonb)', 'booking.shift_offer_email_drain(integer)', 'booking.shift_offer_email(uuid,text,text,text,text)', 'public.shift_offer_queue_message(uuid,bigint,uuid,text,text,text)', 'public.shift_offer_ensure(uuid,timestamptz,boolean)', 'booking.shift_staff_welcome(uuid)', 'public.parse_shift_title(text)', 'booking.shift_offer_deadline_preview(bigint,timestamptz)', 'booking.shift_offer_deadline_on_sent(bigint,timestamptz)', 'booking.shift_offer_email_sent_trg()', 'booking.shift_offer_wa_ready(uuid,text,text)', 'booking.shift_offer_resend_lost(timestamptz)', 'public.shift_offer_bot_ack(bigint[])', 'booking.shift_staff_welcome_mark_sent(uuid,text)', 'booking.shift_staff_welcome_release(uuid)', 'booking.shift_offer_report_issues(timestamptz)'] loop
    if has_function_privilege('anon', to_regprocedure(s), 'execute') or has_function_privilege('authenticated', to_regprocedure(s), 'execute')
       or not has_function_privilege('service_role', to_regprocedure(s), 'execute') then
      ok := false; msg := msg || ' oikeudet:' || s;
    end if;
  end loop;
  if exists (select 1 from soefix_flags_before b
              where b.eng is distinct from (select row_to_json(e)::jsonb - 'updated_at' from public.shift_offer_engine_settings e where e.id)
                 or b.roles is distinct from (select jsonb_object_agg(role_type, enabled) from public.shift_offer_settings)
                 or b.welcome is distinct from (select value from booking.settings where key = 'shift_offer.welcome_enabled')
                 or b.email is distinct from (select value from booking.settings where key = 'shift_offer.email_enabled')) then
    ok := false; msg := msg || ' moottorin kytkimet muuttuivat';
  end if;
  if (select value from booking.settings where key = 'shift_offer.wa_templates') ? 'fallback'
     or (select value -> 'offer' from booking.settings where key = 'shift_offer.wa_templates') ? 'fallback' then ok := false; msg := msg || ' fallback jäi'; end if;
  if not ok then raise exception 'soefix: jälkitarkistus epäonnistui:%', msg; end if;
end $p$;
