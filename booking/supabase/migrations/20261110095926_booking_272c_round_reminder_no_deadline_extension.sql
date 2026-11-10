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
         and not exists (select 1 from booking.shift_offer_message_meta rm where rm.message_id = m.id and rm.subkind = 'round_reminder')
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
  -- booking_272: kierrosmuistutus ei jatka takarajaa (muistutuksessa kerrottu aika pysyy voimassa)
  if exists (select 1 from booking.shift_offer_message_meta rm where rm.message_id = p_message and rm.subkind = 'round_reminder') then
    return null;
  end if;
  update public.shift_offer_messages set deadline_extended_at = now()
   where id = p_message and deadline_extended_at is null and recipient_id is not null and kind in ('offer','reminder')
  returning recipient_id into v_r;
  if v_r is null then return null; end if;
  return booking.shift_offer_extend_deadline(v_r, coalesce(p_at, now()));
end $function$;
