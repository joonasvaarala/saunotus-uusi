-- booking_280: lahjakortti ja kumppanikoodi varauksen peruutuksessa (tilausnäkymä v3 §4 C, §3.1, §3.1b). Joonas 11.11.2026 t42u:
--   "Lahjakorttivarauksen voi perua, ja silloin kysytään, jätetäänkö koodi voimaan" (rahaa ei hyvitetä) ja
--   "Lunastetun kumppanikoodin varauksen voi perua tai siirtää, mutta tilaus jää voimaan".
--
-- Muutokset:
--  * admin_cancel_reservation(bigint,text,boolean,text) → (…, p_gift_card_keep boolean default null). Vanha 4 argumentin versio pudotetaan
--    (nimetyt 4 argumentin kutsut toimivat edelleen oletusarvon ansiosta). Jos varauksen osuuteen kuuluu lahjakorttimaksua:
--      - p_gift_card_keep on pakollinen (gift_card_keep_required),
--      - true  → osuus palautetaan kortille (_gc_return_to_card: refunds-rivi 'done', provider 'manual', provider_status 'gift_card_keep',
--               maksurivit, hyvityskuitti kuten ennen, _gc_apply 'refund'). Vain voimassa olevalle kortille (gift_card_expired).
--               Oikeus bookings.manage (ei rahaliikennettä, §5).
--      - false → arvo menetetään: maksu jää 'paid', rivi booking.gift_card_forfeits + audit GIFT_CARD_FORFEITED_ON_CANCEL.
--               Joonas 11.11.2026 18.12: menetetty arvo kirjataan kuin asiakas olisi käyttänyt palvelun = toteutunut myynti, sama
--               kirjanpitopolku kuin käytetyllä palvelulla. Toteutus: lunastusmaksu, maksurivit ja kuitti jäävät ennalleen (ei
--               peruutuskirjausta), joten raportit/Procountor (_accrual_json, kuittirivit) käsittelevät sen kuten käytetyn palvelun.
--    p_refund = true hyvittää rahana vain muut kuin lahjakortti- ja kumppanikoodimaksut.
--  * admin_refund: lahjakorttimaksu → gift_card_requires_keep_choice, kumppanikoodimaksu (partner_voucher*) → voucher_not_refundable.
--    Lahjakorttien OSTOmaksun hyvitys ennallaan.
--  * admin_set_reservation_status: jos tilauksella on voucher_claims.status = 'redeemed', viimeisen varauksen peruutus EI peru tilausta
--    (orders.status ennallaan, ei arkistointia; lunastus ja maksurivi säilyvät; saldo näkyy käyttämättömänä lunastuksena).
--    Joonas 11.11.2026 18.12: tilaus jää voimaan myös kirjanpidossa; kumppanilunastus EI vanhene automaattisesti (ei ajastusta).
--  * Uusi admin_reservation_cancel_options(bigint) (bookings.manage): dialogin tiedot (lahjakorttiosuus + voimassaolo, kumppanilunastus,
--    tilaus jää voimaan, asiakkaan sähköposti, tuleva varaus). Rahaosuus vain payments.refund-oikeudella.
--  * Uusi taulu booking.gift_card_forfeits (vain luku henkilökunnalle, jolla payments.manage).
-- Ei toteutettu tässä (avoin): uusi admin_add_reservation_to_order lunastuksen uudelleenkäyttöön. Siirto toimii nykyisellä admin_change_booking-polulla.

set local lock_timeout = '5s';

