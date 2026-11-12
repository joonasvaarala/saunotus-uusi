-- booking_282: pienennyksen esikatselu ja hyvitys (tilausnäkymä v3 §4 D, PR 3). Lippu settings.partial_refunds_enabled (oletus false).
--
-- Uudet (sisäiset, ei annettu authenticatedille): _flag_on, _pl_cap, _order_refund_info, _refund_allocate, _do_refunds.
-- Uudet julkiset: admin_change_booking_preview(...) (bookings.manage).
-- Muutettu: admin_change_booking (8 arg) → 11 arg (+ p_refund_amount, p_refund_reason, p_notify). 8 argumentin versio pudotetaan.
--
-- Laskentasäännöt (määrittely §4):
--   ylisuoritus = max(netto maksettu − tilauksen summa, 0), netto = maksettu − hyvitetty − käsittelyssä olevat hyvitykset
--   hyvitettävä enintään = min(ylisuoritus, rahamaksut − max(summa − lahjakortti-/kumppanimaksut, 0), hyvitettävissä olevien maksujen jäännös)
--     (lahjakortti/kumppanikoodi kattaa tilauksen ensin; raha hyvitetään vain ylimenevältä osalta; loppu jää ylisuoritukseksi)
--   valinta: verkkomaksut (Montonio ym.) ensin, sitten käteinen; lahjakortti/kumppanikoodi ei koskaan; minimi 0,05 €, 2 desimaalia
--   kohdistus: ensin rivit, joilla katettu > rivin summa (ylisuoritusrivit), sitten muut rivit; ei rivejä → ohitetaan
-- Hyvitys tehdään olemassa olevalla admin_refund-funktiolla (Montonio: status requested → Edge montonio-refund; idempotency-avain refund-<id>).
-- Koko toiminto on yksi transaktio: virhe hyvityksessä kumoaa myös muutoksen.
-- Rollback: rollbacks/20261113000010_booking_282_ROLLBACK.sql
set local lock_timeout = '5s';

do $pre$
declare v text;
begin
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_change_booking(bigint,bigint,date,integer,boolean,boolean,timestamptz,timestamptz)')));
  if v is null then raise exception 'booking_282: admin_change_booking (8 arg) puuttuu. Ei muutoksia.'; end if;
  if to_regprocedure('booking.admin_refund(bigint,numeric,text,jsonb,boolean)') is null then raise exception 'booking_282: admin_refund puuttuu'; end if;
  if to_regprocedure('booking._reservation_refund_plan(bigint)') is null then raise exception 'booking_282: _reservation_refund_plan puuttuu'; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._on_refund_done(bigint)')));
  if v is distinct from '83f32b69d7d7dbd4da4727215241e994' then raise exception 'booking_282: _on_refund_done md5 % ei vastaa odotettua. Ei muutoksia.', v; end if;
end $pre$;

insert into booking.settings(key, value, description, is_public)
values ('partial_refunds_enabled', 'false'::jsonb, 'Hallinnan osahyvitys (muutos, ylisuoritus, peru koko tilaus osasummalla) päällä. Oletus pois.', false)
on conflict (key) do nothing;

-- Viestivalinta (t42u/G): refunds.notify_customer null = vanha käytös (refund_receipt lähtee), false = ei kuittiviestiä (kuitti näkyy silti tilaussivulla),
-- true = kuittiviesti lähtee normaalisti. Asetetaan vain uusissa virroissa (D/E/F/K), jotta admin_refund-kutsujien käytös ei muutu.
alter table booking.refunds add column if not exists notify_customer boolean;

