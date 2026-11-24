-- booking_345: lahjakortin oston hyvitys lukitsee kortit (K2) + kumppanikoodin lunastus vaatii kumppanin viitteen (K8).
-- KirjanpitoTapion marraskuun tarkastus K2 ja K8. Joonas 24.11.2026 "Korjaa kaikki mitä pystyt".
--
-- K2: kun lahjakortin ostomaksun hyvitys alkaa (refunds requested/processing), oston kortit (active/expired) siirtyvät tilaan
--     'suspended' (gift_cards.refund_hold_id = hyvitys; myös pending_verification). Pidossa olevaa korttia ei voi käyttää eikä saldoa muuttaa.
--     Hyvitys done → kortit mitätöidään (status cancelled, saldo 0, ledger 'cancel_refund').
--     Hyvitys failed/cancelled → pito vapautuu (pending_verification palautuu sellaisenaan; muuten saldo 0 → used, vanhentunut → expired, muuten active).
--     Käytettyä osaa ei hyvitetä: hyvitystä ei voi luoda, jos oston kortilla on jo käyttöä (gift_card_in_use).
--     Koskee vain hyvityksiä, joiden rivit osuvat lahjakorttiriveihin (rivit puuttuvat → kaikki maksun lahjakorttirivit).
--     svc_refund_gift_card_hold(p_refund_id): jo kesken olevan hyvityksen pito jälkikäteen (datakorjaus, esim. hyvitys 71 / kortti 2918).
-- K8: voucher_claims ei voi tulla tilaan redeemed ilman partner_ref:iä (trigger, kattaa kaikki polut: _vc_resolve, botti, hallinta).
--
-- Ei kytkimiä, ei datamuutoksia, ei hintoja/ALV:ita. Rollback: rollbacks/20261125000100_booking_345_ROLLBACK.sql.

-- ---------- K2: rakenne ----------
alter table booking.gift_cards add column if not exists refund_hold_id bigint references booking.refunds(id) on delete set null;
alter table booking.gift_cards add column if not exists refund_hold_prev_status text;
alter table booking.gift_cards drop constraint gift_cards_status_check;
alter table booking.gift_cards add constraint gift_cards_status_check
  check (status = any (array['active'::text, 'used'::text, 'expired'::text, 'cancelled'::text, 'pending_verification'::text, 'pending_payment'::text, 'suspended'::text]));
alter table booking.gift_cards add constraint gift_cards_suspended_hold_chk check ((status = 'suspended') = (refund_hold_id is not null));
create index if not exists gift_cards_refund_hold_idx on booking.gift_cards(refund_hold_id) where refund_hold_id is not null;
comment on column booking.gift_cards.refund_hold_id is 'booking_345: hyvitys, jonka ajaksi kortti on lukittu (status suspended)';
comment on column booking.gift_cards.refund_hold_prev_status is 'booking_345: tila ennen lukitusta (pending_verification palautetaan sellaisenaan; muut lasketaan saldosta ja voimassaolosta)';

-- Pidossa olevan kortin saldoa ei voi muuttaa, eikä pito pura muuten kuin mitätöimällä tai vapautusfunktiolla.
create or replace function booking._gc_suspended_guard_trg()
 returns trigger language plpgsql set search_path to ''
as $function$
begin
  if old.status = 'suspended' then
    if new.status = 'suspended' and new.balance is distinct from old.balance then
      perform booking._err('gift_card_suspended', 'Kortin osto on hyvityksessä: korttia ei voi käyttää eikä saldoa muuttaa');
    end if;
    if new.status not in ('suspended', 'cancelled') and coalesce(current_setting('booking.gc_hold_release', true), '') <> '1' then
      perform booking._err('gift_card_suspended', 'Kortin osto on hyvityksessä: tila vapautuu vasta, kun hyvitys epäonnistuu tai perutaan');
    end if;
  end if;
  return new;
end $function$;
drop trigger if exists gift_cards_suspended_guard on booking.gift_cards;
create trigger gift_cards_suspended_guard before update on booking.gift_cards for each row execute function booking._gc_suspended_guard_trg();

-- Hyvityksen kohteena olevat oston kortit (lahjakorttirivit; rivit puuttuvat → kaikki maksun lahjakorttirivit).
create or replace function booking._refund_gc_cards(p_payment_id bigint, p_order_id bigint, p_lines jsonb)
 returns setof bigint language sql stable security definer set search_path to ''
