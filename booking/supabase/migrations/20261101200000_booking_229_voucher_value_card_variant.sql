-- booking_229_voucher_value_card_variant
-- Kumppanilahjakortin erotuksen maksulinkki saa toisen introtekstin, kun asiakaspalvelubotti
-- lunastaa yli vuoden vanhan kortin arvolahjakorttina.
--
-- 1) voucher_claims.value_card (boolean, oletus false) jää audit-jäljeksi.
-- 2) svc_mark_voucher_claim_redeemed saa valinnaisen p_value_card boolean default false.
--    Vanha neljän argumentin funktio pudotetaan ja luodaan uudelleen viidennellä argumentilla,
--    jotta nimetty ja sijaintikutsu ilman parametria toimii edelleen (service_role).
--    booking._vc_redeem(bigint,numeric,text,text,text) jätetään ennalleen (md5 booking_188):
--    henkilökunta ja resolve-polku eivät välitä lippua. Uusi kuusipaikkainen _vc_redeem
--    kirjoittaa lipun sähköpostin payloadiin ('value_card') ja pyyntöriville.
-- 3) email_outbox_claim_base_215 kopioi value_cardin voucher_difference-lohkoon.
--
-- Kutsu:
--   select booking.svc_mark_voucher_claim_redeemed(p_id, p_amount, p_partner_ref, p_note);
--   select booking.svc_mark_voucher_claim_redeemed(p_id, p_amount, p_partner_ref, p_note, true);
--   select booking.svc_mark_voucher_claim_redeemed(p_id := 123, p_amount := 50, p_value_card := true);
-- Ilman p_value_card arvo on false (yleinen erotus). true = arvolahjakortin intro.
--
-- Rollback: rollbacks/20261101200000_booking_229_ROLLBACK.sql
-- Ei koske site_texts-rivejä (voucher_intro on jo v2 kannassa; uusi avain tuodaan pending-import-117:llä).

set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table booking.voucher_claims
  add column if not exists value_card boolean not null default false;

comment on column booking.voucher_claims.value_card is
  'booking_229: botti lunasti kortin arvolahjakorttina (yli vuoden vanha). false = yleinen erotus.';

-- Kuusipaikkainen lunastus. Viidettä argumenttia ei oleteta, jotta vanha _vc_redeem(5) pysyy yksiselitteisenä.
create or replace function booking._vc_redeem(p_id bigint, p_amount numeric, p_partner_ref text, p_note text, p_by text, p_value_card boolean)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare c booking.voucher_claims; o booking.orders; v jsonb; v_due numeric; v_link jsonb; v_pid bigint; v_diff numeric; v_mail boolean := false;
  v_card boolean := coalesce(p_value_card, false);
begin
  if p_amount is not null then
    if p_amount <= 0 or p_amount <> round(p_amount, 2) then perform booking._err('invalid_amount', 'Lahjakortin arvon pitää olla yli 0 € (enintään 2 desimaalia)'); end if;
    select * into c from booking.voucher_claims where id = p_id for update;
    if found and c.status in ('open', 'processing', 'problem') then
      select * into o from booking.orders where id = c.order_id for update;
      if found and o.status in ('pending', 'confirmed') and o.external_source is null then
        v_due := booking._vc_due(o, c);
        if p_amount > v_due then
          perform booking._err('voucher_exceeds_total', format('Lahjakortin arvo %s € ylittää maksettavan summan %s €', p_amount, v_due));
        end if;
      end if;
    end if;
  end if;
  v := booking._vc_mark_redeemed(p_id, p_amount, p_partner_ref, p_note, p_by);
  if not coalesce((v ->> 'already')::boolean, false) then
    update booking.voucher_claims set value_card = v_card where id = p_id;
  end if;
  -- booking_174 / booking_229: arvo pienempi kuin maksettava → erotus maksulinkkinä. value_card valitsee introtekstin.
  if v_due is not null and p_amount < v_due and not coalesce((v ->> 'already')::boolean, false) and (v ->> 'payment_id') is not null then
    select * into o from booking.orders where id = o.id;
    v_link := booking._create_link_payment(o.id, null::integer, 'Kumppanilahjakortin erotus, pyyntö #' || p_id);
    v_pid := (v_link ->> 'payment_id')::bigint;
    v_diff := (v_link ->> 'amount')::numeric;
    v_mail := booking._enqueue_email('payment_link', o.id, null, v_pid, 'payment_link:voucher_difference:' || p_id || ':' || v_pid,
                jsonb_build_object('variant', 'voucher_difference', 'claim_id', p_id, 'voucher_value', (v ->> 'amount')::numeric, 'difference', v_diff,
                                   'total', (v ->> 'amount')::numeric + v_diff, 'value_card', v_card));
    insert into booking.vc_difference_payments(order_id, claim_id, payment_id) values (o.id, p_id, v_pid) on conflict (payment_id) do nothing;
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
    values (auth.uid(), booking._jwt_role(), 'booking.voucher_claims', p_id::text, 'VOUCHER_DIFFERENCE_LINK', null,
            jsonb_build_object('voucher_value', (v ->> 'amount')::numeric, 'due', v_due, 'difference', v_diff, 'link_payment_id', v_pid, 'email_queued', v_mail, 'by', p_by, 'value_card', v_card));
  end if;
  return v || jsonb_build_object('voucher_value', case when (v ->> 'already')::boolean then null else (v ->> 'amount')::numeric end, 'due', v_due,
    'difference', v_diff, 'payment_link', case when v_pid is not null then booking._link_json(v_pid) || jsonb_build_object('online_payment_enabled', booking._montonio_online()) end,
    'email_queued', v_mail, 'value_card', (select vc.value_card from booking.voucher_claims vc where vc.id = p_id));
