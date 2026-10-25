-- booking_175 ROLLBACK: palauttaa tuotannon määrittelyt tavu tavulta (pg_get_functiondef, luettu sxbofnuisemspgquoxyv 25.10.2026) ja poistaa asetukset invoice_reference_prefix ja invoice_einvoice_auto_send.
-- Aja yhdessä transaktiossa. Jo lähetettyjen laskujen viitenumerot, jonossa olevat verkkolaskut, jonotetut PDF-laskusähköpostit ja tilausten billing.invoice_method jäävät ennalleen
-- (vanha koodi ei lue billing.invoice_methodia; uudet viitteet palaavat muotoon järjestysnumero + tarkiste).
--   booking._clean_company(jsonb): 53fa5a8a98e98aeb4a97000d2f6b37ec -> 4e8d9dddda117bdc208f3b1bb281f97a
--   booking._stamp_order_billing(bigint,bigint,jsonb): 693f24abfe0dddfbf4a2e345e1596e73 -> 709b28b59f549df7be252b2942e77256
--   booking._invoice_allocate(bigint): 46a3326812f896077fc2614ba783ff3d -> ad7dbbd30a6b3362bf4011d4e8ff296e
--   booking.orders_invoice_draft_trg(): a48fe50340cff5f6e9709ad46055ecb9 -> a9a389358507c2dca37acbacdcfd3d61
set local lock_timeout = '5s';

do $g$
declare v text; ok boolean := true; msg text := '';
begin
  v := md5(pg_get_functiondef('booking._clean_company(jsonb)'::regprocedure));
  if v not in ('53fa5a8a98e98aeb4a97000d2f6b37ec', '4e8d9dddda117bdc208f3b1bb281f97a') then ok := false; msg := msg || ' _clean_company=' || v; end if;
  v := md5(pg_get_functiondef('booking._stamp_order_billing(bigint,bigint,jsonb)'::regprocedure));
  if v not in ('693f24abfe0dddfbf4a2e345e1596e73', '709b28b59f549df7be252b2942e77256') then ok := false; msg := msg || ' _stamp_order_billing=' || v; end if;
  v := md5(pg_get_functiondef('booking._invoice_allocate(bigint)'::regprocedure));
  if v not in ('46a3326812f896077fc2614ba783ff3d', 'ad7dbbd30a6b3362bf4011d4e8ff296e') then ok := false; msg := msg || ' _invoice_allocate=' || v; end if;
  v := md5(pg_get_functiondef('booking.orders_invoice_draft_trg()'::regprocedure));
  if v not in ('a48fe50340cff5f6e9709ad46055ecb9', 'a9a389358507c2dca37acbacdcfd3d61') then ok := false; msg := msg || ' orders_invoice_draft_trg=' || v; end if;
  if not ok then raise exception 'booking_175 rollback: md5 ei vastaa booking_175:ttä eikä tuotannon alkuperäistä (%); mitään ei muutettu', msg; end if;
end $g$;

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
begin
  if p is null or jsonb_typeof(p) <> 'object' then perform booking._err('invalid_company', 'Anna yrityksen tiedot'); end if;
  if char_length(v_name) < 2 or char_length(v_name) > 200 then perform booking._err('invalid_company_name', 'Anna yrityksen nimi'); end if;
  if v_bid is null or not booking._business_id_ok(v_bid) then perform booking._err('invalid_business_id', 'Tarkista y-tunnus (muoto 1234567-8)'); end if;
  if char_length(v_street) < 2 or char_length(v_street) > 200 then perform booking._err('invalid_address', 'Anna yrityksen katuosoite'); end if;
  if v_country !~ '^[A-Z]{2}$' then perform booking._err('invalid_country', 'Tarkista maa (kaksikirjaiminen koodi, esim. FI)'); end if;
  if (v_country = 'FI' and v_zip !~ '^\d{5}$') or (v_country <> 'FI' and v_zip !~ '^[A-Za-z0-9 -]{2,12}$') then perform booking._err('invalid_zip', 'Tarkista postinumero'); end if;
  if char_length(v_city) < 2 or char_length(v_city) > 100 then perform booking._err('invalid_city', 'Anna postitoimipaikka'); end if;
  if v_ei <> '' and v_ei !~ '^[A-Z0-9]{6,35}$' then perform booking._err('invalid_einvoice_address', 'Tarkista verkkolaskuosoite / OVT-tunnus'); end if;
  if v_op <> '' and v_op !~ '^[A-Z0-9]{3,35}$' then perform booking._err('invalid_einvoice_operator', 'Tarkista verkkolaskuoperaattorin välittäjätunnus'); end if;
  if (v_ei = '') <> (v_op = '') then perform booking._err('einvoice_incomplete', 'Anna sekä verkkolaskuosoite että operaattorin välittäjätunnus (tai kumpikaan)'); end if;
  if v_req and (v_ei = '' or v_op = '') then perform booking._err('einvoice_incomplete', 'Yritysasiakas maksaa verkkolaskulla: anna OVT-tunnus ja välittäjätunnus'); end if;
  if v_req and not booking._ovt_ok(v_ei, v_bid) then perform booking._err('invalid_einvoice_address', 'Tarkista verkkolaskuosoite. OVT-tunnus alkaa 0037 ja sisältää y-tunnuksen.'); end if;
  if char_length(v_ref) > 100 then perform booking._err('invalid_reference', 'Viite on liian pitkä (enintään 100 merkkiä)'); end if;
  return jsonb_build_object('company_name', v_name, 'business_id', v_bid, 'street', v_street, 'zip', v_zip, 'city', v_city, 'country', v_country,
                            'einvoice_address', nullif(v_ei, ''), 'einvoice_operator', nullif(v_op, ''), 'reference', nullif(v_ref, ''));
