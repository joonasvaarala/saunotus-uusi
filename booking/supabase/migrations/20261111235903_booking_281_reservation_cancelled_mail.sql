-- booking_281: yhdistetty peruutusviesti reservation_cancelled (tilausnäkymä v3 §4 G). Joonas 11.11.2026 18.12–18.15:
-- md5-vakiot on kirjoitettu 8 merkin paloina ('aaaaaaaa'||…): sama arvo, mutta salaisuusskanneri ei tulkitse 32 merkin heksaa avaimeksi.
--   peruutusviesti lähtee HETI toiminnon yhteydessä (EI 2 pankkipäivän odotusta eikä vakiota). Hyvitysteksti riippuu tilasta lähetyshetkellä:
--   - hyvitys jo vahvistettu (done) → "hyvitetty" + hyvityskuitti liitteenä (yksi viesti; erillinen refund_receipt ohitetaan),
--   - hyvitys kesken (requested/processing) → "hyvitys käsittelyssä"; kuitti lähtee erikseen, kun Montonio vahvistaa (montonio_refund_complete),
--   - ei hyvitystä → viestissä ei mainita hyvitystä lainkaan.
--
-- Muutokset:
--  * email_outbox.kind + 'reservation_cancelled' (lähtötila = PROD/DEV-rajoite, jossa myös 'newsletter').
--  * admin_cancel_reservation(…, p_gift_card_keep) → (…, p_gift_card_keep, p_notify boolean default null). booking_280:n 5 argumentin versio pudotetaan.
--      p_notify true  = yksi reservation_cancelled-viesti heti: perutut varaukset, käynnistetyt hyvitykset (summa + tila),
--                       lahjakortin tila (palautettu / menetetty) ja kumppanilunastuksen tila (tilaus jää voimaan).
--      p_notify null/false = ei peruutusviestiä.
--  * Hyvityskuitti: _on_refund_done ennallaan (jonottaa refund_receipt-viestin, kun hyvitys on done: käsin kirjattu heti, Montonio kun
--    montonio_refund_complete vahvistaa). Claim ohittaa refund_receipt-rivin, jos sama kuitti lähtee peruutusviestin liitteenä.
--  * email_outbox_claim (booking_279-versio) + reservation_cancelled-rikastus (booking._reservation_cancelled_mail).
-- Edge send-emails (templates/texts) tuntee lajin reservation_cancelled: julkaistava ENNEN kuin UI lähettää p_notify = true.
-- Ei asiakasviestejä testeissä (paikallinen kanta; rivit jäävät jonoon).

set local lock_timeout = '5s';

do $pre$
declare v text; x record;
begin
  for x in select * from (values
      ('booking.email_outbox_claim(integer)', array[('e46ae5eb'||'d9fb813a'||'087b7f05'||'c40949b8'),('44601247'||'f6bbcadf'||'ece1e56a'||'0c08fb13')]),
      ('booking._enqueue_email(text,bigint,bigint,bigint,text,jsonb)', array[('e2eee720'||'6bd6006e'||'d93a81b1'||'cdeecb32')])
    ) t(sig, ok) loop
    v := md5(pg_get_functiondef(to_regprocedure(x.sig)));
    if v is null or not (v = any (x.ok)) then raise exception 'booking_281: % md5 % ei vastaa odotettua (%). Ei muutoksia.', x.sig, v, array_to_string(x.ok, ' / '); end if;
  end loop;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_cancel_reservation(bigint,text,boolean,text,boolean)')));
  if v is not null and v <> ('5664a3cd'||'e7b36666'||'711c023e'||'8ce9ba5f') then
    raise exception 'booking_281: admin_cancel_reservation (5 arg, booking_280) md5 % ei vastaa. Ei muutoksia.', v;
  end if;
  if v is null and to_regprocedure('booking.admin_cancel_reservation(bigint,text,boolean,text,boolean,boolean)') is null then
    raise exception 'booking_281: booking_280 puuttuu (admin_cancel_reservation 5 arg). Ei muutoksia.';
  end if;
  if to_regprocedure('booking.admin_cancel_reservation(bigint,text,boolean,text)') is not null then
    raise exception 'booking_281: 4 argumentin admin_cancel_reservation on yhä olemassa (booking_280 ajamatta). Ei muutoksia.';
  end if;
  v := (select md5(pg_get_constraintdef(oid)) from pg_constraint where conrelid = 'booking.email_outbox'::regclass and conname = 'email_outbox_kind_check');
  if v is null or v not in (('37e35b13'||'045a5382'||'2f2da9de'||'d36263e1'), ('4948a32b'||'0fffc9f4'||'9667a4c2'||'c2fe906e')) then
    raise exception 'booking_281: email_outbox_kind_check md5 % ei ole PROD-lähtötila 37e35b13…. Ei muutoksia.', v;
  end if;
  for x in select * from (values
      ('booking.admin_cancel_reservation(bigint,text,boolean,text,boolean,boolean)', ('f76f9885'||'7d6477f4'||'95f27658'||'2e732c11')),
      ('booking._enqueue_reservation_cancelled(bigint,uuid,bigint[],jsonb,jsonb,boolean)', ('64b44693'||'bdf387b9'||'e94b76dc'||'cd201094')),
      ('booking._reservation_cancelled_mail(bigint)', ('4a944f66'||'279e4c82'||'b3c4aa03'||'707ad3da'))
    ) t(sig, ok) loop
    if to_regprocedure(x.sig) is not null and md5(pg_get_functiondef(to_regprocedure(x.sig))) <> x.ok then
      raise exception 'booking_281: vieras aiempi versio %. Ei muutoksia.', x.sig;
    end if;
  end loop;