do $pre$
declare v text; x record;
begin
  -- korvattavat funktiot: PROD/DEV-lähtötila (SELECT-varmennettu 11.11.2026) tai tämän migraation versio (uudelleenajo)
  for x in select * from (values
      ('booking.admin_refund(bigint,numeric,text,jsonb,boolean)', array['709d5fd54d877846682571b60c5d21bd','21cdc941bb061856bd368130a08a5704']),
      ('booking.admin_set_reservation_status(bigint,text,text)', array['aed4b0d7e19f7c13d1ac91c28cc0b642','9a63771574d6a03f665078c5895010d5']),
      ('booking._reservation_refund_plan(bigint)', array['a22952905fc68f119427f7fd4e6025fa']),
      ('booking._gc_apply(bigint,numeric,text,bigint,bigint,text,jsonb,timestamp with time zone)', array['f1958557dbf3ed5ab36d728e2582088a']),
      ('booking.admin_refund_order(bigint,numeric,text,jsonb,boolean)', array['b77f3c4116f6f1ef64267ce4ebde20a1'])
    ) t(sig, ok) loop
    v := md5(pg_get_functiondef(to_regprocedure(x.sig)));
    if v is null or not (v = any (x.ok)) then raise exception 'booking_280: % md5 % ei vastaa odotettua (%). Ei muutoksia.', x.sig, v, array_to_string(x.ok, ' / '); end if;
  end loop;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_cancel_reservation(bigint,text,boolean,text)')));
  if v is not null and v <> 'e627951cee8875cbab0b8ad8b02d8de1' then
    raise exception 'booking_280: admin_cancel_reservation (4 arg) md5 % ei ole lähtötila e627951c…. Ei muutoksia.', v;
  end if;
  if v is null and to_regprocedure('booking.admin_cancel_reservation(bigint,text,boolean,text,boolean)') is null then
    raise exception 'booking_280: admin_cancel_reservation puuttuu kokonaan. Ei muutoksia.';
  end if;
  -- uudet funktiot: puuttuvat tai tämän migraation versio
  for x in select * from (values
      ('booking.admin_cancel_reservation(bigint,text,boolean,text,boolean)', '5664a3cde7b36666711c023e8ce9ba5f'),
      ('booking._order_voucher_redeemed(bigint)', '6f4edb95f92936eaaa342cf4d7be41ce'),
      ('booking._gc_keep_allowed(booking.gift_cards)', '262ac6f9e952e0057f902426fce9845a'),
      ('booking._gc_return_to_card(bigint,numeric,jsonb,text,bigint)', 'b3c10da3850d5296f3a187363d6c2e48'),
      ('booking._gc_forfeit_on_cancel(bigint,numeric,bigint,text)', 'c60d0087f32e7051896e2cba1493c36b'),
      ('booking.admin_reservation_cancel_options(bigint)', 'd7e42987fc7ae571bd29768e04088960')
    ) t(sig, ok) loop
    if to_regprocedure(x.sig) is not null and md5(pg_get_functiondef(to_regprocedure(x.sig))) <> x.ok then
      raise exception 'booking_280: vieras aiempi versio %. Ei muutoksia.', x.sig;
    end if;
  end loop;
end $pre$;

create table if not exists booking.gift_card_forfeits (
  id bigint generated always as identity primary key,
  gift_card_id bigint not null references booking.gift_cards(id) on delete restrict,
  payment_id bigint not null references booking.payments(id) on delete restrict,
  order_id bigint not null references booking.orders(id) on delete restrict,
  reservation_id bigint references booking.reservations(id) on delete set null,
  amount numeric(10,2) not null check (amount > 0),
  note text check (note is null or char_length(note) <= 500),
  created_at timestamptz not null default now(),
  created_by uuid
);
create index if not exists gift_card_forfeits_order_idx on booking.gift_card_forfeits(order_id);
create index if not exists gift_card_forfeits_card_idx on booking.gift_card_forfeits(gift_card_id);
comment on table booking.gift_card_forfeits is 'booking_280: varauksen peruutuksessa menetetty lahjakorttiarvo (koodia ei jätetty voimaan). Maksu jää paid; ei rahaliikettä.';
alter table booking.gift_card_forfeits enable row level security;
revoke all on booking.gift_card_forfeits from public, anon, authenticated;
grant select on booking.gift_card_forfeits to authenticated;
grant all on booking.gift_card_forfeits to service_role;
drop policy if exists staff_read on booking.gift_card_forfeits;
create policy staff_read on booking.gift_card_forfeits for select to authenticated using ((select booking.has_permission('payments.manage')));

create or replace function booking._order_voucher_redeemed(p_order_id bigint)
returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from booking.voucher_claims v where v.order_id = p_order_id and v.status = 'redeemed')
$$;

create or replace function booking._gc_keep_allowed(g booking.gift_cards)
returns boolean
language sql stable security definer set search_path = '' as $$
  select g.id is not null and g.status in ('active', 'used') and (g.valid_to is null or g.valid_to >= booking._gc_today())
$$;