end $function$;

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
        'country', coalesce(p_company ->> 'country', c.country), 'einvoice_address', coalesce(p_company ->> 'einvoice_address', c.einvoice_address),
        'einvoice_operator', coalesce(p_company ->> 'einvoice_operator', c.einvoice_operator),
        'contact_name', c.name, 'contact_phone', c.phone, 'contact_email', c.email) end,
    invoice_reference = case when k.is_company then coalesce(nullif(p_company ->> 'reference', ''), c.invoice_reference) end
   where id = p_order_id;
end $function$;

CREATE OR REPLACE FUNCTION booking._invoice_allocate(p_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare i booking.invoices; n int; v_no text;
begin
  select * into i from booking.invoices where id = p_id for update;
  if i.status <> 'draft' then perform booking._err('invoice_locked', 'Vain luonnos voidaan lähettää'); end if;
  if not exists (select 1 from booking.invoice_lines l where l.invoice_id = p_id) then
    perform booking._err('invalid_lines', 'Laskulla ei ole rivejä');
  end if;
  n := booking._next_invoice_seq(i.series);
  v_no := i.series || lpad(n::text, 6, '0');
  update booking.invoices set
    seq = n, invoice_no = v_no, reference_no = booking._fi_reference(lpad(n::text, 3, '0')),
    seller_snapshot = booking._seller_invoice(),
    customer_snapshot = case when i.customer_snapshot_locked then i.customer_snapshot else booking._invoice_customer_json(i.customer_id) end,
    status = 'sent', sent_at = now(), locked_at = now()
  where id = p_id;
end $function$;

CREATE OR REPLACE FUNCTION booking.orders_invoice_draft_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if new.payment_status = 'invoiced' and (tg_op = 'INSERT' or old.payment_status is distinct from 'invoiced') then
    begin
      perform booking._ensure_draft_invoice(new.id);
    exception when others then
      raise warning 'orders_invoice_draft: tilaus % luonnoslasku epäonnistui: %', new.id, sqlerrm;
      insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, new_data)
      values (auth.uid(), booking._jwt_role(), 'orders', new.id::text, 'invoice_draft_failed',
              jsonb_build_object('order_id', new.id, 'sqlstate', sqlstate, 'error', left(sqlerrm, 500)));
    end;
  end if;
  return null;
end $function$;

delete from booking.settings where key in ('invoice_reference_prefix', 'invoice_einvoice_auto_send');

do $v$
begin
  if md5(pg_get_functiondef('booking._clean_company(jsonb)'::regprocedure)) <> '4e8d9dddda117bdc208f3b1bb281f97a' then raise exception 'booking_175 rollback: _clean_company ei palautunut tuotannon määrittelyyn'; end if;
  if md5(pg_get_functiondef('booking._stamp_order_billing(bigint,bigint,jsonb)'::regprocedure)) <> '709b28b59f549df7be252b2942e77256' then raise exception 'booking_175 rollback: _stamp_order_billing ei palautunut tuotannon määrittelyyn'; end if;
  if md5(pg_get_functiondef('booking._invoice_allocate(bigint)'::regprocedure)) <> 'ad7dbbd30a6b3362bf4011d4e8ff296e' then raise exception 'booking_175 rollback: _invoice_allocate ei palautunut tuotannon määrittelyyn'; end if;
  if md5(pg_get_functiondef('booking.orders_invoice_draft_trg()'::regprocedure)) <> 'a9a389358507c2dca37acbacdcfd3d61' then raise exception 'booking_175 rollback: orders_invoice_draft_trg ei palautunut tuotannon määrittelyyn'; end if;
end $v$;