end $pre$;

alter table booking.email_outbox drop constraint email_outbox_kind_check;
alter table booking.email_outbox add constraint email_outbox_kind_check CHECK ((kind = ANY (ARRAY['newsletter'::text, 'payment_link_reminder'::text, 'event_message'::text, 'waitlist_joined'::text, 'order_confirmation'::text, 'payment_link'::text, 'receipt'::text, 'refund_receipt'::text, 'cancel_request_ack'::text, 'order_change'::text, 'gift_card_buyer'::text, 'gift_card_recipient'::text, 'voucher_claim_received'::text, 'voucher_claim_problem'::text, 'business_quote_ack'::text, 'business_quote_notify'::text, 'invoice_pdf'::text, 'product_message'::text, 'waitlist_spot_freed'::text, 'annual_card_code'::text, 'staff_shift_notice'::text, 'unpaid_booking_cancelled'::text, 'reservation_cancelled'::text])));

-- Jonottaa viestin heti (_enqueue_email: lähtee seuraavalla ajolla). Payload: toiminnon tunniste, perutut varaukset, käynnistetyt rahahyvitykset (id + summa),
-- lahjakortin käsittely ja kumppanilunastuksen tila. Dedupe: yksi viesti / toiminto.
create or replace function booking._enqueue_reservation_cancelled(p_order_id bigint, p_action_id uuid, p_reservation_ids bigint[], p_refunds jsonb, p_gift jsonb, p_order_kept boolean)
returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  return coalesce(booking._enqueue_email('reservation_cancelled', p_order_id, null, null,
    'reservation_cancelled:' || p_order_id::text || ':' || p_action_id::text,
    jsonb_build_object('action_id', p_action_id, 'reservation_ids', to_jsonb(coalesce(p_reservation_ids, '{}'::bigint[])),
                       -- rahahyvitykset + lahjakortille palautukset (molemmista syntyy hyvityskuitti)
                       'refund_ids', coalesce((select jsonb_agg((e ->> 'refund_id')::bigint)
                                                 from jsonb_array_elements(coalesce(p_refunds, '[]'::jsonb) || coalesce(p_gift, '[]'::jsonb)) e
                                                where e ->> 'refund_id' ~ '^[0-9]+$'), '[]'::jsonb),
                       'gift_card', coalesce(p_gift, '[]'::jsonb), 'order_kept', coalesce(p_order_kept, false))), false);
end $$;