as $function$
  with items as (
    select pl.order_item_id from booking.payment_lines pl join booking.order_items oi on oi.id = pl.order_item_id
     where pl.payment_id = p_payment_id and oi.kind = 'gift_card'
       and (coalesce(jsonb_typeof(p_lines), 'null') <> 'array' or jsonb_array_length(p_lines) = 0
            or pl.id in (select (x ->> 'payment_line_id')::bigint from jsonb_array_elements(p_lines) x where (x ->> 'payment_line_id') ~ '^\d{1,18}$')))
  select g.id from booking.gift_cards g
   where exists (select 1 from items) and g.purchase_order_id = p_order_id
     and (g.purchase_order_item_id is null or g.purchase_order_item_id in (select order_item_id from items))
   order by g.id
$function$;
revoke all on function booking._refund_gc_cards(bigint, bigint, jsonb) from public, anon, authenticated;

-- Lukitus / mitätöinti / vapautus yhdelle hyvitykselle.
create or replace function booking._refund_gc_apply(p_refund_id bigint, p_op text)
 returns integer language plpgsql security definer set search_path to ''
as $function$
declare rf booking.refunds; c record; v_n int := 0; v_note text;
begin
  select * into rf from booking.refunds where id = p_refund_id;
  if not found then return 0; end if;
  if p_op = 'hold' then
    for c in select g.id, g.status from booking.gift_cards g where g.id in (select booking._refund_gc_cards(rf.payment_id, rf.order_id, rf.lines))
               and g.status in ('active', 'expired', 'pending_verification') order by g.id for update loop
      update booking.gift_cards set status = 'suspended', refund_hold_id = rf.id, refund_hold_prev_status = c.status where id = c.id;
      v_n := v_n + 1;
    end loop;
  elsif p_op = 'void' then
    v_note := 'Ostomaksu hyvitetty (hyvitys #' || rf.id || ')';
    for c in select g.id, g.balance from booking.gift_cards g
              where (g.id in (select booking._refund_gc_cards(rf.payment_id, rf.order_id, rf.lines)) or g.refund_hold_id = rf.id)
                and g.status not in ('cancelled', 'pending_payment') order by g.id for update loop
      update booking.gift_cards set status = 'cancelled', refund_hold_id = null, refund_hold_prev_status = null where id = c.id;
      if c.balance > 0 then perform booking._gc_apply(c.id, -c.balance, 'cancel_refund', rf.order_id, rf.payment_id, v_note, jsonb_build_object('refund_id', rf.id));
      else insert into booking.gift_card_ledger(gift_card_id, order_id, payment_id, delta, balance_after, reason, created_by, note, meta)
           values (c.id, rf.order_id, rf.payment_id, 0, 0, 'cancel_refund', auth.uid(), v_note, jsonb_build_object('refund_id', rf.id));
      end if;
      v_n := v_n + 1;
    end loop;
  elsif p_op = 'release' then
    perform set_config('booking.gc_hold_release', '1', true);
    for c in select g.id, g.balance, g.valid_to, g.refund_hold_prev_status from booking.gift_cards g where g.refund_hold_id = rf.id and g.status = 'suspended' order by g.id for update loop
      update booking.gift_cards
         set status = case when c.refund_hold_prev_status = 'pending_verification' then 'pending_verification' when c.balance = 0 then 'used' when c.valid_to is not null and c.valid_to < booking._gc_today() then 'expired' else 'active' end,
             refund_hold_id = null, refund_hold_prev_status = null
       where id = c.id;
      v_n := v_n + 1;
    end loop;
    perform set_config('booking.gc_hold_release', '', true);
  else
    perform booking._err('invalid_param', 'p_op: hold | void | release');
  end if;
  if v_n > 0 then
    insert into booking.audit_log(action, table_name, row_pk, new_data)
    values ('GIFT_CARD_REFUND_' || upper(p_op), 'refunds', rf.id::text, jsonb_build_object('refund_id', rf.id, 'order_id', rf.order_id, 'payment_id', rf.payment_id, 'cards', v_n, 'refund_status', rf.status));
  end if;
  return v_n;
end $function$;
revoke all on function booking._refund_gc_apply(bigint, text) from public, anon, authenticated;