-- Lahjakorttimaksun osuuden palautus kortille (koodi jää voimaan). Sama kirjanpito kuin admin_refundin valmis-haarassa (booking_44),
-- mutta ilman payments.refund-oikeutta: tätä kutsuu vain admin_cancel_reservation (bookings.manage). Ei rahaliikettä.
create or replace function booking._gc_return_to_card(p_payment_id bigint, p_amount numeric, p_lines jsonb, p_reason text, p_reservation_id bigint)
returns bigint
language plpgsql security definer set search_path = '' as $$
declare pay booking.payments; v_cap numeric; v_id bigint; v_sum numeric := 0; l jsonb; v_pl booking.payment_lines;
begin
  select * into pay from booking.payments where id = p_payment_id for update;
  if not found or pay.gift_card_id is null then perform booking._err('not_found', 'Lahjakorttimaksua ei löydy'); end if;
  if pay.status not in ('paid', 'partially_refunded') then perform booking._err('refund_not_allowed', 'Vain maksettu lahjakorttimaksu voidaan palauttaa kortille'); end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then perform booking._err('invalid_amount', 'Virheellinen summa'); end if;
  v_cap := pay.amount - pay.refunded_amount - coalesce((select sum(f.amount) from booking.refunds f where f.payment_id = pay.id and f.status in ('requested','processing')), 0);
  if p_amount > v_cap + 0.004 then perform booking._err('amount_exceeds_refundable', format('Palautettavissa enintään %s €', v_cap)); end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then perform booking._err('invalid_items', 'Rivijako puuttuu'); end if;
  for l in select * from jsonb_array_elements(p_lines) loop
    select * into v_pl from booking.payment_lines where id = (l ->> 'payment_line_id')::bigint and payment_id = pay.id;
    if not found or (l ->> 'amount')::numeric <= 0 or (l ->> 'amount')::numeric > v_pl.amount_gross - v_pl.refunded_gross + 0.004 then
      perform booking._err('invalid_items', 'Rivijako virheellinen');
    end if;
    v_sum := v_sum + (l ->> 'amount')::numeric;
  end loop;
  if abs(v_sum - p_amount) > 0.004 then perform booking._err('invalid_items', 'Rivien summa ei vastaa palautusta'); end if;
  insert into booking.refunds(payment_id, order_id, amount, reason, status, provider, provider_status, lines, created_by, done_at)
  values (pay.id, pay.order_id, p_amount, left(btrim(p_reason), 500), 'done', 'manual', 'gift_card_keep', p_lines, auth.uid(), now()) returning id into v_id;
  update booking.payment_lines pl set refunded_gross = pl.refunded_gross + (x ->> 'amount')::numeric
    from jsonb_array_elements(p_lines) x where pl.id = (x ->> 'payment_line_id')::bigint;
  update booking.payments set refunded_amount = refunded_amount + p_amount,
         status = case when refunded_amount + p_amount >= amount then 'refunded' else 'partially_refunded' end where id = pay.id;
  perform booking._sync_placeholder(pay.order_id);
  perform booking._refresh_order_payment(pay.order_id);
  perform booking._on_refund_done(v_id);
  perform booking._gc_apply(pay.gift_card_id, p_amount, 'refund', pay.order_id, pay.id, 'Palautus kortille: ' || left(btrim(p_reason), 400),
                            jsonb_build_object('booking_280', 'keep', 'reservation_id', p_reservation_id, 'refund_id', v_id));
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'refunds', v_id::text, 'GIFT_CARD_RETURNED_ON_CANCEL', null,
          jsonb_build_object('payment_id', pay.id, 'gift_card_id', pay.gift_card_id, 'amount', p_amount, 'reservation_id', p_reservation_id));
  return v_id;
end $$;

