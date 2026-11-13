-- booking_283: ylisuorituksen hyvitys (E) ja atominen "peru koko tilaus" (F), tilausnäkymä v3 §4 E+F (PR 3). Lippu settings.partial_refunds_enabled (booking_282).
--
-- Uudet:
--   admin_order_refund_info(p_order_id)  lukufunktio hyvitysdialogeille: ylisuoritus, hyvitettävä enintään, maksut (kind), lahjakortit, kumppanilunastus
--   admin_refund_overpayment(p_order_id, p_amount, p_payment_id, p_reason, p_notify)   payments.refund + lippu; ≤ hyvitettävä enintään (282:n laskentasäännöt)
--   admin_cancel_order(p_order_id, p_reason, p_refund jsonb, p_notify, p_gift_card_keep)  yksi transaktio, yksi hyvitys / maksu, lahjakorttivalinta
-- Muutettu: admin_cancel_reservation 6 arg → 7 arg (+ p_refund_amount: osittainen summa, lippu + payments.refund). 6 argumentin versio pudotetaan.
--
-- Yhteistoiminta booking_288:n kanssa: admin_cancel_order peruu varaukset admin_set_reservation_status-funktiolla; kun viimeinen varaus peruuntuu ja
-- tilaus merkitään perutuksi, PRODin triggeri orders_cancel_close_links (booking._close_cancelled_order_links) sulkee maksulinkit. Tässä migraatiossa EI
-- tehdä omaa linkkien sulkulogiikkaa. Kumppanilunastuksen tilaus jää voimaan (booking_280), jolloin triggeri ei laukea.
-- Rollback: rollbacks/20261113000020_booking_283_ROLLBACK.sql
set local lock_timeout = '5s';

do $pre$
declare v text;
begin
  if to_regprocedure('booking._order_refund_info(bigint,numeric)') is null then raise exception 'booking_283: booking_282 puuttuu. Ei muutoksia.'; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_cancel_reservation(bigint,text,boolean,text,boolean,boolean)')));
  if v is not null and v <> 'f76f98857d6477f495f276582e732c11' then raise exception 'booking_283: admin_cancel_reservation (6 arg) md5 % ei vastaa booking_281-versiota. Ei muutoksia.', v; end if;
  if v is null and to_regprocedure('booking.admin_cancel_reservation(bigint,text,boolean,text,boolean,boolean,numeric)') is null then
    raise exception 'booking_283: admin_cancel_reservation puuttuu. Ei muutoksia.';
  end if;
end $pre$;

-- Maksun kaikki vapaat rivit (koko tilauksen peruutus: lahjakortin palautus/menetys ja hyvitys).
create or replace function booking._payment_free_lines(p_payment_id bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'amount', coalesce(sum(c.cap), 0),
    'lines', coalesce(jsonb_agg(jsonb_build_object('payment_line_id', c.id, 'amount', c.cap) order by c.id), '[]'::jsonb))
    from (select pl.id, booking._pl_cap(pl.id) as cap from booking.payment_lines pl where pl.payment_id = p_payment_id) c where c.cap > 0.004
$$;

