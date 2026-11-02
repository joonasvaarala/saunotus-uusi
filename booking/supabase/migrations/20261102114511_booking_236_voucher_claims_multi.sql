-- booking_236: useampi kumppanilahjakortti samaan tilaukseen, yksi erotuksen maksulinkki.
--
-- svc_mark_voucher_claim_redeemed kirjaa yhden pyynnön ja lähettää erotuksesta oman maksulinkin.
-- Kaksi 25 € korttia 58 € tilauksella tuottaa siksi linkit 33 € ja 8 €. Oikein on yksi linkki 8 €
-- (tilauksen summa miinus korttien arvot miinus muut maksut) ja yksi sähköposti.
-- p_value_card true käyttää samaa arvolahjakortin introa kuin booking_229 (payload value_card).
--
-- Uusi bottifunktio (service_role), yksi allekirjoitus (ei ylikuormia):
--   svc_mark_voucher_claims_redeemed(p_claim_ids bigint[], p_amount numeric default null, p_amounts numeric[] default null,
--                                    p_partner_ref text default null, p_note text default null, p_value_card boolean default false)
--   p_amount: sama arvo jokaiselle pyynnölle (toinen argumentti kuten yhden kortin svc_mark_voucher_claim_redeemed).
--   p_amounts: p_amounts[i] on p_claim_ids[i]:n arvo.
--   Anna joko p_amount tai p_amounts, ei molempia. Ilman kumpaakaan vain yksi pyyntö (koko maksettava, kuten yhden kortin p_amount null).
-- Esimerkki (PostgREST rpc nimetyillä argumenteilla):
--   select booking.svc_mark_voucher_claims_redeemed(p_claim_ids := array[101,102], p_amount := 25, p_value_card := true);
--   select booking.svc_mark_voucher_claims_redeemed(p_claim_ids := array[101,102], p_amounts := array[25,30]);
--
-- Kirjaus tapahtuu booking._vc_mark_redeemed-apufunktiolla (sama kuin yhden kortin polku; se ei itse tee linkkiä eikä viestiä).
-- svc_mark_voucher_claim_redeemed ja _vc_redeem jätetään ennalleen (ei md5-muutosta).
-- Lukitus: pyynnöt id-järjestyksessä, sitten tilaus (sama järjestys kuin yhden kortin polussa: pyyntö → tilaus).
-- Laskulukko: booking._order_invoice_locked → BK001 / order_invoiced, ei kirjoituksia.
-- Erotus > 0 → yksi booking._create_link_payment ja yksi payment_link-sähköposti kaikkien kirjausten jälkeen.
-- Erotus <= 0 → ei linkkiä eikä sähköpostia.
--
-- Rollback: rollbacks/20261102130000_booking_236_ROLLBACK.sql

set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $need$
begin
  if to_regprocedure('booking._vc_mark_redeemed(bigint,numeric,text,text,text)') is null then
    raise exception 'booking_236: booking._vc_mark_redeemed puuttuu';
  end if;
  if to_regprocedure('booking._order_invoice_locked(bigint)') is null then
    raise exception 'booking_236: booking._order_invoice_locked puuttuu';
  end if;
  if to_regprocedure('booking._create_link_payment(bigint,integer,text)') is null then
    raise exception 'booking_236: booking._create_link_payment puuttuu';
  end if;
  if to_regprocedure('booking.svc_mark_voucher_claim_redeemed(bigint,numeric,text,text,boolean)') is null then
    raise exception 'booking_236: booking.svc_mark_voucher_claim_redeemed (booking_229) puuttuu';
  end if;
end $need$;