create or replace function booking._on_refund_done(p_refund_id bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare v_id bigint; v_order bigint; v_pay bigint;
begin
  if exists (select 1 from booking.refunds f join booking.payments p on p.id = f.payment_id where f.id = p_refund_id and p.method = 'invoice') then return; end if;
  v_id := booking._issue_refund_receipt(p_refund_id);
  if v_id is not null and coalesce((select f.notify_customer from booking.refunds f where f.id = p_refund_id), true) then
    select order_id, payment_id into v_order, v_pay from booking.refunds where id = p_refund_id;
    perform booking._enqueue_email('refund_receipt', v_order, v_id, v_pay, 'receipt:' || v_id);
  end if;
end $$;

create or replace function booking._flag_on(p_key text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select (s.value #>> '{}') = 'true' from booking.settings s where s.key = p_key), false)
$$;

-- Maksurivin vapaa hyvitettävä määrä (miinus käsittelyssä olevat hyvitysrivit).
create or replace function booking._pl_cap(p_line_id bigint)
returns numeric language sql stable security definer set search_path = '' as $$
  select pl.amount_gross - pl.refunded_gross - coalesce((select sum((x ->> 'amount')::numeric)
           from booking.refunds f, jsonb_array_elements(coalesce(f.lines, '[]'::jsonb)) x
          where f.payment_id = pl.payment_id and f.status in ('requested','processing') and (x ->> 'payment_line_id')::bigint = pl.id), 0)
    from booking.payment_lines pl where pl.id = p_line_id
$$;

-- Tilauksen hyvitystilanne. p_total: vertailusumma (esikatselussa muutoksen jälkeinen summa), oletus orders.total_gross.
create or replace function booking._order_refund_info(p_order_id bigint, p_total numeric default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare o booking.orders; p record; v_total numeric; v_net numeric := 0; v_gp numeric := 0; v_elig numeric := 0; v_money numeric := 0; v_over numeric; v_max numeric;
        v_pays jsonb := '[]'::jsonb; v_kind text; v_cap numeric; v_mode text; v_gcsale boolean;
begin
  select * into o from booking.orders where id = p_order_id;
  if not found then return null; end if;
  v_total := coalesce(p_total, o.total_gross);
  for p in select * from booking.payments x where x.order_id = o.id and x.status in ('paid','partially_refunded') and x.external_source is null order by x.id loop
    v_cap := p.amount - p.refunded_amount - coalesce((select sum(f.amount) from booking.refunds f where f.payment_id = p.id and f.status in ('requested','processing')), 0);
    if v_cap <= 0.004 then continue; end if;
    select c.mode into v_mode from booking.integration_config c where c.key = replace(p.provider, '_', '');
    v_kind := case when p.gift_card_id is not null or p.method = 'gift_card' then 'gift_card'
                   when p.method = 'partner_voucher' or p.method like 'partner\_voucher\_%' then 'partner_voucher'
                   when p.provider <> 'manual' and coalesce(v_mode, 'off') = 'off' then 'online_off'
                   else 'refundable' end;
    v_net := v_net + v_cap;
    if v_kind in ('gift_card', 'partner_voucher') then v_gp := v_gp + v_cap; else v_money := v_money + v_cap; end if;
    if v_kind = 'refundable' then v_elig := v_elig + v_cap; end if;
    v_pays := v_pays || jsonb_build_object('payment_id', p.id, 'provider', p.provider, 'method', p.method, 'cap', v_cap, 'kind', v_kind, 'online', p.provider <> 'manual');
  end loop;
  -- Lahjakorttien ostotilaus hyvitetään vain kokonaan (admin_refund); Johku-historia ei hyvitettävissä
  v_gcsale := exists (select 1 from booking.order_items i where i.order_id = o.id and i.kind = 'gift_card');
  if o.external_source is not null or v_gcsale then v_elig := 0; end if;
  v_over := greatest(v_net - v_total, 0);
  -- Lahjakortti/kumppanikoodi kattaa tilauksen ensin; rahaa hyvitetään vain sen verran kuin rahamaksut ylittävät tarvittavan rahaosuuden
  -- (vakaa: toistettu laskenta ei kasvata hyvitettävää, koska hyvitetty raha vähentää sekä ylisuoritusta että rahamaksuja).
  v_max := greatest(round(least(v_over, greatest(v_money - greatest(v_total - v_gp, 0), 0), v_elig), 2), 0);
  return jsonb_build_object('order_id', o.id, 'total', v_total, 'net_paid', v_net, 'overpaid', round(v_over, 2),
    'non_refundable_amount', round(greatest(v_over - v_max, 0), 2), 'eligible_cap', round(v_elig, 2), 'refundable_max', v_max,
    'invoice_locked', booking._order_invoice_locked(o.id), 'payments', v_pays);
end $$;

-- Jakaa hyvityksen summan maksuille ja maksuriveille. Palauttaa [{payment_id, provider, amount, lines}].
-- p_prefer_items: tilausrivit (esim. muuttunut varaus), joiden maksurivit käytetään ensin; null → vain ylisuoritusrivit ensin.
-- p_cancel_mode: true → ei rajoiteta ylisuoritukseen (koko tilauksen peruutus), vain maksujen jäännökseen.
create or replace function booking._refund_allocate(p_order_id bigint, p_amount numeric, p_payment_id bigint default null,
                                                    p_prefer_items bigint[] default null, p_total_override numeric default null,
                                                    p_cancel_mode boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_info jsonb; v_left numeric; pay jsonb; l record; it record; v_take numeric; v_rem numeric; v_c numeric; v_lines jsonb; v_out jsonb := '[]'::jsonb;
        v_ex jsonb := '{}'::jsonb; v_used jsonb := '{}'::jsonb; v_pass int; v_max numeric; v_pid bigint; v_exc numeric; v_online boolean;
begin
  if p_amount is null or p_amount < 0.05 or p_amount <> round(p_amount, 2) then perform booking._err('invalid_amount', 'Hyvityksen vähimmäissumma on 0,05 € (kaksi desimaalia)'); end if;
  v_info := booking._order_refund_info(p_order_id, p_total_override);
  if v_info is null then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  v_max := case when p_cancel_mode then (v_info ->> 'eligible_cap')::numeric else (v_info ->> 'refundable_max')::numeric end;
  if p_amount > v_max + 0.004 then perform booking._err('amount_exceeds_refundable', format('Hyvitettävissä enintään %s €', v_max)); end if;
  -- ylisuoritus per tilausrivi = katettu − rivin summa
  for it in select i.id, i.line_total_gross, coalesce((select sum(booking._pl_cap(pl.id)) from booking.payment_lines pl join booking.payments p on p.id = pl.payment_id
                    where pl.order_item_id = i.id and p.status in ('paid','partially_refunded')), 0) as covered
              from booking.order_items i where i.order_id = p_order_id loop
    v_exc := it.covered - it.line_total_gross;
    if v_exc > 0.004 then v_ex := v_ex || jsonb_build_object(it.id::text, v_exc); end if;
  end loop;
  v_left := p_amount;
  for pay in select e from jsonb_array_elements(v_info -> 'payments') e
              where e ->> 'kind' = 'refundable' and (p_payment_id is null or (e ->> 'payment_id')::bigint = p_payment_id)
              order by (e ->> 'online')::boolean desc, (e ->> 'payment_id')::bigint loop
    exit when v_left <= 0.004;
    v_pid := (pay ->> 'payment_id')::bigint; v_online := (pay ->> 'online')::boolean;
    v_take := least(v_left, (pay ->> 'cap')::numeric);
    if v_online and v_take < 0.05 then continue; end if;
    v_rem := v_take; v_lines := '[]'::jsonb;
    for v_pass in 1..3 loop
      for l in select pl.id, pl.order_item_id, booking._pl_cap(pl.id) as cap from booking.payment_lines pl where pl.payment_id = v_pid order by pl.id loop
        exit when v_rem <= 0.004;
        v_c := l.cap - coalesce((v_used ->> l.id::text)::numeric, 0);
        if v_c <= 0.004 then continue; end if;
        if v_pass = 1 then
          if p_cancel_mode then continue; end if;
          v_c := least(v_c, coalesce((v_ex ->> l.order_item_id::text)::numeric, 0));
        elsif v_pass = 2 then
          if p_prefer_items is null or not (l.order_item_id = any (p_prefer_items)) then continue; end if;
        end if;
        v_c := least(v_c, v_rem);
        if v_c <= 0.004 then continue; end if;
        v_lines := v_lines || jsonb_build_object('payment_line_id', l.id, 'amount', round(v_c, 2));
        v_used := v_used || jsonb_build_object(l.id::text, coalesce((v_used ->> l.id::text)::numeric, 0) + round(v_c, 2));
        if v_pass = 1 then v_ex := v_ex || jsonb_build_object(l.order_item_id::text, coalesce((v_ex ->> l.order_item_id::text)::numeric, 0) - round(v_c, 2)); end if;
        v_rem := v_rem - round(v_c, 2);
      end loop;
    end loop;
    v_take := round(v_take - greatest(v_rem, 0), 2);
    if v_take <= 0.004 or (v_online and v_take < 0.05) then continue; end if;
    v_out := v_out || jsonb_build_object('payment_id', v_pid, 'provider', pay ->> 'provider', 'method', pay ->> 'method', 'amount', v_take, 'lines', v_lines);
    v_left := v_left - v_take;
  end loop;
  if v_left > 0.004 then perform booking._err('amount_exceeds_refundable', 'Hyvitystä ei voida jakaa maksuille (maksurivit puuttuvat tai summa alle 0,05 €)'); end if;
  return v_out;
end $$;

-- Suorittaa jaon: yksi admin_refund / maksu. Vaatii payments.refund (admin_refund tarkistaa).
create or replace function booking._do_refunds(p_plan jsonb, p_reason text, p_notify boolean default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare x jsonb; v jsonb; v_out jsonb := '[]'::jsonb; v_total numeric := 0;
begin
  for x in select * from jsonb_array_elements(coalesce(p_plan, '[]'::jsonb)) loop
    v := booking.admin_refund((x ->> 'payment_id')::bigint, (x ->> 'amount')::numeric, p_reason, x -> 'lines', false);
    if p_notify is not null then
      update booking.refunds set notify_customer = p_notify where id = (v ->> 'refund_id')::bigint;
      if not p_notify then   -- käsin kirjattu hyvitys on jo kuitattu: jonossa oleva kuittiviesti ohitetaan
        update booking.email_outbox e set status = 'skipped', last_error = 'notify=false'
         where e.kind = 'refund_receipt' and e.status = 'pending' and e.receipt_id in (select r.id from booking.receipts r where r.refund_id = (v ->> 'refund_id')::bigint);
      end if;
    end if;
    v_out := v_out || jsonb_build_object('payment_id', (x ->> 'payment_id')::bigint, 'provider', x ->> 'provider', 'amount', (x ->> 'amount')::numeric,
                                        'refund_id', v -> 'refund_id', 'status', v ->> 'status', 'receipt_no', v -> 'receipt_no');
    v_total := v_total + (x ->> 'amount')::numeric;
  end loop;
  return jsonb_build_object('refunds', v_out, 'total', v_total);
end $$;

-- Muutoksen jälkeinen tilauksen summa (palvelimen hinnoittelu: _rule_price + _addon_total_after). Ei kirjoita mitään.
-- Laskutettu tilaus tai aikaväli-/legipohjainen varaus (ei sääntöä): hintaa ei lasketa uudelleen.
create or replace function booking._change_price_preview(p_reservation_id bigint, p_rule_id bigint, p_persons integer)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare res booking.reservations; o booking.orders; pr record; v_persons integer; v_rule bigint; v_item numeric; v_addons numeric; v_other numeric; v_new numeric;
begin
  select * into res from booking.reservations where id = p_reservation_id;
  if not found then return null; end if;
  select * into o from booking.orders where id = res.order_id;
  v_persons := coalesce(p_persons, res.persons);
  v_rule := coalesce(p_rule_id, res.rule_id);
  if booking._order_invoice_locked(o.id) or v_rule is null then
    v_new := o.total_gross;
  else
    select coalesce(sum(i.line_total_gross), 0) into v_other from booking.order_items i
     where i.order_id = o.id and i.id <> res.order_item_id and i.parent_item_id is distinct from res.order_item_id;
    select * into pr from booking._rule_price(v_rule, v_persons);
    v_item := case when res.annual_card_id is not null then 0 else pr.total end;
    v_addons := booking._addon_total_after(res.order_item_id, v_persons);
    v_new := v_other + v_item + v_addons;
  end if;
  return jsonb_build_object('order_id', o.id, 'old_total', o.total_gross, 'new_total', v_new, 'persons_new', v_persons, 'rule_id', v_rule);
end $$;

-- Esikatselu: uusi hinta palvelimelta (_rule_price + _addon_total_after), erotus, ylisuoritus ja hyvityssuunnitelma. Ei kirjoita mitään.
create or replace function booking.admin_change_booking_preview(p_reservation_id bigint, p_rule_id bigint default null, p_date date default null,
                                                                p_persons integer default null, p_start timestamptz default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare res booking.reservations; o booking.orders; v_persons integer; v_pp jsonb;
        v_new numeric; v_old numeric; v_info jsonb; v_plan jsonb := '[]'::jsonb; v_nonref jsonb; v_locked boolean; v_max numeric; v_items bigint[];
begin
  perform booking._require_permission('bookings.manage');
  select * into res from booking.reservations where id = p_reservation_id;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  select * into o from booking.orders where id = res.order_id;
  if res.status <> 'confirmed' or o.status <> 'confirmed' then perform booking._err('not_changeable', 'Vain vahvistettua varausta voi muuttaa'); end if;
  if (p_rule_id is null) <> (p_date is null) then perform booking._err('invalid_change', 'Anna sekä uusi vuoro että päivä, tai kumpikaan'); end if;
  v_locked := booking._order_invoice_locked(o.id);
  v_persons := coalesce(p_persons, res.persons);
  v_pp := booking._change_price_preview(res.id, p_rule_id, p_persons);
  v_old := (v_pp ->> 'old_total')::numeric; v_new := (v_pp ->> 'new_total')::numeric;
  v_info := booking._order_refund_info(o.id, v_new);
  v_max := (v_info ->> 'refundable_max')::numeric;
  select array_agg(i.id) into v_items from booking.order_items i where i.order_id = o.id and (i.id = res.order_item_id or i.parent_item_id = res.order_item_id);
  if v_max >= 0.05 and not v_locked then
    begin v_plan := booking._refund_allocate(o.id, v_max, null, v_items, v_new);
    exception when sqlstate 'BK001' then v_plan := '[]'::jsonb; end;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('payment_id', e ->> 'payment_id', 'method', e ->> 'method', 'kind', e ->> 'kind', 'amount', e -> 'cap')), '[]'::jsonb)
    into v_nonref from jsonb_array_elements(v_info -> 'payments') e where e ->> 'kind' <> 'refundable';
  return jsonb_build_object('ok', true, 'reservation_id', res.id, 'order_id', o.id, 'persons_old', res.persons, 'persons_new', v_persons,
    'old_total', v_old, 'new_total', v_new, 'diff', round(v_new - v_old, 2), 'paid', v_info -> 'net_paid',
    'overpaid_after', v_info -> 'overpaid', 'refundable_max', v_max, 'non_refundable_amount', v_info -> 'non_refundable_amount',
    'refund_plan', (select coalesce(jsonb_agg(jsonb_build_object('payment_id', e -> 'payment_id', 'provider', e -> 'provider', 'method', e -> 'method',
                                                                  'amount_max', e -> 'amount', 'lines', e -> 'lines')), '[]'::jsonb) from jsonb_array_elements(v_plan) e),
    'non_refundable', v_nonref, 'invoice_locked', v_locked,
    'partial_refunds_enabled', booking._flag_on('partial_refunds_enabled'),
    'can_refund', coalesce(booking.has_permission('payments.refund'), false));
end $$;

drop function if exists booking.admin_change_booking(bigint, bigint, date, integer, boolean, boolean, timestamptz, timestamptz);
create or replace function booking.admin_change_booking(p_reservation_id bigint, p_rule_id bigint default null, p_date date default null,
    p_persons integer default null, p_allow_overbook boolean default false, p_allow_off_schedule boolean default false,
    p_start timestamptz default null, p_end timestamptz default null,
    p_refund_amount numeric default null, p_refund_reason text default null, p_notify boolean default false)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_res booking.reservations; v_out jsonb; v_info jsonb; v_plan jsonb; v_done jsonb := '{"refunds":[],"total":0}'::jsonb; v_reason text; v_items bigint[];
        v_notified boolean := false; v_ids jsonb;
begin
  perform booking._require_permission('bookings.manage');
  if p_rule_id is null and p_date is null and p_persons is null and p_start is null then perform booking._err('invalid_change', 'Ei muutettavaa'); end if;
  if p_refund_amount is not null then
    perform booking._require_permission('payments.refund');
    if not booking._flag_on('partial_refunds_enabled') then perform booking._err('partial_refunds_disabled', 'Osahyvitys ei ole käytössä'); end if;
    if p_refund_amount < 0.05 or p_refund_amount <> round(p_refund_amount, 2) then perform booking._err('invalid_amount', 'Hyvityksen vähimmäissumma on 0,05 €'); end if;
  end if;
  select * into v_res from booking.reservations where id = p_reservation_id;
  if not found then perform booking._err('not_found', 'Varausta ei löydy'); end if;
  -- Lukitus: tilaus ensin (kaikki hyvitysreitit serialisoituvat tähän), sitten ydin lukitsee varauksen
  perform 1 from booking.orders where id = v_res.order_id for update;
  if p_refund_amount is not null and booking._order_invoice_locked(v_res.order_id) then
    perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.');
  end if;
  perform booking._arm_staff_overrides(p_allow_overbook, p_allow_off_schedule, p_start, p_end);
  v_out := booking._change_booking_core(p_reservation_id, p_rule_id, p_date, p_persons, false, null, auth.uid(), 'ADMIN_CHANGE');
  if p_refund_amount is not null then
    v_info := booking._order_refund_info(v_res.order_id);
    if (v_info ->> 'refundable_max')::numeric < 0.05 then perform booking._err('nothing_to_refund', 'Muutoksesta ei synny hyvitettävää ylisuoritusta'); end if;
    select array_agg(i.id) into v_items from booking.order_items i where i.order_id = v_res.order_id and (i.id = v_res.order_item_id or i.parent_item_id = v_res.order_item_id);
    v_plan := booking._refund_allocate(v_res.order_id, p_refund_amount, null, v_items);   -- virhe amount_exceeds_refundable kumoaa koko muutoksen
    v_reason := coalesce(nullif(btrim(p_refund_reason), ''), 'Varauksen muutos (varaus #' || v_res.id || ')');
    v_done := booking._do_refunds(v_plan, v_reason, coalesce(p_notify, false));
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
    values (auth.uid(), booking._jwt_role(), 'reservations', v_res.id::text, 'ADMIN_CHANGE_REFUND', null,
            jsonb_build_object('refund_total', v_done -> 'total', 'refunds', v_done -> 'refunds', 'reason', v_reason));
  end if;
  if coalesce(p_notify, false) then
    select coalesce(jsonb_agg(e -> 'refund_id'), '[]'::jsonb) into v_ids from jsonb_array_elements(v_done -> 'refunds') e;
    v_notified := coalesce(booking._enqueue_email('order_change', v_res.order_id, null, null,
      'order_change:' || v_res.order_id || ':' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS'),
      jsonb_build_object('source', 'admin_change', 'reservation_id', v_res.id, 'refund_ids', v_ids)), false);
  end if;
  return v_out || jsonb_build_object('ok', true, 'refunds', v_done -> 'refunds', 'refunded_total', v_done -> 'total', 'notified', v_notified,
                                     'balance', booking._order_balance(v_res.order_id));
end $$;

revoke all on function booking._flag_on(text), booking._pl_cap(bigint), booking._order_refund_info(bigint, numeric), booking._change_price_preview(bigint, bigint, integer),
  booking._refund_allocate(bigint, numeric, bigint, bigint[], numeric, boolean), booking._do_refunds(jsonb, text, boolean) from public, anon, authenticated;
revoke all on function booking.admin_change_booking_preview(bigint, bigint, date, integer, timestamptz) from public, anon;
grant execute on function booking.admin_change_booking_preview(bigint, bigint, date, integer, timestamptz) to authenticated, service_role;
revoke all on function booking.admin_change_booking(bigint, bigint, date, integer, boolean, boolean, timestamptz, timestamptz, numeric, text, boolean) from public, anon;
grant execute on function booking.admin_change_booking(bigint, bigint, date, integer, boolean, boolean, timestamptz, timestamptz, numeric, text, boolean) to authenticated, service_role;

notify pgrst, 'reload schema';