create or replace function booking.admin_order_refund_info(p_order_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_info jsonb; o booking.orders; v_gc jsonb := '[]'::jsonb; p record; fl jsonb; g booking.gift_cards;
begin
  if not (coalesce(booking.has_permission('bookings.manage'), false) or coalesce(booking.has_permission('payments.refund'), false)) then
    perform booking._err('forbidden', 'Ei oikeutta');
  end if;
  select * into o from booking.orders where id = p_order_id;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  v_info := booking._order_refund_info(o.id);
  for p in select * from booking.payments x where x.order_id = o.id and x.gift_card_id is not null and x.status in ('paid', 'partially_refunded') order by x.id loop
    fl := booking._payment_free_lines(p.id);
    select * into g from booking.gift_cards where id = p.gift_card_id;
    v_gc := v_gc || jsonb_build_object('payment_id', p.id, 'amount', fl -> 'amount', 'code_last4', right(g.code, 4), 'valid_to', g.valid_to, 'keep_allowed', booking._gc_keep_allowed(g));
  end loop;
  return jsonb_build_object('ok', true, 'order_id', o.id, 'order_status', o.status, 'overpaid', v_info -> 'overpaid', 'refundable_max', v_info -> 'refundable_max',
    'non_refundable_amount', v_info -> 'non_refundable_amount', 'net_paid', v_info -> 'net_paid', 'total', v_info -> 'total', 'payments', v_info -> 'payments',
    -- koko tilauksen peruutus: hyvitettävissä enintään maksutavoittain (ei lahjakortti/kumppani) = 'cap' niillä, joilla kind = refundable
    'cancel_refundable_max', v_info -> 'eligible_cap', 'gift_cards', v_gc, 'voucher_redeemed', booking._order_voucher_redeemed(o.id),
    'active_reservations', (select count(*) from booking.reservations r where r.order_id = o.id and r.status in ('pending', 'confirmed')),
    'gift_card_sale', exists (select 1 from booking.order_items i where i.order_id = o.id and i.kind = 'gift_card'),
    'invoice_locked', booking._order_invoice_locked(o.id), 'partial_refunds_enabled', booking._flag_on('partial_refunds_enabled'),
    'can_refund', coalesce(booking.has_permission('payments.refund'), false));
end $$;

create or replace function booking.admin_refund_overpayment(p_order_id bigint, p_amount numeric, p_payment_id bigint default null,
                                                            p_reason text default null, p_notify boolean default false)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare o booking.orders; v_plan jsonb; v_done jsonb; v_reason text; v_info jsonb; v_notified boolean := false;
begin
  perform booking._require_permission('payments.refund');
  if not booking._flag_on('partial_refunds_enabled') then perform booking._err('partial_refunds_disabled', 'Osahyvitys ei ole käytössä'); end if;
  select * into o from booking.orders where id = p_order_id for update;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if booking._order_invoice_locked(o.id) then
    perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.');
  end if;
  if o.status = 'cancelled' then perform booking._err('invalid_status', 'Peruttu tilaus: käytä peruutuksen hyvitystä'); end if;
  if p_amount is null or p_amount < 0.05 or p_amount <> round(p_amount, 2) then perform booking._err('invalid_amount', 'Hyvityksen vähimmäissumma on 0,05 €'); end if;
  v_info := booking._order_refund_info(o.id);
  if (v_info ->> 'refundable_max')::numeric < 0.05 then perform booking._err('nothing_to_refund', 'Tilauksella ei ole hyvitettävää ylisuoritusta'); end if;
  v_plan := booking._refund_allocate(o.id, p_amount, p_payment_id, null);
  v_reason := coalesce(nullif(btrim(p_reason), ''), 'Ylisuorituksen hyvitys');
  v_done := booking._do_refunds(v_plan, v_reason, coalesce(p_notify, false));
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'orders', o.id::text, 'ADMIN_REFUND_OVERPAYMENT', null,
          jsonb_build_object('amount', p_amount, 'payment_id', p_payment_id, 'refunds', v_done -> 'refunds', 'reason', v_reason, 'notify', p_notify));
  return jsonb_build_object('ok', true, 'order_id', o.id, 'refunds', v_done -> 'refunds', 'refunded_total', v_done -> 'total',
                            'balance', booking._order_balance(o.id), 'refund_info', booking._order_refund_info(o.id));
end $$;