-- Koodi ei jää voimaan: arvo menetetään. Maksu jää paid (ei hyvitystä, ei kortin saldoa). Kirjataan erilliseen tauluun + audit.
create or replace function booking._gc_forfeit_on_cancel(p_payment_id bigint, p_amount numeric, p_reservation_id bigint, p_note text)
returns bigint
language plpgsql security definer set search_path = '' as $$
declare pay booking.payments; v_id bigint;
begin
  select * into pay from booking.payments where id = p_payment_id for update;
  if not found or pay.gift_card_id is null then perform booking._err('not_found', 'Lahjakorttimaksua ei löydy'); end if;
  if p_amount is null or p_amount <= 0 then perform booking._err('invalid_amount', 'Virheellinen summa'); end if;
  insert into booking.gift_card_forfeits(gift_card_id, payment_id, order_id, reservation_id, amount, note, created_by)
  values (pay.gift_card_id, pay.id, pay.order_id, p_reservation_id, round(p_amount, 2), left(p_note, 500), auth.uid()) returning id into v_id;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'payments', pay.id::text, 'GIFT_CARD_FORFEITED_ON_CANCEL', null,
          jsonb_build_object('gift_card_id', pay.gift_card_id, 'amount', round(p_amount, 2), 'reservation_id', p_reservation_id, 'forfeit_id', v_id));
  return v_id;
end $$;

create or replace function booking.admin_reservation_cancel_options(p_reservation_id bigint)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare r booking.reservations; o booking.orders; v_plan jsonb; v_gc jsonb; v_gc_total numeric; v_partner numeric; v_money numeric; v_active int; v_redeemed boolean;
begin
  perform booking._require_permission('bookings.manage');
  select * into r from booking.reservations where id = p_reservation_id;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  select * into o from booking.orders where id = r.order_id;
  v_plan := booking._reservation_refund_plan(r.id);
  select coalesce(jsonb_agg(jsonb_build_object('payment_id', p.id, 'gift_card_id', g.id, 'amount', (e ->> 'amount')::numeric,
           'code_last4', right(g.code, 4), 'valid_to', g.valid_to, 'card_status', g.status, 'keep_allowed', booking._gc_keep_allowed(g)) order by p.id), '[]'::jsonb),
         coalesce(sum((e ->> 'amount')::numeric), 0)
    into v_gc, v_gc_total
    from jsonb_array_elements(coalesce(v_plan -> 'payments', '[]'::jsonb)) e
    join booking.payments p on p.id = (e ->> 'payment_id')::bigint
    left join booking.gift_cards g on g.id = p.gift_card_id
   where coalesce((e ->> 'gift_card')::boolean, false);
  select coalesce(sum((e ->> 'amount')::numeric), 0) into v_partner from jsonb_array_elements(coalesce(v_plan -> 'payments', '[]'::jsonb)) e
   where e ->> 'method' = 'partner_voucher' or e ->> 'method' like 'partner\_voucher\_%';
  v_money := coalesce((v_plan ->> 'total')::numeric, 0) - v_gc_total - v_partner;
  v_active := (select count(*) from booking.reservations x where x.order_id = r.order_id and x.status in ('pending', 'confirmed'));
  v_redeemed := booking._order_voucher_redeemed(r.order_id);
  return jsonb_build_object('ok', true, 'reservation_id', r.id, 'order_id', r.order_id, 'status', r.status,
    'future', r.starts_at > now(), 'active_in_order', v_active,
    'gift_cards', v_gc, 'gift_card_total', v_gc_total, 'gift_card_choice_required', jsonb_array_length(v_gc) > 0,
    'partner_share', v_partner, 'voucher_redeemed', v_redeemed, 'order_stays', v_redeemed and v_active <= 1,
    'money_share', case when booking.has_permission('payments.refund') then v_money end,
    'unallocated', coalesce((v_plan ->> 'unallocated')::int, 0),
    'invoice_locked', booking._order_invoice_locked(r.order_id),
    'customer_email', exists (select 1 from booking.customers c where c.id = o.customer_id and booking._valid_email(c.email)));
end $$;