-- Käytettyä osaa ei hyvitetä (kaikki polut, myös käsin kirjattu hyvitys).
create or replace function booking._refunds_gc_guard_trg()
 returns trigger language plpgsql security definer set search_path to ''
as $function$
begin
  if exists (select 1 from booking.gift_cards g where g.id in (select booking._refund_gc_cards(new.payment_id, new.order_id, new.lines))
              and g.status not in ('cancelled', 'pending_payment') and g.balance < g.initial_amount) then
    perform booking._err('gift_card_in_use', 'Kortilla on jo käyttöä: lahjakortin ostoa ei voi hyvittää (käytettyä osaa ei hyvitetä)');
  end if;
  return new;
end $function$;
drop trigger if exists refunds_gc_guard on booking.refunds;
create trigger refunds_gc_guard before insert on booking.refunds for each row execute function booking._refunds_gc_guard_trg();

create or replace function booking._refunds_gc_hold_trg()
 returns trigger language plpgsql security definer set search_path to ''
as $function$
declare v_was_open boolean := tg_op = 'UPDATE' and old.status in ('requested', 'processing');
begin
  if new.status in ('requested', 'processing') and not v_was_open then perform booking._refund_gc_apply(new.id, 'hold');
  elsif new.status = 'done' and (tg_op = 'INSERT' or old.status <> 'done') then perform booking._refund_gc_apply(new.id, 'void');
  elsif new.status in ('failed', 'cancelled') and v_was_open then perform booking._refund_gc_apply(new.id, 'release');
  end if;
  return null;
end $function$;
drop trigger if exists refunds_gc_hold on booking.refunds;
create trigger refunds_gc_hold after insert or update of status on booking.refunds for each row execute function booking._refunds_gc_hold_trg();

-- Datakorjausta varten: jo kesken olevan hyvityksen kortit lukkoon (esim. hyvitys 71 / kortti 2918). Vain service_role.
create or replace function booking.svc_refund_gift_card_hold(p_refund_id bigint, p_actor text default 'Bottiavustus')
 returns jsonb language plpgsql security definer set search_path to ''
as $function$
declare rf booking.refunds; v_n int; v_used int;
begin
  select * into rf from booking.refunds where id = p_refund_id for update;
  if not found then perform booking._err('not_found', 'Hyvitystä ei löydy'); end if;
  if rf.status not in ('requested', 'processing') then perform booking._err('refund_not_pending', 'Hyvitys ei ole kesken (tila: ' || rf.status || ')'); end if;
  select count(*) into v_used from booking.gift_cards g where g.id in (select booking._refund_gc_cards(rf.payment_id, rf.order_id, rf.lines))
     and g.status not in ('cancelled', 'pending_payment') and g.balance < g.initial_amount;
  v_n := booking._refund_gc_apply(rf.id, 'hold');
  insert into booking.audit_log(action, table_name, row_pk, new_data)
  values ('SVC_REFUND_GIFT_CARD_HOLD', 'refunds', rf.id::text, jsonb_build_object('refund_id', rf.id, 'cards_held', v_n, 'cards_with_usage', v_used, 'actor', left(coalesce(p_actor, ''), 80)));
  return jsonb_build_object('ok', true, 'refund_id', rf.id, 'cards_held', v_n, 'cards_with_usage', v_used,
    'cards', (select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'code_last4', right(g.code, 4), 'status', g.status, 'balance', g.balance) order by g.id), '[]'::jsonb)
                from booking.gift_cards g where g.id in (select booking._refund_gc_cards(rf.payment_id, rf.order_id, rf.lines))));
end $function$;
revoke all on function booking.svc_refund_gift_card_hold(bigint, text) from public, anon, authenticated;
grant execute on function booking.svc_refund_gift_card_hold(bigint, text) to service_role;