create or replace function booking.admin_cancel_order(p_order_id bigint, p_reason text default null, p_refund jsonb default null,
                                                      p_notify boolean default null, p_gift_card_keep boolean default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare o booking.orders; r booking.reservations; v_ids bigint[] := '{}'; v_reason text; v_rr text; x jsonb; v_plan jsonb; v_done jsonb := '{"refunds":[],"total":0}'::jsonb;
        p record; fl jsonb; g booking.gift_cards; v_gc jsonb := '[]'::jsonb; v_gc_out jsonb := '[]'::jsonb; v_rid bigint; v_partner numeric := 0;
        v_kept boolean; v_action uuid; v_notified boolean := false; v_seen bigint[] := '{}'; v_first bigint; v_info jsonb;
begin
  perform booking._require_permission('bookings.manage');
  select * into o from booking.orders where id = p_order_id for update;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if o.external_source is not null then perform booking._err('order_not_editable', 'Johku-historian tilausta ei voi perua tässä'); end if;
  if exists (select 1 from booking.order_items i where i.order_id = o.id and i.kind = 'gift_card') then
    perform booking._err('gift_card_sale_order', 'Lahjakorttien ostotilauksen peruutus ja hyvitys tehdään lahjakorttien hallinnassa');
  end if;
  -- varaukset lukitaan id-järjestyksessä
  for r in select * from booking.reservations where order_id = o.id and status in ('pending', 'confirmed') order by id for update loop
    v_ids := v_ids || r.id;
  end loop;
  if coalesce(array_length(v_ids, 1), 0) = 0 then perform booking._err('invalid_status', 'Tilauksella ei ole voimassa olevia varauksia'); end if;
  v_first := v_ids[1];
  if p_refund is not null and jsonb_typeof(p_refund) <> 'array' then perform booking._err('invalid_items', 'p_refund väärässä muodossa'); end if;
  if p_refund is not null and jsonb_array_length(p_refund) > 0 then
    perform booking._require_permission('payments.refund');
    if not booking._flag_on('partial_refunds_enabled') then perform booking._err('partial_refunds_disabled', 'Osahyvitys ei ole käytössä'); end if;
    if booking._order_invoice_locked(o.id) then
      perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.');
    end if;
  end if;
  v_reason := coalesce(nullif(btrim(p_reason), ''), 'henkilökunta');
  -- lahjakorttiosuus: rahaa ei hyvitetä; pakollinen valinta jätetäänkö koodi voimaan (booking_280)
  for p in select * from booking.payments x where x.order_id = o.id and x.gift_card_id is not null and x.status in ('paid', 'partially_refunded') order by x.id loop
    fl := booking._payment_free_lines(p.id);
    if (fl ->> 'amount')::numeric > 0.004 then v_gc := v_gc || (fl || jsonb_build_object('payment_id', p.id)); end if;
  end loop;
  if jsonb_array_length(v_gc) > 0 and p_gift_card_keep is null then
    perform booking._err('gift_card_keep_required', 'Tilaus on maksettu (osin) lahjakortilla: valitse, jätetäänkö lahjakorttikoodi voimaan');
  end if;
  if jsonb_array_length(v_gc) > 0 and p_gift_card_keep then
    if booking._order_invoice_locked(o.id) then
      perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.');
    end if;
    for x in select * from jsonb_array_elements(v_gc) loop
      select gc.* into g from booking.gift_cards gc join booking.payments pp on pp.gift_card_id = gc.id where pp.id = (x ->> 'payment_id')::bigint;
      if not booking._gc_keep_allowed(g) then perform booking._err('gift_card_expired', 'Lahjakortti ei ole enää voimassa: koodia ei voi jättää voimaan'); end if;
    end loop;
  end if;
  select coalesce(sum(booking._pl_cap(pl.id)), 0) into v_partner from booking.payment_lines pl join booking.payments pp on pp.id = pl.payment_id
   where pp.order_id = o.id and pp.status in ('paid', 'partially_refunded') and (pp.method = 'partner_voucher' or pp.method like 'partner\_voucher\_%');
  -- hyvitysten tarkistus ENNEN peruutusta (virhe kumoaa kaiken): yksi rivi / maksu, summa ≤ maksun jäännös, ei lahjakortti/kumppani
  if p_refund is not null and jsonb_array_length(p_refund) > 0 then
    v_plan := '[]'::jsonb;
    for x in select * from jsonb_array_elements(p_refund) loop
      if coalesce(x ->> 'payment_id', '') !~ '^\d{1,18}$' or coalesce(x ->> 'amount', '') !~ '^\d{1,6}(\.\d{1,2})?$' then perform booking._err('invalid_items', 'Hyvitysrivi virheellinen'); end if;
      if (x ->> 'payment_id')::bigint = any (v_seen) then perform booking._err('invalid_items', 'Yksi hyvitys / maksu: sama maksu useasti'); end if;
      v_seen := v_seen || (x ->> 'payment_id')::bigint;
      if not exists (select 1 from booking.payments pp where pp.id = (x ->> 'payment_id')::bigint and pp.order_id = o.id) then perform booking._err('not_found', 'Maksua ei löydy tilaukselta'); end if;
      v_plan := v_plan || booking._refund_allocate(o.id, (x ->> 'amount')::numeric, (x ->> 'payment_id')::bigint, null, null, true);
    end loop;
  end if;
  -- peruutus: varaukset yksitellen id-järjestyksessä (admin_set_reservation_status päättää tilauksen tilan; kumppanilunastus jättää tilauksen voimaan)
  foreach v_rid in array v_ids loop
    perform booking.admin_set_reservation_status(v_rid, 'cancelled', v_reason);
  end loop;
  for x in select * from jsonb_array_elements(v_gc) loop
    if p_gift_card_keep then
      v_rid := booking._gc_return_to_card((x ->> 'payment_id')::bigint, (x ->> 'amount')::numeric, x -> 'lines',
                 'Tilauksen peruutus, koodi jätetty voimaan (tilaus #' || o.order_no || ')', v_first);
      v_gc_out := v_gc_out || jsonb_build_object('payment_id', (x ->> 'payment_id')::bigint, 'amount', (x ->> 'amount')::numeric, 'action', 'returned', 'refund_id', v_rid);
    else
      perform booking._gc_forfeit_on_cancel((x ->> 'payment_id')::bigint, (x ->> 'amount')::numeric, v_first, 'Tilauksen peruutus, koodi ei jäänyt voimaan');
      v_gc_out := v_gc_out || jsonb_build_object('payment_id', (x ->> 'payment_id')::bigint, 'amount', (x ->> 'amount')::numeric, 'action', 'forfeited');
    end if;
  end loop;
  if v_plan is not null and jsonb_array_length(v_plan) > 0 then
    v_rr := coalesce(nullif(btrim(p_reason), ''), 'Tilauksen peruutus (tilaus #' || o.order_no || ')');
    v_done := booking._do_refunds(v_plan, v_rr, p_notify);
  end if;
  v_kept := booking._order_voucher_redeemed(o.id) and not exists (select 1 from booking.reservations y where y.order_id = o.id and y.status in ('pending', 'confirmed'));
  if p_notify then
    v_action := gen_random_uuid();
    v_notified := booking._enqueue_reservation_cancelled(o.id, v_action, v_ids, v_done -> 'refunds', v_gc_out, v_kept);
  end if;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'orders', o.id::text, 'ADMIN_CANCEL_ORDER', jsonb_build_object('status', o.status),
          jsonb_build_object('reservations', to_jsonb(v_ids), 'refunds', v_done -> 'refunds', 'refunded_total', v_done -> 'total', 'gift_card_keep', p_gift_card_keep,
                             'gift_card', v_gc_out, 'partner_share', v_partner, 'order_kept_voucher', v_kept, 'notify', p_notify, 'notified', v_notified, 'action_id', v_action));
  return jsonb_build_object('ok', true, 'order_id', o.id, 'cancelled_reservations', to_jsonb(v_ids), 'order_kept', v_kept,
    'order_status', (select status from booking.orders where id = o.id), 'refunds', v_done -> 'refunds', 'refunded_total', v_done -> 'total',
    'gift_card', v_gc_out, 'partner_share', v_partner, 'notified', v_notified, 'action_id', v_action, 'balance', booking._order_balance(o.id));
