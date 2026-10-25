-- booking_175: yritysasiakkaan laskutustapa (verkkolasku / PDF), verkkokaupan verkkolaskun automaattinen jonotus, viitenumeron etuliite 7310.
-- Omistajan päätös (Joonas, 25.10.2026). Versio on väliaikainen (tuotannon versio kirjataan ajossa). Ei public-skeemaa. Hinnat, ALV, slugit ennallaan.
-- 1) _clean_company: company.invoice_method = 'einvoice' | 'pdf' (verkkokauppa). einvoice → OVT + välittäjä pakollisia (kuten ennen require_einvoice);
--    pdf → OVT-tiedot jätetään pois. Ilman invoice_methodia: require_einvoice = true → einvoice (vanha kauppa välimuistissa); muuten ennallaan
--    (hallinnan kutsujat admin_create_booking / _admin_create_legs / admin_create_customer: OVT valinnainen, laskutustapaa ei kirjata).
-- 2) _stamp_order_billing: orders.billing.invoice_method (vain kun annettu); pdf → billingissä ei OVT-tietoja.
-- 3) orders_invoice_draft_trg: luonnos syntyy kuten ennen. Lisäksi verkkokaupan tilaus (source_channel = 'web', status confirmed) ja
--    billing.invoice_method = 'einvoice' → lasku lähetetään heti samalla polulla kuin hallinnan "Lähetä verkkolasku"
--    (_invoice_allocate + _invoice_queue_dispatch → invoices.dispatch_status + invoice_dispatch_log). invoice_dispatch_mode ratkaisee:
--    live → 'queued' (invoice-dispatch-jono), muuten 'dry_run' (kirjataan, ei lähetetä). Tuotannossa dry_run, Procountor mode=off, daily_enabled=false:
--    mitään ei lähetetä. Virhe ei estä varausta: lasku jää luonnokseksi + audit_log 'invoice_auto_send_failed'.
--    PDF-laskutapa ja hallinnassa luodut laskut jäävät luonnokseksi; lähetys napista kuten ennen (ei automaattista sähköpostia).
-- 4) _invoice_allocate: viitenumero = booking.settings.invoice_reference_prefix (oletus "7310") + järjestysnumero + tarkiste 7-3-1 (_fi_reference),
--    enintään 20 merkkiä. Jo lähetettyjen laskujen viitteet eivät muutu (invoices_lock_trg estää). customer_snapshot_locked säilyy kuten tuotannossa.
-- Procountor-asetuksiin, invoice_dispatch_modeen ja edge-funktioihin ei kosketa.
--
-- Vartija: md5(pg_get_functiondef) luettu tuotannosta sxbofnuisemspgquoxyv 25.10.2026. Ajo keskeytyy eikä mitään muuteta, jos ei vastaa.
--   korvataan (tuotanto -> booking_175):
--     booking._clean_company(jsonb): 4e8d9dddda117bdc208f3b1bb281f97a -> 53fa5a8a98e98aeb4a97000d2f6b37ec
--     booking._stamp_order_billing(bigint,bigint,jsonb): 709b28b59f549df7be252b2942e77256 -> 693f24abfe0dddfbf4a2e345e1596e73
--     booking._invoice_allocate(bigint): ad7dbbd30a6b3362bf4011d4e8ff296e -> 46a3326812f896077fc2614ba783ff3d
--     booking.orders_invoice_draft_trg(): a9a389358507c2dca37acbacdcfd3d61 -> df1d0ebf036380495f6730d1fa93de7a
--   riippuvuudet, ei muuteta (tuotanto = vaadittu):
--     _invoice_queue_dispatch f3cfdb0e2d484ab6f63c6286c4ff8560
--     _ensure_draft_invoice eefa8e82c7aab1a148bdb3e319ae65ae
--     _fi_reference f7c4076dcc85d8efc97e7335c349da2c
--     _next_invoice_seq d0a99378be63598409608d001981a68a
--     _setting 70fcfa245e9e7d070dae7a6c1e90ce4d
--     _invoice_customer_json ad0ff09c390f51ff9279f3d55986f5c8
--     _seller_invoice 04e0d3066a7c4cd2a047325282b0ceaa
--     invoice_normalized a55a1149796f9feded3a688ca29132eb
--     invoices_lock_trg 63f39183d475f2b04bcc7a9e9aaf251e
--     orders_invoice_status_trg 9ec5c212604145e284fa07d2fd2686f6
--     admin_send_invoice 7ea29743e8e199c74ced1d62c730b27f
--     admin_create_invoice_from_order da51a0f8743daf809db544ed936d5418
--     invoice_dispatch_claim 098633014401dbd3cd76ff36f9cde16c
--     _ovt_ok 030ecd33df47a695b734910f1bc4a5a9
--     _upsert_company_customer 931c228224ec02107e1e81e4d77a485b
--     public_create_booking befba768679c4e414c4f3966ac4aa136
--     public_create_treatment_booking d47cd6e939943cb2cfa385c0767bc2cb
--     admin_create_booking 7ac1ba613b8db0ae6a4c2e6d9b3ce5c7
--     _admin_create_legs c86a86c12954b6d921564ee86f21b24f
--     admin_create_customer 0a26150daf77b1bfeae0145e4ad7c25f
--     _on_payment_paid de9084871640d213d10527a045157bf2
--     email_outbox_claim 2db9a1233a06e6293d0877f17de1ab72
--     admin_mark_voucher_claim_redeemed 525d1fa96fd7c37df4d7e502edf1bf71
--     _vc_due bea9cd9a32eb273ee72caed0aedd1e2e
-- Rollback: rollbacks/20261025070000_booking_175_ROLLBACK.sql. Testi: tests/invoices/t175_yrityslaskutus.sql (BEGIN … ROLLBACK).
set local lock_timeout = '5s';