-- Viestin sisältö lähetyshetkellä (claim). Hyvitysten tila luetaan refunds-taulusta: done / requested / processing / failed / cancelled.
-- done + kuitti → kuitti liitteenä (claim ohittaa saman kuitin erillisen refund_receipt-rivin). requested/processing → "käsittelyssä",
-- kuitti lähtee myöhemmin erikseen (_on_refund_done). Ei hyvityksiä → refunds = [] (viestissä ei mainita hyvitystä). Ei maksutavan/välittäjän nimeä.
create or replace function booking._reservation_cancelled_mail(p_outbox_id bigint)
returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'reservations', coalesce((select jsonb_agg(jsonb_build_object('product_name', coalesce(it.product_name, p.name), 'product_name_en', p.name_en,
                         'starts_at', r.starts_at, 'ends_at', r.ends_at, 'persons', r.persons, 'option', booking._option_json(r.product_option_id)) order by r.starts_at, r.id)
                       from booking.reservations r left join booking.order_items it on it.id = r.order_item_id left join kb.products p on p.id = r.product_id
                      where r.order_id = e.order_id
                        and r.id in (select x::bigint from jsonb_array_elements_text(coalesce(e.payload -> 'reservation_ids', '[]'::jsonb)) x)), '[]'::jsonb),
    'refunds', coalesce((select jsonb_agg(jsonb_build_object('refund_id', f.id, 'amount', f.amount, 'status', f.status,
                         'kind', case when f.provider_status = 'gift_card_keep' then 'gift_card' else 'money' end,
                         -- kuitti liitteeksi vain valmiille hyvitykselle, jonka kuittia ei ole jo lähetetty erikseen
                         'receipt', case when f.status = 'done' and rc.id is not null and not rc_sent.sent
                                         then jsonb_build_object('receipt_no', rc.receipt_no, 'public_token', rc.public_token, 'total', rc.total_gross) end,
                         'receipt_sent_separately', f.status = 'done' and rc.id is not null and rc_sent.sent) order by f.id)
                       from booking.refunds f
                       left join booking.receipts rc on rc.refund_id = f.id
                       cross join lateral (select exists (select 1 from booking.email_outbox s where s.kind = 'refund_receipt' and s.receipt_id = rc.id
                                                            and s.status in ('sent', 'sending')) as sent) rc_sent
                      where f.order_id = e.order_id
                        and f.id in (select x::bigint from jsonb_array_elements_text(coalesce(e.payload -> 'refund_ids', '[]'::jsonb)) x)), '[]'::jsonb),
    'gift_card', coalesce((select jsonb_agg(jsonb_build_object('action', g ->> 'action', 'amount', (g ->> 'amount')::numeric,
                           'valid_to', gc.valid_to, 'code_last4', right(gc.code, 4)) order by (g ->> 'payment_id')::bigint)
                         from jsonb_array_elements(coalesce(e.payload -> 'gift_card', '[]'::jsonb)) g
                         left join booking.payments pay on pay.id = (g ->> 'payment_id')::bigint
                         left join booking.gift_cards gc on gc.id = pay.gift_card_id), '[]'::jsonb),
    'order_kept', coalesce((e.payload ->> 'order_kept')::boolean, false))
  from booking.email_outbox e where e.id = p_outbox_id
$$;