end $$;

drop function if exists booking.admin_cancel_reservation(bigint, text, boolean, text, boolean, boolean);
create or replace function booking.admin_cancel_reservation(p_reservation_id bigint, p_reason text DEFAULT NULL::text, p_refund boolean DEFAULT false, p_refund_reason text DEFAULT NULL::text, p_gift_card_keep boolean DEFAULT NULL::boolean, p_notify boolean DEFAULT NULL::boolean, p_refund_amount numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r booking.reservations; v_plan jsonb; x jsonb; v_res jsonb; v_out jsonb := '[]'::jsonb; v_total numeric := 0; v_reason text;
        v_gc jsonb := '[]'::jsonb; v_gc_out jsonb := '[]'::jsonb; g booking.gift_cards; v_rid bigint; v_kept_order boolean; v_partner numeric := 0;
        v_action uuid; v_notified boolean := false;
        v_refund boolean := coalesce(p_refund, false) or p_refund_amount is not null; v_left numeric; v_take numeric; v_rem numeric; v_c numeric; v_tl jsonb; v_ln jsonb; v_amt numeric; v_pid bigint; v_prov text;
begin
  perform booking._require_permission('bookings.manage');
  if v_refund then perform booking._require_permission('payments.refund'); end if;
  if p_refund_amount is not null then   -- booking_283: osittainen hyvitys (Hyvitä osa)
    if not booking._flag_on('partial_refunds_enabled') then perform booking._err('partial_refunds_disabled', 'Osahyvitys ei ole käytössä'); end if;
    if p_refund_amount < 0.05 or p_refund_amount <> round(p_refund_amount, 2) then perform booking._err('invalid_amount', 'Hyvityksen vähimmäissumma on 0,05 €'); end if;
  end if;
  select * into r from booking.reservations where id = p_reservation_id;
  if found then perform 1 from booking.orders where id = r.order_id for update; end if;   -- lukitusjärjestys: tilaus ensin (kuten muut hyvitysreitit)
  select * into r from booking.reservations where id = p_reservation_id for update;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  if r.status not in ('pending','confirmed') then perform booking._err('invalid_status', 'Vain voimassa olevan varauksen voi perua'); end if;
  if v_refund and booking._order_invoice_locked(r.order_id) then
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
  if v_refund then
    v_reason := coalesce(nullif(btrim(p_refund_reason), ''), 'Varauksen peruutus (varaus #' || r.id || ')');
    v_left := p_refund_amount;
    for x in select * from jsonb_array_elements(v_plan -> 'payments') e
              where not coalesce((e ->> 'gift_card')::boolean, false)
                and not (e ->> 'method' = 'partner_voucher' or e ->> 'method' like 'partner\_voucher\_%')
              order by (e ->> 'provider' <> 'manual') desc, (e ->> 'payment_id')::bigint loop
      v_pid := (x ->> 'payment_id')::bigint; v_prov := x ->> 'provider'; v_amt := (x ->> 'amount')::numeric; v_ln := x -> 'lines';
      if p_refund_amount is not null then   -- osasumma: verkkomaksut ensin, rivit leikataan summaan
        exit when v_left <= 0.004;
        v_take := least(v_left, v_amt);
        if v_prov <> 'manual' and v_take < 0.05 then continue; end if;
        v_tl := '[]'::jsonb; v_rem := v_take;
        v_tl := (select coalesce(jsonb_agg(jsonb_build_object('payment_line_id', t.pl, 'amount', t.take) order by t.ord), '[]'::jsonb) from (
                   select l.ord, l.pl, least(l.amt, greatest(v_take - coalesce(sum(l.amt) over (order by l.ord rows between unbounded preceding and 1 preceding), 0), 0)) as take
                     from (select ord, (e2 ->> 'payment_line_id')::bigint as pl, (e2 ->> 'amount')::numeric as amt from jsonb_array_elements(v_ln) with ordinality as w(e2, ord)) l) t where t.take > 0.004);
        v_amt := v_take; v_ln := v_tl; v_left := v_left - v_take;
      end if;
      v_res := booking.admin_refund(v_pid, v_amt, v_reason, v_ln, false);
      v_out := v_out || jsonb_build_object('payment_id', v_pid, 'provider', v_prov, 'amount', v_amt,
        'refund_id', v_res -> 'refund_id', 'status', v_res ->> 'status', 'receipt_no', v_res -> 'receipt_no');
      v_total := v_total + v_amt;
    end loop;
    if p_refund_amount is not null and v_left > 0.004 then
      perform booking._err('amount_exceeds_refundable', format('Hyvitettävissä enintään %s €', p_refund_amount - v_left));
    end if;
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
          jsonb_build_object('status', 'cancelled', 'refund', v_refund, 'refund_amount', p_refund_amount, 'refunded_total', v_total,
                             'gift_card_keep', p_gift_card_keep, 'gift_card', v_gc_out, 'partner_share', v_partner, 'order_kept_voucher', v_kept_order,
                             'notify', p_notify, 'notified', v_notified, 'action_id', v_action));
  return jsonb_build_object('ok', true, 'cancelled', true, 'order_id', r.order_id, 'refunds', v_out, 'refunded_total', v_total,
    'gift_card', v_gc_out, 'partner_share', v_partner, 'order_kept', v_kept_order,
    'notified', v_notified, 'action_id', v_action,
    'balance', booking._order_balance(r.order_id));
end $function$;

revoke all on function booking._payment_free_lines(bigint) from public, anon, authenticated;
revoke all on function booking.admin_order_refund_info(bigint), booking.admin_refund_overpayment(bigint, numeric, bigint, text, boolean),
  booking.admin_cancel_order(bigint, text, jsonb, boolean, boolean), booking.admin_cancel_reservation(bigint, text, boolean, text, boolean, boolean, numeric) from public, anon;
grant execute on function booking.admin_order_refund_info(bigint), booking.admin_refund_overpayment(bigint, numeric, bigint, text, boolean),
  booking.admin_cancel_order(bigint, text, jsonb, boolean, boolean), booking.admin_cancel_reservation(bigint, text, boolean, text, boolean, boolean, numeric) to authenticated, service_role;

notify pgrst, 'reload schema';
