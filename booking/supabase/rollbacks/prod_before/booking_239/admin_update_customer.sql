-- PROD-määrittely ennen booking_239:ää (md5 sama DEV/PROD, 3.11.2026)
CREATE OR REPLACE FUNCTION booking.admin_update_customer(p_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  allowed text[] := array['name','email','phone','company','address','zip','city','country','language','notes','marketing_consent',
                          'customer_kind','business_id','einvoice_address','einvoice_operator','invoice_reference'];
  k text; v_consent boolean; c booking.customers; v_bid text; v_ei text; v_op text; v_kind text; v_email text;
begin
  perform booking._require_permission('customers.manage');
  select * into c from booking.customers where id = p_id;
  if not found then perform booking._err('not_found', 'Asiakasta ei löydy'); end if;
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (allowed)) then perform booking._err('unknown_field', 'Kenttää ei saa muokata: ' || k); end if;
  end loop;
  if p_patch ? 'name' and char_length(btrim(coalesce(p_patch ->> 'name', ''))) < 1 then perform booking._err('invalid_name', 'Nimi ei voi olla tyhjä'); end if;
  if p_patch ? 'email' then
    v_email := nullif(btrim(coalesce(p_patch ->> 'email', '')), '');
    if v_email is not null and not booking._valid_email(v_email) then perform booking._err('invalid_email', 'Tarkista sähköpostiosoite'); end if;
  end if;
  if p_patch ? 'phone' and nullif(btrim(coalesce(p_patch ->> 'phone', '')), '') is not null and btrim(p_patch ->> 'phone') !~ '^[0-9+()\- ]{6,30}$' then
    perform booking._err('invalid_phone', 'Tarkista puhelinnumero');
  end if;
  if p_patch ? 'customer_kind' then
    v_kind := lower(btrim(coalesce(p_patch ->> 'customer_kind', '')));
    if not exists (select 1 from booking.customer_kinds where code = v_kind and active) then perform booking._err('invalid_customer_kind', 'Asiakastyyppi ei ole sallittu'); end if;
  end if;
  if p_patch ? 'business_id' then
    v_bid := booking._norm_business_id(p_patch ->> 'business_id');
    if v_bid is not null and not booking._business_id_ok(v_bid) then perform booking._err('invalid_business_id', 'Tarkista y-tunnus (muoto 1234567-8)'); end if;
  end if;
  v_ei := case when p_patch ? 'einvoice_address' then upper(regexp_replace(coalesce(p_patch ->> 'einvoice_address', ''), '\s', '', 'g')) else coalesce(c.einvoice_address, '') end;
  v_op := case when p_patch ? 'einvoice_operator' then upper(regexp_replace(coalesce(p_patch ->> 'einvoice_operator', ''), '\s', '', 'g')) else coalesce(c.einvoice_operator, '') end;
  if v_ei <> '' and v_ei !~ '^[A-Z0-9]{6,35}$' then perform booking._err('invalid_einvoice_address', 'Tarkista verkkolaskuosoite / OVT-tunnus'); end if;
  if v_op <> '' and v_op !~ '^[A-Z0-9]{3,35}$' then perform booking._err('invalid_einvoice_operator', 'Tarkista verkkolaskuoperaattorin välittäjätunnus'); end if;
  if (v_ei = '') <> (v_op = '') then perform booking._err('einvoice_incomplete', 'Anna sekä verkkolaskuosoite että operaattorin välittäjätunnus (tai kumpikaan)'); end if;
  if p_patch ? 'marketing_consent' then v_consent := (p_patch ->> 'marketing_consent')::boolean; end if;
  begin
    update booking.customers set
      name = case when p_patch ? 'name' then btrim(p_patch ->> 'name') else name end,
      email = case when p_patch ? 'email' then v_email else email end,
      phone = case when p_patch ? 'phone' then nullif(btrim(p_patch ->> 'phone'), '') else phone end,
      company = case when p_patch ? 'company' then nullif(btrim(p_patch ->> 'company'), '') else company end,
      address = case when p_patch ? 'address' then p_patch ->> 'address' else address end,
      zip = case when p_patch ? 'zip' then p_patch ->> 'zip' else zip end,
      city = case when p_patch ? 'city' then p_patch ->> 'city' else city end,
      country = case when p_patch ? 'country' then p_patch ->> 'country' else country end,
      language = case when p_patch ? 'language' then p_patch ->> 'language' else language end,
      notes = case when p_patch ? 'notes' then p_patch ->> 'notes' else notes end,
      customer_kind = case when p_patch ? 'customer_kind' then v_kind else customer_kind end,
      business_id = case when p_patch ? 'business_id' then v_bid else business_id end,
      einvoice_address = case when p_patch ? 'einvoice_address' then nullif(v_ei, '') else einvoice_address end,
      einvoice_operator = case when p_patch ? 'einvoice_operator' then nullif(v_op, '') else einvoice_operator end,
      invoice_reference = case when p_patch ? 'invoice_reference' then nullif(btrim(coalesce(p_patch ->> 'invoice_reference', '')), '') else invoice_reference end,
      marketing_consent = coalesce(v_consent, marketing_consent),
      marketing_consent_at = case when v_consent is distinct from marketing_consent and v_consent is not null then now() else marketing_consent_at end,
      marketing_consent_source = case when v_consent is distinct from marketing_consent and v_consent is not null then 'admin' else marketing_consent_source end,
      marketing_unsubscribed_at = case when v_consent is false and marketing_consent then now() else marketing_unsubscribed_at end
     where id = p_id;
  exception when check_violation then
    perform booking._err('invalid_company', 'Yritysasiakkaalla pitää olla yrityksen nimi ja kelvollinen y-tunnus');
  end;
  return jsonb_build_object('ok', true);
end $function$;