do $g$
declare v text; ok boolean := true; msg text := '';
begin
  v := md5(pg_get_functiondef(to_regprocedure('booking._clean_company(jsonb)')));
  if v is null or v not in ('4e8d9dddda117bdc208f3b1bb281f97a', '53fa5a8a98e98aeb4a97000d2f6b37ec') then ok := false; msg := msg || ' _clean_company=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._stamp_order_billing(bigint,bigint,jsonb)')));
  if v is null or v not in ('709b28b59f549df7be252b2942e77256', '693f24abfe0dddfbf4a2e345e1596e73') then ok := false; msg := msg || ' _stamp_order_billing=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._invoice_allocate(bigint)')));
  if v is null or v not in ('ad7dbbd30a6b3362bf4011d4e8ff296e', '46a3326812f896077fc2614ba783ff3d') then ok := false; msg := msg || ' _invoice_allocate=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.orders_invoice_draft_trg()')));
  if v is null or v not in ('a9a389358507c2dca37acbacdcfd3d61', 'df1d0ebf036380495f6730d1fa93de7a') then ok := false; msg := msg || ' orders_invoice_draft_trg=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._invoice_queue_dispatch(bigint)')));
  if v is distinct from 'f3cfdb0e2d484ab6f63c6286c4ff8560' then ok := false; msg := msg || ' _invoice_queue_dispatch=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._ensure_draft_invoice(bigint)')));
  if v is distinct from 'eefa8e82c7aab1a148bdb3e319ae65ae' then ok := false; msg := msg || ' _ensure_draft_invoice=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._fi_reference(text)')));
  if v is distinct from 'f7c4076dcc85d8efc97e7335c349da2c' then ok := false; msg := msg || ' _fi_reference=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._next_invoice_seq(text)')));
  if v is distinct from 'd0a99378be63598409608d001981a68a' then ok := false; msg := msg || ' _next_invoice_seq=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._setting(text,jsonb)')));
  if v is distinct from '70fcfa245e9e7d070dae7a6c1e90ce4d' then ok := false; msg := msg || ' _setting=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._invoice_customer_json(bigint)')));
  if v is distinct from 'ad0ff09c390f51ff9279f3d55986f5c8' then ok := false; msg := msg || ' _invoice_customer_json=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._seller_invoice()')));
  if v is distinct from '04e0d3066a7c4cd2a047325282b0ceaa' then ok := false; msg := msg || ' _seller_invoice=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.invoice_normalized(bigint)')));
  if v is distinct from 'a55a1149796f9feded3a688ca29132eb' then ok := false; msg := msg || ' invoice_normalized=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.invoices_lock_trg()')));
  if v is distinct from '63f39183d475f2b04bcc7a9e9aaf251e' then ok := false; msg := msg || ' invoices_lock_trg=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.orders_invoice_status_trg()')));
  if v is distinct from '9ec5c212604145e284fa07d2fd2686f6' then ok := false; msg := msg || ' orders_invoice_status_trg=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_send_invoice(bigint,boolean,boolean)')));
  if v is distinct from '7ea29743e8e199c74ced1d62c730b27f' then ok := false; msg := msg || ' admin_send_invoice=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_create_invoice_from_order(bigint)')));
  if v is distinct from 'da51a0f8743daf809db544ed936d5418' then ok := false; msg := msg || ' admin_create_invoice_from_order=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.invoice_dispatch_claim(integer)')));
  if v is distinct from '098633014401dbd3cd76ff36f9cde16c' then ok := false; msg := msg || ' invoice_dispatch_claim=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._ovt_ok(text,text)')));
  if v is distinct from '030ecd33df47a695b734910f1bc4a5a9' then ok := false; msg := msg || ' _ovt_ok=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._upsert_company_customer(text,text,text,text,jsonb,boolean,text,text,text)')));
  if v is distinct from '931c228224ec02107e1e81e4d77a485b' then ok := false; msg := msg || ' _upsert_company_customer=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_create_booking(bigint,date,integer,text,text,text,boolean,text,text,text,jsonb,jsonb)')));
  if v is distinct from 'befba768679c4e414c4f3966ac4aa136' then ok := false; msg := msg || ' public_create_booking=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_create_treatment_booking(bigint,timestamp with time zone,integer,text,text,text,boolean,text,text,text,jsonb,text,jsonb)')));
  if v is distinct from 'd47cd6e939943cb2cfa385c0767bc2cb' then ok := false; msg := msg || ' public_create_treatment_booking=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_create_booking(bigint,date,integer,bigint,jsonb,text,boolean,text,timestamp with time zone,timestamp with time zone,numeric,text,jsonb,text)')));
  if v is distinct from '7ac1ba613b8db0ae6a4c2e6d9b3ce5c7' then ok := false; msg := msg || ' admin_create_booking=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._admin_create_legs(text,bigint,timestamp with time zone,timestamp with time zone,integer,bigint,jsonb,text,boolean,text,numeric,bigint,boolean,text,jsonb,bigint,text,boolean,text)')));
  if v is distinct from 'c86a86c12954b6d921564ee86f21b24f' then ok := false; msg := msg || ' _admin_create_legs=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_create_customer(jsonb)')));
  if v is distinct from '0a26150daf77b1bfeae0145e4ad7c25f' then ok := false; msg := msg || ' admin_create_customer=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._on_payment_paid(bigint)')));
  if v is distinct from 'de9084871640d213d10527a045157bf2' then ok := false; msg := msg || ' _on_payment_paid=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.email_outbox_claim(integer)')));
  if v is distinct from '2db9a1233a06e6293d0877f17de1ab72' then ok := false; msg := msg || ' email_outbox_claim=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_mark_voucher_claim_redeemed(bigint,numeric,text,text)')));
  if v is distinct from '525d1fa96fd7c37df4d7e502edf1bf71' then ok := false; msg := msg || ' admin_mark_voucher_claim_redeemed=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._vc_due(booking.orders,booking.voucher_claims)')));
  if v is distinct from 'bea9cd9a32eb273ee72caed0aedd1e2e' then ok := false; msg := msg || ' _vc_due=' || coalesce(v, 'puuttuu'); end if;
  if not exists (select 1 from pg_trigger t where t.tgrelid = 'booking.orders'::regclass and t.tgname = 'orders_invoice_draft'
                  and t.tgfoid = 'booking.orders_invoice_draft_trg()'::regprocedure and not t.tgisinternal) then
    ok := false; msg := msg || ' trigger orders_invoice_draft puuttuu';
  end if;
  if not ok then raise exception 'booking_175: funktioiden md5 ei vastaa tuotantoa eikä booking_175:ttä (%); mitään ei muutettu', msg; end if;