-- Sisäinen. Lukitsee pyynnöt id-järjestyksessä, kirjaa jokaisen _vc_mark_redeemed-kutsulla ja tekee enintään yhden linkin.
create or replace function booking._vc_redeem_many(
  p_claim_ids bigint[],
  p_amounts numeric[],
  p_partner_ref text,
  p_note text,
  p_by text,
  p_value_card boolean
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_n int;
  v_found int;
  v_norders int;
  v_order bigint;
  v_redeemed int;
  v_open int;
  v_bad int;
  v_amt numeric;
  v_sum numeric := 0;
  v_rec_sum numeric := 0;
  v_nulls int := 0;
  v_due numeric;
  v_payable boolean := false;
  v_paid_ok boolean := true;
  v_card boolean := coalesce(p_value_card, false);
  v_ids bigint[] := '{}';
  v_claims jsonb := '[]'::jsonb;
  o booking.orders;
  v jsonb;
  v_link jsonb;
  v_pid bigint;
  v_diff numeric;
  v_mail boolean := false;
  rec record;
  i int;
begin
  if p_by not in ('staff', 'bot') then
    perform booking._err('invalid_actor', 'staff tai bot');
  end if;
  if p_claim_ids is null or coalesce(cardinality(p_claim_ids), 0) = 0 then
    perform booking._err('invalid_ids', 'Anna vähintään yksi lunastuspyyntö');
  end if;
  if exists (select 1 from unnest(p_claim_ids) u(id) where u.id is null) then
    perform booking._err('invalid_ids', 'Lunastuspyynnön tunniste puuttuu');
  end if;
  v_n := cardinality(p_claim_ids);
  if (select count(distinct u.id) from unnest(p_claim_ids) u(id)) <> v_n then
    perform booking._err('duplicate_claim', 'Sama lunastuspyyntö on listalla kahdesti');
  end if;
  if p_note is not null and char_length(p_note) > 1000 then
    perform booking._err('invalid_note', 'Muistiinpano enintään 1000 merkkiä');
  end if;

  if p_amounts is null then
    if v_n <> 1 then
      perform booking._err('invalid_amount', 'Anna jokaisen lahjakortin arvo');
    end if;
    p_amounts := array[null::numeric];
  elsif coalesce(cardinality(p_amounts), 0) <> v_n then
    perform booking._err('invalid_amount', 'Lahjakortin arvoja pitää olla yhtä monta kuin pyyntöjä');
  elsif v_n > 1 and exists (select 1 from unnest(p_amounts) a(amt) where a.amt is null) then
    perform booking._err('invalid_amount', 'Anna jokaisen lahjakortin arvo');
  end if;

  for i in 1..v_n loop
    v_amt := p_amounts[i];
    if v_amt is null then
      v_nulls := v_nulls + 1;
    elsif v_amt <= 0 or v_amt <> round(v_amt, 2) then
      perform booking._err('invalid_amount', 'Lahjakortin arvon pitää olla yli 0 € (enintään 2 desimaalia)');
    else
      v_sum := v_sum + v_amt;
    end if;
  end loop;
  if v_nulls > 0 then
    v_sum := null;
  end if;

  -- Lukitus id-järjestyksessä, jotta rinnakkainen yhden kortin kutsu ei jumitu.
  perform 1
    from booking.voucher_claims
   where id = any (p_claim_ids)
   order by id
   for update;

  select count(*) into v_found
    from booking.voucher_claims
   where id = any (p_claim_ids);
  if v_found <> v_n then
    perform booking._err('not_found', 'Lunastuspyyntöä ei löydy');
  end if;

  select count(distinct order_id), min(order_id)
    into v_norders, v_order
    from booking.voucher_claims
   where id = any (p_claim_ids);
  if v_norders <> 1 then
    perform booking._err('different_orders', 'Lunastuspyynnöt kuuluvat eri tilauksiin');
  end if;

  select * into o from booking.orders where id = v_order for update;
  if not found then
    perform booking._err('not_found', 'Tilausta ei löydy');
  end if;

  select count(*) filter (where status = 'redeemed'),
         count(*) filter (where status in ('open', 'processing')),
         count(*) filter (where status not in ('open', 'processing', 'redeemed'))
    into v_redeemed, v_open, v_bad
    from booking.voucher_claims
   where id = any (p_claim_ids);

  -- Yhden kortin semantiikka: kaikki jo lunastettu → ok, already, ei uutta linkkiä eikä viestiä.
  if v_redeemed = v_n then
    return jsonb_build_object(
      'ok', true,
      'already', true,
      'order_id', v_order,
      'claim_ids', (select coalesce(jsonb_agg(c.id order by c.id), '[]'::jsonb) from booking.voucher_claims c where c.id = any (p_claim_ids)),
      'voucher_value', null,
      'due', null,
      'difference', null,
      'payment_link', null,
      'email_queued', false,
      'value_card', (select bool_and(c.value_card) from booking.voucher_claims c where c.id = any (p_claim_ids))
    );
  end if;

  if booking._order_invoice_locked(o.id) then
    perform booking._err('order_invoiced', 'Tilaus on laskutettu: rivejä ja maksuja ei voi muuttaa. Tee korjaus hyvityslaskulla.');
  end if;

  if v_bad > 0 or v_redeemed > 0 or v_open <> v_n then
    perform booking._err('invalid_state', 'Kaikki pyynnöt eivät ole lunastettavissa');
  end if;

  v_payable := o.status in ('pending', 'confirmed') and o.external_source is null;
  if v_payable then
    -- Sama maksettava kuin booking._vc_due ilman rivikohtaista kattoa: tilauksen summa miinus muut maksut.
    v_due := case when o.status = 'pending'
      then greatest(o.total_gross - (booking._order_balance(o.id) ->> 'net_paid')::numeric, 0)
      else (booking._order_balance(o.id) ->> 'unpaid')::numeric
    end;
    if v_sum is not null and v_sum > v_due then
      perform booking._err('voucher_exceeds_total', format('Lahjakorttien arvo %s € ylittää maksettavan summan %s €', v_sum, v_due));
    end if;
  end if;

  for rec in
    select c.id, u.amt
      from unnest(p_claim_ids, p_amounts) as u(id, amt)
      join booking.voucher_claims c on c.id = u.id
     order by c.id
  loop
    v := booking._vc_mark_redeemed(rec.id, rec.amt, p_partner_ref, p_note, p_by);
    if coalesce((v ->> 'already')::boolean, false) or (v ->> 'payment_id') is null then
      v_paid_ok := false;
    end if;
    -- Rivikohtainen katto (_vc_pay / _vc_due): kirjattu summa ei saa jäädä pyydettyä pienemmäksi. Virhe peruu koko kutsun.
    if v_payable and rec.amt is not null and coalesce((v ->> 'amount')::numeric, 0) <> rec.amt then
      perform booking._err('voucher_exceeds_total', format('Lahjakortin arvo %s € ylittää maksettavan summan (pyyntö #%s)', rec.amt, rec.id));
    end if;
    if not coalesce((v ->> 'already')::boolean, false) then
      update booking.voucher_claims set value_card = v_card where id = rec.id;
    end if;
    v_rec_sum := v_rec_sum + coalesce((v ->> 'amount')::numeric, 0);
    v_ids := v_ids || rec.id;
    v_claims := v_claims || jsonb_build_array(jsonb_build_object(
      'id', rec.id,
      'amount', v -> 'amount',
      'payment_id', v -> 'payment_id',
      'status', v -> 'status',
      'already', coalesce((v ->> 'already')::boolean, false),
      'value_card', v_card
    ));
  end loop;

  if v_payable and v_paid_ok and v_sum is not null and v_due is not null and v_sum < v_due then
    v_link := booking._create_link_payment(o.id, null::integer, 'Kumppanilahjakortin erotus, pyynnöt #' || array_to_string(v_ids, ','));
    v_pid := (v_link ->> 'payment_id')::bigint;
    v_diff := (v_link ->> 'amount')::numeric;
    if v_pid is not null and v_diff > 0 then
      v_mail := booking._enqueue_email(
        'payment_link', o.id, null, v_pid,
        'payment_link:voucher_difference:' || array_to_string(v_ids, '-') || ':' || v_pid,
        jsonb_build_object(
          'variant', 'voucher_difference',
          'claim_id', v_ids[1],
          'claim_ids', to_jsonb(v_ids),
          'voucher_value', v_sum,
          'difference', v_diff,
          'total', v_sum + v_diff,
          'value_card', v_card
        )
      );
      insert into booking.vc_difference_payments(order_id, claim_id, payment_id)
      values (o.id, v_ids[1], v_pid)
      on conflict (payment_id) do nothing;
      insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
      values (
        auth.uid(), booking._jwt_role(), 'booking.voucher_claims', v_ids[1]::text, 'VOUCHER_DIFFERENCE_LINK', null,
        jsonb_build_object(
          'voucher_value', v_sum, 'due', v_due, 'difference', v_diff,
          'link_payment_id', v_pid, 'email_queued', v_mail, 'by', p_by,
          'value_card', v_card, 'claim_ids', to_jsonb(v_ids)
        )
      );
    else
      v_pid := null;
      v_diff := 0;
      v_link := null;
    end if;
  elsif v_payable and (v_sum is null or (v_due is not null and v_sum >= v_due)) then
    v_diff := 0;
  end if;

  return jsonb_build_object(
    'ok', true,
    'already', false,
    'order_id', v_order,
    'claim_ids', to_jsonb(v_ids),
    'claims', v_claims,
    'voucher_value', v_rec_sum,
    'due', v_due,
    'difference', v_diff,
    'payment_link', case when v_pid is not null then booking._link_json(v_pid) || jsonb_build_object('online_payment_enabled', booking._montonio_online()) end,
    'email_queued', v_mail,
    'value_card', v_card
  );
end
$function$;

revoke all on function booking._vc_redeem_many(bigint[], numeric[], text, text, text, boolean) from public, anon, authenticated, service_role;

comment on function booking._vc_redeem_many(bigint[], numeric[], text, text, text, boolean) is
  'booking_236: usean kumppanilahjakortin lunastus samaan tilaukseen. Sisäinen. service_role ei saa kutsua suoraan.';

-- Yksi allekirjoitus. Nimetyt argumentit (PostgREST) ja kutsu pelkällä p_claim_ids:llä ovat yksiselitteisiä.
create or replace function booking.svc_mark_voucher_claims_redeemed(
  p_claim_ids bigint[],
  p_amount numeric default null,
  p_amounts numeric[] default null,
  p_partner_ref text default null,
  p_note text default null,
  p_value_card boolean default false
) returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if p_amount is not null and p_amounts is not null then
    perform booking._err('invalid_amount', 'Anna joko p_amount tai p_amounts, ei molempia');
  end if;
  if p_amount is not null and p_claim_ids is not null and coalesce(cardinality(p_claim_ids), 0) > 0 then
    return booking._vc_redeem_many(
      p_claim_ids,
      array_fill(p_amount, array[cardinality(p_claim_ids)]),
      p_partner_ref, p_note, 'bot', coalesce(p_value_card, false)
    );
  end if;
  return booking._vc_redeem_many(p_claim_ids, p_amounts, p_partner_ref, p_note, 'bot', coalesce(p_value_card, false));
end
$function$;

revoke all on function booking.svc_mark_voucher_claims_redeemed(bigint[], numeric, numeric[], text, text, boolean) from public, anon, authenticated;
grant execute on function booking.svc_mark_voucher_claims_redeemed(bigint[], numeric, numeric[], text, text, boolean) to service_role;

comment on function booking.svc_mark_voucher_claims_redeemed(bigint[], numeric, numeric[], text, text, boolean) is
  'booking_236: botti lunastaa usean kumppanilahjakortin samaan tilaukseen, yksi erotuksen maksulinkki. p_amount (sama arvo kaikille) tai p_amounts[i] = p_claim_ids[i]:n arvo. p_value_card boolean default false. service_role.';