end $function$;

revoke all on function booking._vc_redeem(bigint, numeric, text, text, text, boolean) from public, anon, authenticated, service_role;

comment on function booking._vc_redeem(bigint, numeric, text, text, text, boolean) is
  'booking_229: sama kuin _vc_redeem(5) plus p_value_card. Sisäinen. service_role ei saa kutsua suoraan.';

-- Vanha neljän argumentin RPC pois, jotta viides oletus ei ole moniselitteinen.
drop function if exists booking.svc_mark_voucher_claim_redeemed(bigint, numeric, text, text);

create or replace function booking.svc_mark_voucher_claim_redeemed(
  p_id bigint,
  p_amount numeric default null,
  p_partner_ref text default null,
  p_note text default null,
  p_value_card boolean default false
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  -- booking_229: p_value_card oletus false. true vain kun botti tietää kortin muuttuneen arvolahjakortiksi.
  return booking._vc_redeem(p_id, p_amount, p_partner_ref, p_note, 'bot', coalesce(p_value_card, false));
end $function$;

revoke all on function booking.svc_mark_voucher_claim_redeemed(bigint, numeric, text, text, boolean) from public, anon, authenticated;
grant execute on function booking.svc_mark_voucher_claim_redeemed(bigint, numeric, text, text, boolean) to service_role;

comment on function booking.svc_mark_voucher_claim_redeemed(bigint, numeric, text, text, boolean) is
  'booking_229: botin lunastus. p_value_card boolean default false. service_role.';

-- email_outbox_claim_base_215: voucher_difference-lohkoon value_card (puuttuva payload = false).
do $patch$
declare
  src text;
  neu text;
  old text := $o$jsonb_build_object('total', e.payload -> 'total', 'voucher_value', e.payload -> 'voucher_value', 'difference', e.payload -> 'difference')$o$;
  nxt text := $n$jsonb_build_object('total', e.payload -> 'total', 'voucher_value', e.payload -> 'voucher_value', 'difference', e.payload -> 'difference', 'value_card', coalesce((e.payload ->> 'value_card')::boolean, false))$n$;
begin
  src := pg_get_functiondef('booking.email_outbox_claim_base_215(integer)'::regprocedure);
  if src is null then
    raise exception 'booking_229: email_outbox_claim_base_215 puuttuu';
  end if;
  if position(nxt in src) > 0 then
    return;
  end if;
  if position(old in src) = 0 then
    raise exception 'booking_229: voucher_difference-lohkoa ei löydy email_outbox_claim_base_215:stä';
  end if;
  neu := replace(src, old, nxt);
  execute neu;
end $patch$;

comment on function booking.email_outbox_claim_base_215(integer) is
  'booking_215 + booking_229: voucher_difference sisältää total, voucher_value, difference ja value_card.';