end $g$;

-- Viitenumeron etuliite (asetus). Olemassa olevaa arvoa ei korvata.
insert into booking.settings(key, value, description, is_public)
values ('invoice_reference_prefix', '"7310"'::jsonb,
        'Laskun viitenumeron etuliite (1–9 numeroa, ei alkunollaa). Viite = etuliite + laskun järjestysnumero + tarkiste (7-3-1), enintään 20 merkkiä. Muutos koskee vain tämän jälkeen lähetettäviä laskuja.',
        false)
on conflict (key) do nothing;

-- 1) booking._clean_company(jsonb)
CREATE OR REPLACE FUNCTION booking._clean_company(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare
  v_name text := btrim(coalesce(p ->> 'company_name', p ->> 'name', ''));
  v_bid text := booking._norm_business_id(p ->> 'business_id');
  v_street text := btrim(coalesce(p ->> 'street', p ->> 'address', ''));
  v_zip text := btrim(coalesce(p ->> 'zip', ''));
  v_city text := btrim(coalesce(p ->> 'city', ''));
  v_country text := upper(btrim(coalesce(nullif(p ->> 'country', ''), 'FI')));
  v_ei text := upper(regexp_replace(coalesce(p ->> 'einvoice_address', ''), '\s', '', 'g'));
  v_op text := upper(regexp_replace(coalesce(p ->> 'einvoice_operator', ''), '\s', '', 'g'));
  v_ref text := btrim(coalesce(p ->> 'reference', ''));
  v_req boolean := coalesce((p ->> 'require_einvoice')::boolean, false);
  v_method text := lower(btrim(coalesce(p ->> 'invoice_method', '')));
begin
  if p is null or jsonb_typeof(p) <> 'object' then perform booking._err('invalid_company', 'Anna yrityksen tiedot'); end if;
  -- booking_175: laskutustapa (verkkokauppa): einvoice = verkkolasku (OVT pakollinen), pdf = PDF-lasku sähköpostiin (OVT-tiedot jätetään pois).
  -- Ilman invoice_methodia: require_einvoice = true → einvoice (vanha kauppa), muuten ennallaan (laskutustapaa ei kirjata, OVT valinnainen; hallinta).
  if v_method = '' then v_method := case when v_req then 'einvoice' end; end if;
  if v_method is not null and v_method not in ('einvoice', 'pdf') then perform booking._err('invalid_invoice_method', 'Valitse laskutustapa: verkkolasku tai PDF'); end if;
  if v_method = 'pdf' then v_req := false; v_ei := ''; v_op := ''; end if;
  if v_method = 'einvoice' then v_req := true; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 200 then perform booking._err('invalid_company_name', 'Anna yrityksen nimi'); end if;
  if v_bid is null or not booking._business_id_ok(v_bid) then perform booking._err('invalid_business_id', 'Tarkista y-tunnus (muoto 1234567-8)'); end if;
  if char_length(v_street) < 2 or char_length(v_street) > 200 then perform booking._err('invalid_address', 'Anna yrityksen katuosoite'); end if;
  if v_country !~ '^[A-Z]{2}$' then perform booking._err('invalid_country', 'Tarkista maa (kaksikirjaiminen koodi, esim. FI)'); end if;
  if (v_country = 'FI' and v_zip !~ '^\d{5}$') or (v_country <> 'FI' and v_zip !~ '^[A-Za-z0-9 -]{2,12}$') then perform booking._err('invalid_zip', 'Tarkista postinumero'); end if;
  if char_length(v_city) < 2 or char_length(v_city) > 100 then perform booking._err('invalid_city', 'Anna postitoimipaikka'); end if;
  if v_ei <> '' and v_ei !~ '^[A-Z0-9]{6,35}$' then perform booking._err('invalid_einvoice_address', 'Tarkista verkkolaskuosoite / OVT-tunnus'); end if;
  if v_op <> '' and v_op !~ '^[A-Z0-9]{3,35}$' then perform booking._err('invalid_einvoice_operator', 'Tarkista verkkolaskuoperaattorin välittäjätunnus'); end if;
  if (v_ei = '') <> (v_op = '') then perform booking._err('einvoice_incomplete', 'Anna sekä verkkolaskuosoite että operaattorin välittäjätunnus (tai kumpikaan)'); end if;
  if v_req and (v_ei = '' or v_op = '') then perform booking._err('einvoice_incomplete', 'Verkkolasku: anna OVT-tunnus ja välittäjätunnus'); end if;
  if v_req and not booking._ovt_ok(v_ei, v_bid) then perform booking._err('invalid_einvoice_address', 'Tarkista verkkolaskuosoite. OVT-tunnus alkaa 0037 ja sisältää y-tunnuksen.'); end if;
  if char_length(v_ref) > 100 then perform booking._err('invalid_reference', 'Viite on liian pitkä (enintään 100 merkkiä)'); end if;
  return jsonb_build_object('company_name', v_name, 'business_id', v_bid, 'street', v_street, 'zip', v_zip, 'city', v_city, 'country', v_country,
                            'einvoice_address', nullif(v_ei, ''), 'einvoice_operator', nullif(v_op, ''), 'reference', nullif(v_ref, ''))
         || case when v_method is not null then jsonb_build_object('invoice_method', v_method) else '{}'::jsonb end;
end $function$;

-- 2) booking._stamp_order_billing(bigint,bigint,jsonb)
CREATE OR REPLACE FUNCTION booking._stamp_order_billing(p_order_id bigint, p_customer_id bigint, p_company jsonb DEFAULT NULL::jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c booking.customers; k booking.customer_kinds;
begin
  select * into c from booking.customers where id = p_customer_id;
  if not found then return; end if;
  select * into k from booking.customer_kinds where code = c.customer_kind;
  update booking.orders set
    customer_kind = c.customer_kind,
    billing = case when k.is_company then jsonb_build_object(
        'company', coalesce(p_company ->> 'company_name', c.company), 'business_id', coalesce(p_company ->> 'business_id', c.business_id),
        'street', coalesce(p_company ->> 'street', c.address), 'zip', coalesce(p_company ->> 'zip', c.zip), 'city', coalesce(p_company ->> 'city', c.city),
        'country', coalesce(p_company ->> 'country', c.country),
        -- booking_175: PDF-laskutapa → tilauksen laskutustiedoissa ei OVT-tietoja (ei asiakasrekisterin vanhoja)
        'einvoice_address', case when p_company ->> 'invoice_method' = 'pdf' then null else coalesce(p_company ->> 'einvoice_address', c.einvoice_address) end,
        'einvoice_operator', case when p_company ->> 'invoice_method' = 'pdf' then null else coalesce(p_company ->> 'einvoice_operator', c.einvoice_operator) end,
        'contact_name', c.name, 'contact_phone', c.phone, 'contact_email', c.email)
        || case when p_company ->> 'invoice_method' in ('einvoice', 'pdf') then jsonb_build_object('invoice_method', p_company ->> 'invoice_method') else '{}'::jsonb end end,
    invoice_reference = case when k.is_company then coalesce(nullif(p_company ->> 'reference', ''), c.invoice_reference) end
   where id = p_order_id;
end $function$;

-- 3) booking._invoice_allocate(bigint)
CREATE OR REPLACE FUNCTION booking._invoice_allocate(p_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare i booking.invoices; n int; v_no text; v_pre text; v_ref text;
begin
  select * into i from booking.invoices where id = p_id for update;
  if i.status <> 'draft' then perform booking._err('invoice_locked', 'Vain luonnos voidaan lähettää'); end if;
  if not exists (select 1 from booking.invoice_lines l where l.invoice_id = p_id) then
    perform booking._err('invalid_lines', 'Laskulla ei ole rivejä');
  end if;
  -- booking_175: viitenumero = etuliite (booking.settings invoice_reference_prefix, oletus 7310) + laskun järjestysnumero + tarkiste (7-3-1), enintään 20 merkkiä.
  -- Jo lähetettyjen laskujen viitteet eivät muutu (viite annetaan vain tässä, luonnoksen lähetyksessä).
  v_pre := booking._setting('invoice_reference_prefix', '"7310"'::jsonb) #>> '{}';
  if v_pre is null or v_pre !~ '^[1-9][0-9]{0,8}$' then
    perform booking._err('invalid_setting', 'Viitenumeron etuliite (invoice_reference_prefix) on virheellinen: 1–9 numeroa, ei alkunollaa');
  end if;
  n := booking._next_invoice_seq(i.series);
  v_no := i.series || lpad(n::text, 6, '0');
  v_ref := booking._fi_reference(v_pre || n::text);
  if char_length(v_ref) > 20 then perform booking._err('invalid_reference', 'Viitenumero on liian pitkä (enintään 20 merkkiä)'); end if;
  update booking.invoices set
    seq = n, invoice_no = v_no, reference_no = v_ref,
    seller_snapshot = booking._seller_invoice(),
    customer_snapshot = case when i.customer_snapshot_locked then i.customer_snapshot else booking._invoice_customer_json(i.customer_id) end,
    status = 'sent', sent_at = now(), locked_at = now()
  where id = p_id;
end $function$;

-- 4) booking.orders_invoice_draft_trg()
CREATE OR REPLACE FUNCTION booking.orders_invoice_draft_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_inv bigint;
begin
  if new.payment_status = 'invoiced' and (tg_op = 'INSERT' or old.payment_status is distinct from 'invoiced') then
    begin
      v_inv := booking._ensure_draft_invoice(new.id);
    exception when others then
      raise warning 'orders_invoice_draft: tilaus % luonnoslasku epäonnistui: %', new.id, sqlerrm;
      insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
      values (auth.uid(), booking._jwt_role(), 'orders', new.id::text, 'invoice_draft_failed',
              jsonb_build_object('order_id', new.id, 'sqlstate', sqlstate, 'error', left(sqlerrm, 500)));
    end;
    -- booking_175: verkkokaupan yritystilaus, laskutustapa verkkolasku → lasku lähetetään heti verkkolaskujonoon
    -- (sama polku kuin hallinnan "Lähetä verkkolasku": _invoice_allocate + _invoice_queue_dispatch; invoice_dispatch_mode ratkaisee queued / dry_run).
    -- Laskun asiakaskuvaan tilauksella annettu OVT + välittäjä (vain tämä lasku, customer_snapshot_locked). Rekisteriä ei muuteta.
    -- PDF-laskutapa ja hallinnan / muiden kanavien tilaukset jäävät luonnokseksi (lähetysnappi). Virhe ei estä varausta: lasku jää luonnokseksi + audit_log.
    if v_inv is not null and new.source_channel = 'web' and new.status = 'confirmed' and new.billing ->> 'invoice_method' = 'einvoice' then
      begin
        if exists (select 1 from booking.invoices where id = v_inv and kind = 'debit' and status = 'draft') then
          update booking.invoices set
            customer_snapshot = customer_snapshot || jsonb_build_object('einvoice_address', upper(new.billing ->> 'einvoice_address'), 'einvoice_operator', upper(new.billing ->> 'einvoice_operator')),
            customer_snapshot_locked = true
           where id = v_inv and nullif(new.billing ->> 'einvoice_address', '') is not null and nullif(new.billing ->> 'einvoice_operator', '') is not null;
          perform booking._invoice_allocate(v_inv);
          perform booking._invoice_queue_dispatch(v_inv);
        end if;
      exception when others then
        raise warning 'orders_invoice_draft: tilaus % verkkolaskun automaattinen lähetys epäonnistui: %', new.id, sqlerrm;
        insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
        values (auth.uid(), booking._jwt_role(), 'orders', new.id::text, 'invoice_auto_send_failed',
                jsonb_build_object('order_id', new.id, 'invoice_id', v_inv, 'sqlstate', sqlstate, 'error', left(sqlerrm, 500)));
      end;
    end if;
  end if;
  return null;
end $function$;

do $v$
begin
  if md5(pg_get_functiondef('booking._clean_company(jsonb)'::regprocedure)) <> '53fa5a8a98e98aeb4a97000d2f6b37ec' then raise exception 'booking_175: _clean_company md5 ei vastaa odotettua'; end if;
  if md5(pg_get_functiondef('booking._stamp_order_billing(bigint,bigint,jsonb)'::regprocedure)) <> '693f24abfe0dddfbf4a2e345e1596e73' then raise exception 'booking_175: _stamp_order_billing md5 ei vastaa odotettua'; end if;
  if md5(pg_get_functiondef('booking._invoice_allocate(bigint)'::regprocedure)) <> '46a3326812f896077fc2614ba783ff3d' then raise exception 'booking_175: _invoice_allocate md5 ei vastaa odotettua'; end if;
  if md5(pg_get_functiondef('booking.orders_invoice_draft_trg()'::regprocedure)) <> 'df1d0ebf036380495f6730d1fa93de7a' then raise exception 'booking_175: orders_invoice_draft_trg md5 ei vastaa odotettua'; end if;
end $v$;