-- Käyttöpolut: suspended ei käytettävissä; hallinnan suodatin tuntee tilan; mitätöinti toimii myös pidossa olevalle kortille.
CREATE OR REPLACE FUNCTION booking._gc_redeem(p_order_id bigint, p_card_id bigint, p_amount numeric, p_note text, p_public boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o booking.orders; g booking.gift_cards; v_unpaid numeric; v_amt numeric; v_id bigint; rc record; v_excl boolean; v_card booking.gift_cards; v_rest numeric; v_confirmed boolean := false;
        v_own boolean; v_ok numeric; v_left numeric; v_use numeric; ur record; v_cap numeric;
begin
  if not booking._gc_flag('gift_cards.redeem_enabled') then perform booking._err('redeem_disabled', 'Lahjakorttien lunastus ei ole vielä käytössä'); end if;
  select * into o from booking.orders where id = p_order_id for update;
  if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
  if booking._order_invoice_locked(o.id) then perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.'); end if;
  if p_public and o.status = 'expired' then perform booking._err('order_expired', 'Varaus on vanhentunut – tee uusi varaus'); end if;
  if p_public and o.status = 'pending' and o.hold_kind = 'preliminary' then perform booking._err('order_preliminary', 'Alustava varaus: maksu pyydetään vahvistuksen jälkeen'); end if;
  if p_public and o.status = 'pending' and not exists (select 1 from booking.reservations x where x.order_id = o.id and x.status = 'pending' and x.hold_expires_at > now())
     and not booking._order_mp_inflight(o.id) then
    perform booking._err('order_expired', 'Varaus on vanhentunut – tee uusi varaus');
  end if;
  if o.external_source is not null or o.status not in ('pending', 'confirmed', 'completed') or (p_public and o.status = 'completed') then
    perform booking._err('order_not_editable', 'Tilaukselle ei voi kirjata maksua');
  end if;
  if exists (select 1 from booking.order_items oi where oi.order_id = o.id and oi.kind = 'gift_card') then
    perform booking._err('gift_card_not_allowed', 'Lahjakortilla ei voi ostaa lahjakorttia');
  end if;
  select * into g from booking.gift_cards where id = p_card_id for update;
  if not found then perform booking._err('gift_card_not_found', 'Korttia ei löydy'); end if;
  if g.source = 'johku' and not booking._gc_flag('gift_cards.johku_cards_redeemable') then
    perform booking._err('johku_cards_closed', 'Johku-lähtöisten korttien lunastus ei ole vielä käytössä (kortit lunastetaan toistaiseksi Johkussa)');
  end if;
  if g.status in ('cancelled', 'pending_payment', 'pending_verification', 'suspended') then perform booking._err('gift_card_inactive', 'Kortti ei ole käytettävissä'); end if;   -- booking_345: suspended = osto hyvityksessä
  if g.status = 'expired' or (g.valid_to is not null and g.valid_to < booking._gc_today()) then perform booking._err('gift_card_expired', 'Kortin voimassaolo on päättynyt'); end if;
  if g.status = 'used' or g.balance <= 0 then perform booking._err('gift_card_empty', 'Kortin saldo on käytetty'); end if;
  if not g.balance_verified then perform booking._err('gift_card_inactive', 'Kortin saldoa ei ole vahvistettu'); end if;
  -- booking_330: paketin lunastusrajaus (tuote + viikonpäivä) ja tuotteen perushinnan kattava kortti
  if g.package_code is not null and booking._gc_redeem_rules(o.id, g.id) > 0 then
    select * into o from booking.orders where id = o.id;
  end if;
  v_unpaid := case when o.status = 'pending' then greatest(o.total_gross - (booking._order_balance(o.id) ->> 'net_paid')::numeric, 0) else (booking._order_balance(o.id) ->> 'unpaid')::numeric end;
  if v_unpaid <= 0 then perform booking._err('nothing_to_pay', 'Tilauksella ei ole maksettavaa'); end if;
  v_cap := case when g.package_code is not null then booking._gc_redeem_cap(o.id, g.id) end;   -- booking_332: henkilöpääsykortin enimmäissumma
  v_amt := coalesce(p_amount, least(g.balance, v_unpaid, coalesce(v_cap, g.balance)));
  if v_cap is not null and v_amt > v_cap + 0.004 then
    perform booking._err('amount_exceeds_unpaid', format('Kortilla voi maksaa tästä varauksesta enintään %s €', v_cap));
  end if;
  if v_amt is null or v_amt <= 0 or v_amt <> round(v_amt, 2) then perform booking._err('invalid_amount', 'Virheellinen summa'); end if;
  if v_amt > g.balance + 0.004 then perform booking._err('insufficient_balance', format('Kortin saldo on %s €', g.balance)); end if;
  if v_amt > v_unpaid + 0.004 then perform booking._err('amount_exceeds_unpaid', format('Summa ylittää maksamattoman osuuden (%s €)', v_unpaid)); end if;
  v_own := g.source is distinct from 'johku' and g.accounting_origin is distinct from 'johku';
  if v_own and not g.complimentary then
    select coalesce(sum(u.remaining) filter (where u.remaining > 0.004), 0)
      into v_ok from booking._order_uncovered(o.id, false) u;
    if v_amt > v_ok + 0.004 then
      perform booking._err('amount_exceeds_unpaid', 'Summa ylittää tuotteiden maksamattoman osuuden');
    end if;
  end if;
  update booking.payments set status = 'cancelled', note = concat_ws(' | ', note, 'korvattu lahjakorttimaksulla')
   where order_id = o.id and status = 'pending' and external_source is null
     and ((provider = 'manual' and not exists (select 1 from booking.payment_lines pl where pl.payment_id = payments.id)) or provider <> 'manual');
  insert into booking.payments(order_id, method, provider, status, amount, gift_card_id, note, created_by)
  values (o.id, 'gift_card', 'manual', 'pending', v_amt, g.id, nullif(concat_ws(' | ', 'Lahjakortti …' || right(g.code, 4), p_note), ''), auth.uid()) returning id into v_id;
  if v_own then
    v_left := v_amt;
    if abs(v_ok - v_amt) < 0.005 then
      insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
      select v_id, u.item_id, u.description, u.kind, u.quantity, u.remaining, u.vat_rate
        from booking._order_uncovered(o.id, false) u
       where u.remaining > 0.004;
    else
      for ur in select * from booking._order_uncovered(o.id, false) u where u.remaining > 0.004 loop
        exit when v_left <= 0.004;
        v_use := least(ur.remaining, v_left);
        insert into booking.payment_lines(payment_id, order_item_id, description, kind, quantity, amount_gross, vat_rate)
        values (v_id, ur.item_id, ur.description, ur.kind, case when v_use = ur.remaining then ur.quantity else 1 end, v_use, ur.vat_rate);
        v_left := v_left - v_use;
      end loop;
    end if;
  else
    perform booking._alloc_payment_lines(v_id);
  end if;
  update booking.payments set status = 'paid', paid_at = now() where id = v_id;       -- trigger: tiedoksi-kuitti vain maksetulle omalle at_sale-kortille, ei kirjanpitoon
  perform booking._gc_apply(g.id, -v_amt, 'redemption', o.id, v_id, p_note);
  select * into v_card from booking.gift_cards where id = g.id;
  if v_card.single_order and v_card.balance > 0 then
    perform booking._gc_apply(g.id, -v_card.balance, 'single_order_forfeit', o.id, v_id, 'Kertakäyttökortti: jäännös ei käytettävissä');
    select * into v_card from booking.gift_cards where id = g.id;
  end if;
  perform booking._sync_placeholder(o.id);
  perform booking._refresh_order_payment(o.id);
  v_rest := greatest(o.total_gross - (booking._order_balance(o.id) ->> 'net_paid')::numeric, 0);
  if o.status = 'pending' and v_rest <= 0.004 then
    update booking.reservations set status = 'confirmed', hold_expires_at = null where order_id = o.id and status = 'pending';
    update booking.orders set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()) where id = o.id and status = 'pending';
    v_confirmed := true;
  end if;
  v_excl := booking._acct_excluded(o.id, v_id);
  select receipt_no, id into rc from booking.receipts where payment_id = v_id and kind = 'receipt';
  return jsonb_build_object('ok', true, 'payment_id', v_id, 'amount', v_amt, 'order_id', o.id, 'balance', booking._order_balance(o.id),
    'gift_card', jsonb_build_object('id', v_card.id, 'code_last4', right(v_card.code, 4), 'balance', v_card.balance, 'status', v_card.status, 'valid_to', v_card.valid_to),
    'receipt_id', rc.id, 'receipt_no', rc.receipt_no, 'accounted', not v_excl,
    'confirmed', v_confirmed, 'remaining', v_rest, 'order_status', (select status from booking.orders where id = o.id));