drop function if exists booking.admin_cancel_reservation(bigint, text, boolean, text);
CREATE OR REPLACE FUNCTION booking.admin_cancel_reservation(p_reservation_id bigint, p_reason text DEFAULT NULL::text, p_refund boolean DEFAULT false, p_refund_reason text DEFAULT NULL::text, p_gift_card_keep boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r booking.reservations; v_plan jsonb; x jsonb; v_res jsonb; v_out jsonb := '[]'::jsonb; v_total numeric := 0; v_reason text;
        v_gc jsonb := '[]'::jsonb; v_gc_out jsonb := '[]'::jsonb; g booking.gift_cards; v_rid bigint; v_kept_order boolean; v_partner numeric := 0;
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
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'reservations', r.id::text, 'ADMIN_CANCEL_RESERVATION', jsonb_build_object('status', r.status),
          jsonb_build_object('status', 'cancelled', 'refund', coalesce(p_refund, false), 'refunded_total', v_total,
                             'gift_card_keep', p_gift_card_keep, 'gift_card', v_gc_out, 'partner_share', v_partner, 'order_kept_voucher', v_kept_order));
  return jsonb_build_object('ok', true, 'cancelled', true, 'order_id', r.order_id, 'refunds', v_out, 'refunded_total', v_total,
    'gift_card', v_gc_out, 'partner_share', v_partner, 'order_kept', v_kept_order,
    'balance', booking._order_balance(r.order_id));
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_refund(p_payment_id bigint, p_amount numeric, p_reason text, p_lines jsonb DEFAULT NULL::jsonb, p_manual_done boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pay booking.payments; o booking.orders; v_cap numeric; v_mode text; v_online boolean; v_id bigint; l jsonb; v_pl booking.payment_lines; v_sum numeric := 0; v_full boolean;
        r record; v_total_cap numeric; v_alloc numeric; v_left numeric; v_alloc_json jsonb := '[]'::jsonb; v_status text; rc record; v_n int; v_i int := 0;
        v_gc_sale boolean := false;
begin
  perform booking._require_permission('payments.refund');
  select * into pay from booking.payments where id = p_payment_id for update;
  if not found then perform booking._err('not_found', 'Maksua ei löydy'); end if;
  -- booking_280 (t42u): lahjakorttimaksua ei hyvitetä rahana eikä kortille kysymättä; kumppanikoodimaksua ei hyvitetä lainkaan.
  if pay.gift_card_id is not null or pay.method = 'gift_card' then
    perform booking._err('gift_card_requires_keep_choice', 'Lahjakorttimaksua ei hyvitetä: peru varaus ja valitse, jätetäänkö lahjakorttikoodi voimaan');
  end if;
  if pay.method = 'partner_voucher' or pay.method like 'partner\_voucher\_%' then
    perform booking._err('voucher_not_refundable', 'Kumppanikoodilla maksettua osuutta ei hyvitetä');
  end if;
  select * into o from booking.orders where id = pay.order_id for update;
  if o.external_source is not null or pay.external_source is not null then perform booking._err('order_not_editable', 'Johku-historian maksuja ei voi hyvittää tässä'); end if;
  if pay.status = 'refunded' then perform booking._err('already_refunded', 'Maksu on jo hyvitetty kokonaan'); end if;
  if pay.status not in ('paid','partially_refunded') then perform booking._err('refund_not_allowed', 'Vain maksettu maksu voidaan hyvittää'); end if;
  if p_reason is null or char_length(btrim(p_reason)) < 3 or char_length(p_reason) > 500 then perform booking._err('invalid_param', 'Anna hyvityksen syy (3–500 merkkiä)'); end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then perform booking._err('invalid_amount', 'Virheellinen summa'); end if;
  v_cap := pay.amount - pay.refunded_amount - coalesce((select sum(f.amount) from booking.refunds f where f.payment_id = pay.id and f.status in ('requested','processing')), 0);
  if p_amount > v_cap + 0.004 then perform booking._err('amount_exceeds_refundable', format('Hyvitettävissä enintään %s €', v_cap)); end if;
  v_online := pay.provider <> 'manual';
  select mode into v_mode from booking.integration_config where key = replace(pay.provider, '_', '');
  if v_online and coalesce(v_mode, 'off') = 'off' then
    if not p_manual_done then perform booking._err('refund_not_allowed', 'Verkkomaksun hyvitys ei ole käytössä – kirjaa hyvitys käsin (vain admin)'); end if;
    if booking.current_staff_role() is distinct from 'admin' then perform booking._err('forbidden', 'Käsinkirjaus verkkomaksulle vaatii admin-roolin'); end if;
  end if;
  v_full := abs(p_amount - v_cap) < 0.005 and pay.refunded_amount = 0;
  -- lahjakortit (booking_44): lahjakorttien ostomaksu hyvitetään vain kokonaan ja vain käyttämättömille korteille (kortit mitätöidään)
  if exists (select 1 from booking.payment_lines pl join booking.order_items oi on oi.id = pl.order_item_id where pl.payment_id = pay.id and oi.kind = 'gift_card')
     and exists (select 1 from booking.gift_cards gc where gc.purchase_order_id = pay.order_id and gc.status <> 'cancelled') then
    if not v_full then perform booking._err('gift_card_refund_full_only', 'Lahjakorttien ostomaksu hyvitetään kokonaan (kortit mitätöidään)'); end if;
    if exists (select 1 from booking.gift_cards gc where gc.purchase_order_id = pay.order_id and gc.status not in ('cancelled', 'pending_payment') and gc.balance < gc.initial_amount) then
      perform booking._err('gift_card_in_use', 'Kortilla on jo käyttöä: ostoa ei voi hyvittää kokonaan (mitätöi kortti hallinnassa ja hyvitä tarvittaessa käsin)');
    end if;
    v_gc_sale := true;
  end if;

  -- rivijako
  if p_lines is not null then
    if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then perform booking._err('invalid_items', 'p_lines väärässä muodossa'); end if;
    for l in select * from jsonb_array_elements(p_lines) loop
      if coalesce(l ->> 'payment_line_id', '') !~ '^\d{1,18}$' or coalesce(l ->> 'amount', '') !~ '^\d{1,6}(\.\d{1,2})?$' then perform booking._err('invalid_items', 'Rivi virheellinen'); end if;
      select * into v_pl from booking.payment_lines where id = (l ->> 'payment_line_id')::bigint and payment_id = pay.id;
      if not found then perform booking._err('item_not_found', 'Maksun riviä ei löydy'); end if;
      if (l ->> 'amount')::numeric <= 0 or (l ->> 'amount')::numeric > v_pl.amount_gross - v_pl.refunded_gross + 0.004 then perform booking._err('amount_exceeds_refundable', 'Rivin hyvitys ylittää hyvitettävissä olevan'); end if;
      v_alloc_json := v_alloc_json || jsonb_build_object('payment_line_id', v_pl.id, 'amount', (l ->> 'amount')::numeric);
      v_sum := v_sum + (l ->> 'amount')::numeric;
    end loop;
    if abs(v_sum - p_amount) > 0.004 then perform booking._err('invalid_items', 'Rivien summa ei vastaa hyvityksen summaa'); end if;
  elsif v_full then
    select coalesce(jsonb_agg(jsonb_build_object('payment_line_id', id, 'amount', amount_gross - refunded_gross) order by id), '[]'::jsonb) into v_alloc_json
      from booking.payment_lines where payment_id = pay.id and amount_gross - refunded_gross <> 0;
  else   -- suhteessa positiivisten rivien hyvitettävään osuuteen
    select coalesce(sum(amount_gross - refunded_gross), 0) into v_total_cap from booking.payment_lines where payment_id = pay.id and amount_gross - refunded_gross > 0;
    if v_total_cap < p_amount - 0.004 then perform booking._err('invalid_items', 'Anna rivijako (p_lines)'); end if;
    v_left := p_amount; select count(*) into v_n from booking.payment_lines where payment_id = pay.id and amount_gross - refunded_gross > 0;
    for r in select id, amount_gross - refunded_gross as cap from booking.payment_lines where payment_id = pay.id and amount_gross - refunded_gross > 0 order by id loop
      v_i := v_i + 1;
      v_alloc := case when v_i = v_n then v_left else least(round(p_amount * r.cap / v_total_cap, 2), r.cap) end;
      v_alloc := least(v_alloc, r.cap, v_left);
      if v_alloc > 0 then v_alloc_json := v_alloc_json || jsonb_build_object('payment_line_id', r.id, 'amount', v_alloc); v_left := v_left - v_alloc; end if;
    end loop;
    if v_left > 0.004 then perform booking._err('invalid_items', 'Anna rivijako (p_lines)'); end if;
  end if;

  v_status := case when v_online and coalesce(v_mode, 'off') <> 'off' then 'requested' else 'done' end;
  insert into booking.refunds(payment_id, order_id, amount, reason, status, provider, provider_status, lines, created_by, done_at)
  values (pay.id, pay.order_id, p_amount, btrim(p_reason), v_status, case when v_online and v_status = 'requested' then pay.provider else 'manual' end,
          case when v_online and v_status = 'done' then 'manual_done' end, v_alloc_json, auth.uid(), case when v_status = 'done' then now() end) returning id into v_id;
  if v_status = 'done' then
    update booking.payment_lines pl set refunded_gross = pl.refunded_gross + (x ->> 'amount')::numeric
      from jsonb_array_elements(v_alloc_json) x where pl.id = (x ->> 'payment_line_id')::bigint;
    update booking.payments set refunded_amount = refunded_amount + p_amount,
           status = case when refunded_amount + p_amount >= amount then 'refunded' else 'partially_refunded' end where id = pay.id;
    perform booking._sync_placeholder(pay.order_id);
    perform booking._refresh_order_payment(pay.order_id);
    perform booking._on_refund_done(v_id);
    -- lahjakortit (booking_44): ostomaksun hyvitys mitätöi kortit; lahjakorttimaksun hyvitys palautetaan kortille (ei rahana)
    if v_gc_sale then perform booking._gc_cancel_order_cards(pay.order_id, 'Ostomaksu hyvitetty (hyvitys #' || v_id || ')'); end if;
    if pay.gift_card_id is not null then perform booking._gc_apply(pay.gift_card_id, p_amount, 'refund', pay.order_id, pay.id, 'Hyvitys kortille: ' || btrim(p_reason)); end if;
  end if;
  insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), booking._jwt_role(), 'refunds', v_id::text, 'ADMIN_REFUND', null, jsonb_build_object('payment_id', pay.id, 'amount', p_amount, 'reason', p_reason, 'status', v_status));
  select id, receipt_no into rc from booking.receipts where refund_id = v_id;
  return jsonb_build_object('ok', true, 'refund_id', v_id, 'status', v_status, 'balance', booking._order_balance(pay.order_id), 'receipt_id', rc.id, 'receipt_no', rc.receipt_no);
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_set_reservation_status(p_reservation_id bigint, p_status text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r booking.reservations;
begin
  perform booking._require_permission('bookings.manage');
  if p_status not in ('confirmed','cancelled','completed','no_show') then perform booking._err('invalid_status', 'Tila ei sallittu'); end if;
  select * into r from booking.reservations where id = p_reservation_id for update;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  update booking.reservations set
      status = p_status, hold_expires_at = case when p_status = 'confirmed' then null else hold_expires_at end,
      cancelled_at = case when p_status = 'cancelled' then now() else cancelled_at end,
      cancel_reason = case when p_status = 'cancelled' then p_reason else cancel_reason end,
      checkin_at = case when p_status = 'completed' and checkin_at is null then now() else checkin_at end
   where id = p_reservation_id;   -- trigger validoi uudelleenaktivoinnin
  -- booking_280 (t42u): lunastetun kumppanikoodin tilaus jää voimaan, vaikka sen viimeinen varaus perutaan.
  if p_status = 'cancelled' and not exists (select 1 from booking.reservations x where x.order_id = r.order_id and x.status in ('pending','confirmed'))
     and not booking._order_voucher_redeemed(r.order_id) then
    update booking.orders set status = 'cancelled', cancelled_at = now() where id = r.order_id;
  elsif p_status = 'confirmed' then
    update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()), cancelled_at = null where id = r.order_id;
  elsif p_status = 'completed' then
    update booking.orders set status = 'completed' where id = r.order_id and not exists (select 1 from booking.reservations x where x.order_id = r.order_id and x.status in ('pending','confirmed'));
  end if;
  return jsonb_build_object('ok', true);
end $function$;

revoke all on function booking._order_voucher_redeemed(bigint) from public, anon, authenticated;
revoke all on function booking._gc_keep_allowed(booking.gift_cards) from public, anon, authenticated;
revoke all on function booking._gc_return_to_card(bigint, numeric, jsonb, text, bigint) from public, anon, authenticated;
revoke all on function booking._gc_forfeit_on_cancel(bigint, numeric, bigint, text) from public, anon, authenticated;
revoke all on function booking.admin_reservation_cancel_options(bigint) from public, anon;
grant execute on function booking.admin_reservation_cancel_options(bigint) to authenticated, service_role;
revoke all on function booking.admin_cancel_reservation(bigint, text, boolean, text, boolean) from public, anon;
grant execute on function booking.admin_cancel_reservation(bigint, text, boolean, text, boolean) to authenticated, service_role;

notify pgrst, 'reload schema';
