-- Rollback booking_229. Palauttaa botin neljän argumentin svc_mark_voucher_claim_redeemed
-- (booking_176), poistaa kuusipaikkaisen _vc_redeemin ja value_card-sarakkeen,
-- ja palauttaa email_outbox_claim_base_215:n voucher_difference-lohkon ilman value_cardia.
-- Viisipaikkainen _vc_redeem (booking_188) ei muuttunut, joten sitä ei kirjoiteta uudelleen.

set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $patch$
declare
  src text;
  neu text;
  old text := $o$jsonb_build_object('total', e.payload -> 'total', 'voucher_value', e.payload -> 'voucher_value', 'difference', e.payload -> 'difference')$o$;
  nxt text := $n$jsonb_build_object('total', e.payload -> 'total', 'voucher_value', e.payload -> 'voucher_value', 'difference', e.payload -> 'difference', 'value_card', coalesce((e.payload ->> 'value_card')::boolean, false))$n$;
begin
  if to_regprocedure('booking.email_outbox_claim_base_215(integer)') is null then
    return;
  end if;
  src := pg_get_functiondef('booking.email_outbox_claim_base_215(integer)'::regprocedure);
  if position(old in src) > 0 and position(nxt in src) = 0 then
    return;
  end if;
  if position(nxt in src) = 0 then
    raise exception 'booking_229 rollback: value_card-lohkoa ei löydy email_outbox_claim_base_215:stä';
  end if;
  neu := replace(src, nxt, old);
  execute neu;
end $patch$;

drop function if exists booking.svc_mark_voucher_claim_redeemed(bigint, numeric, text, text, boolean);
drop function if exists booking._vc_redeem(bigint, numeric, text, text, text, boolean);

CREATE OR REPLACE FUNCTION booking.svc_mark_voucher_claim_redeemed(p_id bigint, p_amount numeric DEFAULT NULL::numeric, p_partner_ref text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  -- booking_176: sama arvon tarkistus ja erotuksen maksulinkki kuin henkilökunnalla
  return booking._vc_redeem(p_id, p_amount, p_partner_ref, p_note, 'bot');
end $function$;

revoke all on function booking.svc_mark_voucher_claim_redeemed(bigint, numeric, text, text) from public, anon, authenticated;
grant execute on function booking.svc_mark_voucher_claim_redeemed(bigint, numeric, text, text) to service_role;

alter table booking.voucher_claims drop column if exists value_card;
