-- booking_243 rollback: palauta admin_create_booking ja poista payment_methods.payment_link.
-- Älä aja PRODissa jos payment_link-rivejä on jo luotu.

set local lock_timeout = '5s';

CREATE OR REPLACE FUNCTION booking.admin_create_booking(p_rule_id bigint, p_date date, p_persons integer, p_customer_id bigint DEFAULT NULL::bigint, p_customer jsonb DEFAULT NULL::jsonb, p_payment_method text DEFAULT 'pay_later'::text, p_paid boolean DEFAULT false, p_note text DEFAULT NULL::text, p_start timestamp with time zone DEFAULT NULL::timestamp with time zone, p_end timestamp with time zone DEFAULT NULL::timestamp with time zone, p_price numeric DEFAULT NULL::numeric, p_channel text DEFAULT 'admin'::text, p_addons jsonb DEFAULT NULL::jsonb, p_invoice_reference text DEFAULT NULL::text, p_discount_code text DEFAULT NULL::text, p_gift_card_code text DEFAULT NULL::text, p_remainder_method text DEFAULT NULL::text, p_allow_overbook boolean DEFAULT false, p_allow_off_schedule boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_cust bigint := p_customer_id; v_res jsonb; v_email text; v_order bigint; v_pm booking.payment_methods;
  v_kind text; v_is_company boolean; v_company jsonb; v_add numeric; v_total numeric; v_consent boolean; v_ref text := nullif(btrim(coalesce(p_invoice_reference, '')), '');
  v_method text := p_payment_method; v_paid boolean := coalesce(p_paid, false); v_gc text := nullif(btrim(coalesce(p_gift_card_code, '')), '');
  v_extra jsonb := '{}'::jsonb; v_disc jsonb;
begin
  perform booking._require_permission('bookings.manage');
  perform booking._arm_staff_overrides(p_allow_overbook, p_allow_off_schedule, p_start, p_end);
  if v_method = 'gift_card' and v_gc is null then perform booking._err('gift_card_code_required', 'Anna lahjakortin koodi.'); end if;
  if v_gc is not null then v_method := 'pay_later'; v_paid := false; end if;
  select * into v_pm from booking.payment_methods where code = v_method and active;
  if not found then perform booking._err('invalid_payment_method', 'Maksutapa ei ole käytössä'); end if;
  if p_channel not in ('admin','phone','email','walk_in','other') then perform booking._err('invalid_channel', 'Virheellinen lähdekanava'); end if;
  if p_price is not null and p_price < 0 then perform booking._err('invalid_price', 'Virheellinen hinta'); end if;
  if v_ref is not null and char_length(v_ref) > 100 then perform booking._err('invalid_reference', 'Viite on liian pitkä (enintään 100 merkkiä)'); end if;
  if v_cust is null then
    if p_customer is null or char_length(btrim(coalesce(p_customer ->> 'name', ''))) < 2 then
      perform booking._err('customer_required', 'Valitse asiakas tai anna nimi');
    end if;
    v_kind := lower(btrim(coalesce(nullif(p_customer ->> 'kind', ''), 'private')));
    select ck.is_company into v_is_company from booking.customer_kinds ck where ck.code = v_kind and ck.active;
    if v_is_company is null then perform booking._err('invalid_customer_kind', 'Valitse asiakastyyppi (yksityinen / yritys)'); end if;
    v_email := lower(nullif(btrim(coalesce(p_customer ->> 'email', '')), ''));
    if v_email is not null and not booking._valid_email(v_email) then perform booking._err('invalid_email', 'Tarkista sähköpostiosoite'); end if;
    v_consent := coalesce((p_customer ->> 'marketing_consent')::boolean, false);
    if v_is_company then
      v_company := booking._clean_company(p_customer -> 'company_details');
      v_cust := booking._upsert_company_customer(v_kind, btrim(p_customer ->> 'name'), v_email, nullif(btrim(coalesce(p_customer ->> 'phone', '')), ''),
                  v_company, v_consent, 'admin', coalesce(p_customer ->> 'language', 'fi'));
    elsif v_email is not null then
      v_cust := booking._upsert_customer(btrim(p_customer ->> 'name'), v_email, nullif(btrim(coalesce(p_customer ->> 'phone', '')), ''),
                 v_consent, 'admin', coalesce(p_customer ->> 'language', 'fi'));
    else
      insert into booking.customers(name, phone, company, language, marketing_consent, marketing_consent_at, marketing_consent_source)
      values (btrim(p_customer ->> 'name'), nullif(btrim(coalesce(p_customer ->> 'phone', '')), ''), nullif(btrim(coalesce(p_customer ->> 'company', '')), ''),
              coalesce(p_customer ->> 'language', 'fi'), v_consent,
              case when v_consent then now() end, case when v_consent then 'admin' end)
      returning id into v_cust;
    end if;
  elsif not exists (select 1 from booking.customers where id = v_cust) then
    perform booking._err('customer_not_found', 'Asiakasta ei löydy');
  end if;

  v_res := booking._create_booking_core(p_rule_id, p_date, p_persons, v_cust, p_channel, auth.uid(), 'fi', p_note,
                                        'confirmed', null, false, p_start, p_end, p_price);
  v_order := (v_res ->> 'order_id')::bigint;
  perform booking._stamp_order_billing(v_order, v_cust, v_company);
  if v_ref is not null then update booking.orders set invoice_reference = v_ref where id = v_order and customer_kind <> 'private'; end if;
  v_add := booking._attach_addons((v_res ->> 'reservation_id')::bigint, p_addons);
  v_disc := booking._apply_admin_discount(v_order, p_discount_code);
  v_total := (v_disc ->> 'total')::numeric;
  v_extra := v_disc;
  if coalesce((v_disc ->> 'payment_inserted')::boolean, false) then
    null;
  elsif v_gc is not null then
    v_extra := v_disc || booking._apply_admin_gift(v_order, v_gc, p_remainder_method, p_paid);
    v_total := coalesce((v_extra ->> 'total')::numeric, v_total);
  else
    if v_total > 0.004 then
      insert into booking.payments(order_id, method, provider, status, amount, paid_at, created_by)
      values (v_order, v_method, 'manual', case when v_paid then 'paid' else 'pending' end, v_total,
              case when v_paid then now() end, auth.uid());
    end if;
    update booking.orders set payment_status = case when v_paid or v_total <= 0.004 then 'paid' else 'unpaid' end where id = v_order;
  end if;
  return v_res - 'public_token' || jsonb_build_object('customer_id', v_cust, 'total', v_total, 'addons_total', v_add) || v_extra;
end $function$;;

delete from booking.payment_methods where code = 'payment_link';