end $function$;

CREATE OR REPLACE FUNCTION booking.public_check_gift_card(p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare g booking.gift_cards; v_norm text := booking.gift_code_norm(p_code); v_eff text; v_red boolean; v_why text;
begin
  if booking._gc_rl_blocked() then
    return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen');
  end if;
  if v_norm !~ '^[A-Z0-9]{12}$' then
    perform booking._gc_log('invalid');
    return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', 'Koodia ei löydy tai se ei ole käytettävissä');
  end if;
  select * into g from booking.gift_cards where code = v_norm;
  if not found or g.status in ('cancelled', 'pending_payment', 'suspended') then   -- booking_345: hyvityksessä oleva kortti ei käytettävissä
    perform booking._gc_log('invalid');
    return jsonb_build_object('ok', false, 'code', 'invalid_code', 'message', 'Koodia ei löydy tai se ei ole käytettävissä');
  end if;
  perform booking._gc_log('ok');
  v_eff := case when g.status = 'active' and g.valid_to is not null and g.valid_to < booking._gc_today() then 'expired' else g.status end;
  v_why := case when not booking._gc_flag('gift_cards.redeem_enabled') then 'redeem_disabled'
                when g.source = 'johku' and not booking._gc_flag('gift_cards.johku_cards_redeemable') then 'johku_cards_closed'
                when v_eff = 'expired' then 'expired' when v_eff = 'used' or g.balance <= 0 then 'empty'
                when v_eff = 'pending_verification' or not g.balance_verified then 'verification_pending' end;
  v_red := v_why is null and v_eff = 'active';
  return jsonb_build_object('ok', true, 'code', booking.gift_code_fmt(g.code), 'type', g.kind, 'package_code', g.package_code,
    'package_name', (select p.name from booking.gift_card_packages p where p.code = g.package_code), 'status', v_eff,
    'initial_amount', g.initial_amount, 'balance', g.balance, 'currency', g.currency, 'valid_to', g.valid_to, 'redeemable', v_red, 'not_redeemable_reason', v_why,
    'balance_verified', g.balance_verified, 'restrictions', booking._gc_rules_json(g.package_code));  -- booking_330
end $function$;

CREATE OR REPLACE FUNCTION booking.admin_list_gift_cards(p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_source text DEFAULT NULL::text, p_kind text DEFAULT NULL::text, p_package text DEFAULT NULL::text, p_vat_treatment text DEFAULT NULL::text, p_unverified boolean DEFAULT NULL::boolean, p_expiring_days integer DEFAULT NULL::integer, p_has_balance boolean DEFAULT NULL::boolean, p_sort text DEFAULT 'created_desc'::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_s text := nullif(btrim(coalesce(p_search, '')), ''); v_norm text; v_res jsonb; v_today date := booking._gc_today(); v_lim int := least(greatest(coalesce(p_limit, 50), 1), 200); v_off int := greatest(coalesce(p_offset, 0), 0);
begin
  if not booking.is_staff() then perform booking._err('forbidden', 'Ei oikeuksia'); end if;
  if coalesce(p_sort, 'created_desc') not in ('created_desc', 'created_asc', 'name_asc', 'valid_to_asc', 'valid_to_desc', 'balance_desc', 'balance_asc', 'initial_desc', 'initial_asc') then perform booking._err('invalid_sort', 'Tuntematon lajittelu'); end if;
  if p_status is not null and p_status not in ('active', 'used', 'expired', 'cancelled', 'pending_verification', 'pending_payment', 'suspended') then perform booking._err('invalid_param', 'Virheellinen tila'); end if;
  v_norm := booking.gift_code_norm(v_s);
  with f as (
    select g.*, booking._gc_product_name(g) as pname from booking.gift_cards g
     where (v_s is null or (char_length(v_norm) >= 4 and g.code like '%' || v_norm || '%')
            or g.buyer_name ilike '%' || v_s || '%' or g.buyer_email ilike '%' || v_s || '%' or g.recipient_name ilike '%' || v_s || '%' or g.recipient_email ilike '%' || v_s || '%'
            or booking._gc_product_name(g) ilike '%' || v_s || '%'
            or (v_s ~ '^\d{1,10}$' and exists (select 1 from booking.orders o where o.id = g.purchase_order_id and (o.order_no = v_s::bigint or o.johku_order_no = v_s::bigint))))
       and (p_status is null or case when p_status = 'expired' then (g.status = 'expired' or (g.status = 'active' and g.valid_to < v_today)) when p_status = 'active' then g.status = 'active' and (g.valid_to is null or g.valid_to >= v_today) else g.status = p_status end)
       and (p_source is null or g.source = p_source) and (p_kind is null or g.kind = p_kind) and (p_package is null or g.package_code = p_package)
       and (p_vat_treatment is null or g.vat_treatment = p_vat_treatment) and (p_unverified is null or g.balance_verified = not p_unverified)
       and (p_expiring_days is null or (g.status = 'active' and g.valid_to between v_today and v_today + p_expiring_days))
       and (p_has_balance is null or (g.balance > 0) = p_has_balance)
  ), s as (
    select count(*) c, coalesce(sum(balance), 0) sb, coalesce(sum(initial_amount), 0) si,
           coalesce(sum(balance) filter (where status = 'active' and (valid_to is null or valid_to >= v_today)), 0) sr from f
  ), r as (
    select f.id, f.pname, row_number() over (order by
        (case when p_sort = 'name_asc' then lower(coalesce(nullif(btrim(f.recipient_name), ''), nullif(btrim(f.buyer_name), ''))) end) collate "fi-x-icu" asc nulls last,
        (case when p_sort = 'name_asc' then f.code end) asc,
        (case when p_sort = 'valid_to_asc' then f.valid_to end) asc nulls last, (case when p_sort = 'valid_to_desc' then f.valid_to end) desc nulls last,
        (case when p_sort = 'balance_desc' then f.balance end) desc, (case when p_sort = 'balance_asc' then f.balance end) asc,
        (case when p_sort = 'initial_desc' then f.initial_amount end) desc, (case when p_sort = 'initial_asc' then f.initial_amount end) asc,
        (case when p_sort = 'created_asc' then f.created_at end) asc, (case when p_sort = 'created_asc' then f.id end) asc, f.created_at desc, f.id desc) rn from f
  )
  select jsonb_build_object('total', s.c, 'sum_balance', s.sb, 'sum_initial', s.si, 'sum_balance_redeemable', s.sr,
      'rows', coalesce((select jsonb_agg(booking._gc_card_json(g2, true) || jsonb_build_object('product_name', r.pname) order by r.rn)
                          from r join booking.gift_cards g2 on g2.id = r.id where r.rn > v_off and r.rn <= v_off + v_lim), '[]'::jsonb))
    into v_res from s;
  return v_res;
end $function$;

CREATE OR REPLACE FUNCTION booking._gc_cancel_order_cards(p_order bigint, p_note text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c record; v_n int := 0;
begin
  for c in select id, status, balance from booking.gift_cards where purchase_order_id = p_order and status <> 'cancelled' order by id for update loop
    -- booking_345: tila ensin (hyvityksessä = suspended -kortin saldoa ei voi muuttaa ennen mitätöintiä), sitten saldo nollaan ledgerillä
    update booking.gift_cards set status = 'cancelled', refund_hold_id = null, refund_hold_prev_status = null where id = c.id;
    if c.balance > 0 then perform booking._gc_apply(c.id, -c.balance, 'cancel_refund', p_order, null, p_note); end if;
    if c.balance = 0 then
      insert into booking.gift_card_ledger(gift_card_id, order_id, delta, balance_after, reason, created_by, note) values (c.id, p_order, 0, 0, 'cancel_refund', auth.uid(), p_note);
    end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $function$;

-- ---------- K8: kumppanikoodin lunastus vaatii kumppanin viitteen ----------
create or replace function booking._vc_partner_ref_guard_trg()
 returns trigger language plpgsql set search_path to ''
as $function$
begin
  if new.status = 'redeemed' and nullif(btrim(coalesce(new.partner_ref, '')), '') is null
     and (tg_op = 'INSERT' or old.status is distinct from 'redeemed' or old.partner_ref is distinct from new.partner_ref) then
    perform booking._err('partner_ref_required', 'Anna kumppanin viite (esim. kumppanin tilaus- tai lunastusnumero) ennen kuin merkitset koodin lunastetuksi');
  end if;
  return new;
end $function$;
drop trigger if exists voucher_claims_partner_ref_guard on booking.voucher_claims;
create trigger voucher_claims_partner_ref_guard before insert or update on booking.voucher_claims for each row execute function booking._vc_partner_ref_guard_trg();