CREATE OR REPLACE FUNCTION booking.email_outbox_claim(p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_rows jsonb;
begin
  -- Separate SPI statement: observe actual post-trigger statuses, not the caller SELECT snapshot.
  v_rows := booking.email_outbox_claim_base_215(p_limit);
  -- booking_281 (Joonas 11.11.2026): peruutusviestin hyvitysteksti riippuu tilasta LÄHETYSHETKELLÄ. Jos hyvitys on jo vahvistettu (done) ja
  -- kuitti on olemassa, kuitti kulkee peruutusviestin liitteenä → saman kuitin erillinen refund_receipt-rivi ohitetaan (jonossa, epäonnistunut
  -- tai tässä erässä otettu). Jo lähetettyä/toisen työntekijän lähettämää kuittia ei liitetä uudelleen.
  update booking.email_outbox rr
     set status = 'skipped', locked_at = null, last_error = 'booking_281: hyvityskuitti peruutusviestin liitteenä (#' || c.id || ')'
    from booking.email_outbox c, booking.refunds f, booking.receipts rc
   where c.id in (select (x ->> 'id')::bigint from jsonb_array_elements(v_rows) x where x ->> 'kind' = 'reservation_cancelled')
     and c.status = 'sending'
     and f.id in (select y::bigint from jsonb_array_elements_text(coalesce(c.payload -> 'refund_ids', '[]'::jsonb)) y) and f.status = 'done'
     and f.order_id = c.order_id and rc.refund_id = f.id
     and rr.kind = 'refund_receipt' and rr.receipt_id = rc.id
     and (rr.status in ('pending', 'failed')
          or (rr.status = 'sending' and rr.id in (select (x ->> 'id')::bigint from jsonb_array_elements(v_rows) x)));
  return (
  select coalesce(jsonb_agg(
    case when z.item->>'kind' = 'payment_link_reminder' then
      (case when exists (
          select 1 from booking.email_outbox e
          join booking.payments p on p.id = e.payment_id
          join booking.orders o on o.id = e.order_id
         where e.id = (z.item->>'id')::bigint
           and p.status = 'pending' and p.provider <> 'manual' and p.external_source is null and o.external_source is null
           and (p.link_expires_at is null or p.link_expires_at > now()))
        then z.item
        else z.item || jsonb_build_object('payment', (coalesce(z.item->'payment', '{}'::jsonb) - 'link_url'))
       end)
      || coalesce((select jsonb_build_object('payment_reminder', jsonb_build_object(
            'n', e.payload -> 'reminder_no', 'kind', e.payload ->> 'reminder_kind',
            'cancel_if_unpaid', coalesce((e.payload ->> 'cancel_if_unpaid')::boolean, false),
            'due_at', e.payload -> 'due_at'))
          from booking.email_outbox e where e.id = (z.item->>'id')::bigint), '{}'::jsonb)
    else case when z.item->>'kind' = 'order_confirmation' then
      z.item || coalesce((
        select jsonb_build_object('order', coalesce(z.item->'order', '{}'::jsonb) || jsonb_build_object(
          'deposit', true,
          'training', jsonb_build_object(
            'course_price', tp.course_price, 'addons_total', tp.addons_total, 'total', tp.total,
            'deposit_paid', tp.deposit_paid, 'remaining', tp.remaining, 'addons', tp.addons,
            'segments', tp.segments)))
          from booking.email_outbox e
          join booking.training_participants tp on tp.order_id = e.order_id
         where e.id = (z.item->>'id')::bigint
         order by tp.id limit 1
      ), '{}'::jsonb)
    -- booking_281: peruutusviesti (perutut varaukset, hyvitykset tilan mukaan + valmiiden kuitit, lahjakortin ja kumppanilunastuksen tila)
    when z.item->>'kind' = 'reservation_cancelled' then
      z.item || jsonb_build_object('cancellation', booking._reservation_cancelled_mail((z.item->>'id')::bigint))
    else z.item end end
  order by z.ord), '[]'::jsonb)
  from jsonb_array_elements(v_rows) with ordinality as z(item, ord)
  where exists (select 1 from booking.email_outbox e where e.id=(z.item->>'id')::bigint and e.status='sending')
  );
end $function$;

drop function if exists booking.admin_cancel_reservation(bigint, text, boolean, text, boolean);
CREATE OR REPLACE FUNCTION booking.admin_cancel_reservation(p_reservation_id bigint, p_reason text DEFAULT NULL::text, p_refund boolean DEFAULT false, p_refund_reason text DEFAULT NULL::text, p_gift_card_keep boolean DEFAULT NULL::boolean, p_notify boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r booking.reservations; v_plan jsonb; x jsonb; v_res jsonb; v_out jsonb := '[]'::jsonb; v_total numeric := 0; v_reason text;
        v_gc jsonb := '[]'::jsonb; v_gc_out jsonb := '[]'::jsonb; g booking.gift_cards; v_rid bigint; v_kept_order boolean; v_partner numeric := 0;
        v_action uuid; v_notified boolean := false;
begin
  perform booking._require_permission('bookings.manage');
  if coalesce(p_refund, false) then perform booking._require_permission('payments.refund'); end if;
  select * into r from booking.reservations where id = p_reservation_id for update;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  if r.status not in ('pending','confirmed') then perform booking._err('invalid_status', 'Vain voimassa olevan varauksen voi perua'); end if;
  if coalesce(p_refund, false) and booking._order_invoice_locked(r.order_id) then
    perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.');
  end if;
  v_plan := booking._reservation_refund_plan(r.id);   -- ennen peruutusta (rivit eivät muutu)
  -- booking_280: lahjakorttiosuus (rahaa ei koskaan hyvitetä) → pakollinen valinta "jätetäänkö koodi voimaan"
  select coalesce(jsonb_agg(e), '[]'::jsonb) into v_gc from jsonb_array_elements(coalesce(v_plan -> 'payments', '[]'::jsonb)) e where coalesce((e ->> 'gift_card')::boolean, false);
  select coalesce(sum((e ->> 'amount')::numeric), 0) into v_partner from jsonb_array_elements(coalesce(v_plan -> 'payments', '[]'::jsonb)) e
   where e ->> 'method' = 'partner_voucher' or e ->> 'method' like 'partner\_voucher\_%';
  if jsonb_array_length(v_gc) > 0 and p_gift_card_keep is null then
    perform booking._err('gift_card_keep_required', 'Varaus on maksettu lahjakortilla: valitse, jätetäänkö lahjakorttikoodi voimaan');
  end if;
  if jsonb_array_length(v_gc) > 0 and p_gift_card_keep and booking._order_invoice_locked(r.order_id) then
    perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.');
  end if;
  if jsonb_array_length(v_gc) > 0 and p_gift_card_keep then
    for x in select * from jsonb_array_elements(v_gc) loop
      select gc.* into g from booking.gift_cards gc join booking.payments p on p.gift_card_id = gc.id where p.id = (x ->> 'payment_id')::bigint;
      if not booking._gc_keep_allowed(g) then
        perform booking._err('gift_card_expired', 'Lahjakortti ei ole enää voimassa: koodia ei voi jättää voimaan');
      end if;
    end loop;
  end if;
  perform booking.admin_set_reservation_status(r.id, 'cancelled', coalesce(nullif(btrim(p_reason), ''), 'henkilökunta'));
  for x in select * from jsonb_array_elements(v_gc) loop
    if p_gift_card_keep then
      v_rid := booking._gc_return_to_card((x ->> 'payment_id')::bigint, (x ->> 'amount')::numeric, x -> 'lines',
                 'Varauksen peruutus, koodi jätetty voimaan (varaus #' || r.id || ')', r.id);
      v_gc_out := v_gc_out || jsonb_build_object('payment_id', (x ->> 'payment_id')::bigint, 'amount', (x ->> 'amount')::numeric, 'action', 'returned', 'refund_id', v_rid);
    else
      perform booking._gc_forfeit_on_cancel((x ->> 'payment_id')::bigint, (x ->> 'amount')::numeric, r.id, 'Varauksen peruutus, koodi ei jäänyt voimaan');
      v_gc_out := v_gc_out || jsonb_build_object('payment_id', (x ->> 'payment_id')::bigint, 'amount', (x ->> 'amount')::numeric, 'action', 'forfeited');
    end if;
  end loop;
  if coalesce(p_refund, false) then
    v_reason := coalesce(nullif(btrim(p_refund_reason), ''), 'Varauksen peruutus (varaus #' || r.id || ')');
    for x in select * from jsonb_array_elements(v_plan -> 'payments') e
              where not coalesce((e ->> 'gift_card')::boolean, false)
                and not (e ->> 'method' = 'partner_voucher' or e ->> 'method' like 'partner\_voucher\_%') loop
      v_res := booking.admin_refund((x ->> 'payment_id')::bigint, (x ->> 'amount')::numeric, v_reason, x -> 'lines', false);
      v_out := v_out || jsonb_build_object('payment_id', (x ->> 'payment_id')::bigint, 'provider', x ->> 'provider', 'amount', (x ->> 'amount')::numeric,
        'refund_id', v_res -> 'refund_id', 'status', v_res ->> 'status', 'receipt_no', v_res -> 'receipt_no');
      v_total := v_total + (x ->> 'amount')::numeric;
    end loop;
  end if;
  v_kept_order := booking._order_voucher_redeemed(r.order_id)
                  and not exists (select 1 from booking.reservations y where y.order_id = r.order_id and y.status in ('pending','confirmed'));
  -- booking_281 (Joonas 11.11.2026 18.12): p_notify = true → yksi reservation_cancelled-viesti HETI (peruutus + "hyvitys käsittelyssä"
  -- + lahjakortin/kumppanilunastuksen tila). Hyvityskuitti lähtee erikseen nykyisellä refund_receipt-polulla, kun hyvitys on vahvistettu
  -- (manuaalinen heti; Montonio montonio_refund_complete → _on_refund_done). p_notify null/false → ei peruutusviestiä.
  if p_notify then
    v_action := gen_random_uuid();
    v_notified := booking._enqueue_reservation_cancelled(r.order_id, v_action, array[r.id], v_out, v_gc_out, v_kept_order);
  end if;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'reservations', r.id::text, 'ADMIN_CANCEL_RESERVATION', jsonb_build_object('status', r.status),
          jsonb_build_object('status', 'cancelled', 'refund', coalesce(p_refund, false), 'refunded_total', v_total,
                             'gift_card_keep', p_gift_card_keep, 'gift_card', v_gc_out, 'partner_share', v_partner, 'order_kept_voucher', v_kept_order,
                             'notify', p_notify, 'notified', v_notified, 'action_id', v_action));
  return jsonb_build_object('ok', true, 'cancelled', true, 'order_id', r.order_id, 'refunds', v_out, 'refunded_total', v_total,
    'gift_card', v_gc_out, 'partner_share', v_partner, 'order_kept', v_kept_order,
    'notified', v_notified, 'action_id', v_action,
    'balance', booking._order_balance(r.order_id));
end $function$;

revoke all on function booking._enqueue_reservation_cancelled(bigint, uuid, bigint[], jsonb, jsonb, boolean) from public, anon, authenticated;
revoke all on function booking._reservation_cancelled_mail(bigint) from public, anon, authenticated;
revoke all on function booking.admin_cancel_reservation(bigint, text, boolean, text, boolean, boolean) from public, anon;
grant execute on function booking.admin_cancel_reservation(bigint, text, boolean, text, boolean, boolean) to authenticated, service_role;

notify pgrst, 'reload schema';
