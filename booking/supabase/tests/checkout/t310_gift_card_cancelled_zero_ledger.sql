begin;
-- t310: peruttu nollaledgerin lahjakorttimaksu ei estä maksamatta vanhentuneen verkkotilauksen piilotusta (booking_310, Joonas 14.11.2026 klo 12.34).
-- Vaatii migraatiot ≤ 310 + fixtures/10_test_helpers.sql. Yksi transaktio; lopuksi rollback. VAIN paikalliseen kertakäyttökantaan.
set local lock_timeout = '3s';
set local statement_timeout = '120s';
create temp table t310_r(ok boolean, label text) on commit drop;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$ insert into t310_r values (coalesce(p_ok, false), p_label) $$;
create function pg_temp.run(p_who text, p_sql text, p_user uuid default null, p_ip text default null) returns jsonb language plpgsql as $$
declare v jsonb; d text;
begin
  perform test.reset_rl();
  case p_who when 'anon' then perform test.anon(p_ip); when 'service' then perform test.service(); else perform test.login(p_user); end case;
  begin execute p_sql into v;
  exception when others then
    get stacked diagnostics d = pg_exception_detail;
    v := jsonb_build_object('err', coalesce(nullif(d, ''), sqlstate), 'msg', sqlerrm);
  end;
  perform test.logout();
  return v;
end $$;
-- verkkokaupan varaus (anon) → order id
create function pg_temp.book(p_rule bigint, p_date date, p_email text) returns bigint language plpgsql as $$
declare a jsonb;
begin
  perform test.reset_rl();
  perform test.anon('10.30.9.' || (1 + (random() * 200)::int));
  a := test.pub_book(p_rule, p_date, 2, p_email);
  perform test.logout();
  if not coalesce((a ->> 'ok')::boolean, false) then raise exception 'pub_book: %', a; end if;
  return (test.ord((a ->> 'token')::uuid)).id;
end $$;
-- pito vanhenee: hold_expires_at menneisyyteen + expire_holds (cron-ajo) ; vanhentumisviesti "lähetetään"
create function pg_temp.expire(p_order bigint) returns void language plpgsql as $$
begin
  update booking.reservations set hold_expires_at = now() - interval '1 minute' where order_id = p_order and status = 'pending';
  update booking.payments set raw = coalesce(raw, '{}'::jsonb) || jsonb_build_object('attempt_started_at', now() - interval '2 hours', 'last_state', 'CREATED')
   where order_id = p_order and status = 'pending';
end $$;
create function pg_temp.send_mails(p_order bigint) returns void language sql as $$
  update booking.email_outbox set status = 'sent', sent_at = now(), attempts = 1 where order_id = p_order and status = 'pending' $$;

-- maksamatta vanhentunut verkkotilaus (vanhentumisviesti lähetetty)
create function pg_temp.dead(p_rule bigint, p_date date, p_email text) returns bigint language plpgsql as $$
declare o bigint;
begin
  o := pg_temp.book(p_rule, p_date, p_email);
  perform pg_temp.expire(o); perform booking.expire_holds(); perform pg_temp.send_mails(o);
  return o;
end $$;
-- lahjakortti + lahjakorttimaksu (veloitus kirjattu ledgeriin), palauttaa payment id
create function pg_temp.gc_pay(p_order bigint, p_code text, p_amount numeric, p_status text, p_refund boolean) returns bigint language plpgsql as $$
declare g bigint; p bigint;
begin
  insert into booking.gift_cards(code, issuer, kind, initial_amount, balance, status, source) values (p_code, 'own', 'value', 200, 200, 'active', 'native') returning id into g;
  insert into booking.payments(order_id, method, provider, status, amount, paid_at, gift_card_id) values (p_order, 'gift_card', 'manual', 'cancelled', p_amount, now() - interval '20 minutes', g)
  returning id into p;
  if p_status <> 'cancelled' then update booking.payments set status = p_status where id = p; end if;
  insert into booking.gift_card_ledger(gift_card_id, order_id, payment_id, delta, balance_after, reason, note) values (g, p_order, p, -p_amount, 200 - p_amount, 'redemption', 't310');
  if p_refund then
    insert into booking.gift_card_ledger(gift_card_id, order_id, payment_id, delta, balance_after, reason, note) values (g, p_order, p, p_amount, 200, 'refund', 't310');
    update booking.gift_cards set balance = 200 where id = g;
  else
    update booking.gift_cards set balance = 200 - p_amount where id = g;
  end if;
  return p;
end $$;

do $t$
declare
  v_rule bigint := test.rule('Miesten sauna%'); d date := test.next_dow(1, 20);
  oA bigint; oB bigint; oC bigint; oD bigint; oE bigint; oF bigint; oG bigint; oH bigint; cA bigint; p bigint; v jsonb;
begin
  update booking.settings set value = '"hold_until_paid"'::jsonb where key = 'public_payment_mode';
  update booking.settings set value = '0'::jsonb where key = 'checkout_group_threshold_persons';
  insert into booking.integration_config(key, mode, settings) values ('montonio', 'test', '{"approved_by":"t310"}'::jsonb)
    on conflict (key) do update set mode = 'test', settings = booking.integration_config.settings || '{"approved_by":"t310"}'::jsonb;
  update booking.settings set value = 'true'::jsonb where key = 'expired_unpaid_auto_archive_paused';

  -- A: #15081-tyyppinen: peruttu lahjakorttimaksu, paid_at täytetty, ledger -149 / +149 → piiloon
  oA := pg_temp.dead(v_rule, d, 'a@t310.example');
  p := pg_temp.gc_pay(oA, 'HHT310AAAAA1', 149, 'cancelled', true);
  perform pg_temp.ck((select paid_at is not null and status = 'cancelled' from booking.payments where id = p), 'A0: maksu peruttu, paid_at täytetty');
  perform pg_temp.ck(booking._expired_web_order_archivable(oA), 'A1: peruttu nollaledgerin lahjakorttimaksu ei estä');

  -- B: peruttu, mutta ledger ≠ 0 (veloitus jäi kortille) → estetty
  oB := pg_temp.dead(v_rule, d, 'b@t310.example');
  perform pg_temp.gc_pay(oB, 'HHT310BBBBB1', 50, 'cancelled', false);
  perform pg_temp.ck(not booking._expired_web_order_archivable(oB), 'B1: peruttu mutta ledger ≠ 0 → estetty');

  -- C: aktiivinen (paid) lahjakorttimaksu → estetty (myös nollaledgerilla)
  oC := pg_temp.dead(v_rule, d, 'c@t310.example');
  perform pg_temp.gc_pay(oC, 'HHT310CCCCC1', 40, 'paid', false);
  perform pg_temp.ck(not booking._expired_web_order_archivable(oC), 'C1: aktiivinen lahjakorttimaksu → estetty');
  oD := pg_temp.dead(v_rule, d, 'd@t310.example');
  perform pg_temp.gc_pay(oD, 'HHT310DDDDD1', 40, 'paid', true);
  perform pg_temp.ck(not booking._expired_web_order_archivable(oD), 'C2: maksettu-tilainen lahjakorttimaksu nollaledgerillakin → estetty');

  -- E: peruttu Visma-maksu, jolla paid_at → estetty (vain lahjakorttipoikkeus)
  oE := pg_temp.dead(v_rule, d, 'e@t310.example');
  insert into booking.payments(order_id, method, provider, status, amount, paid_at) values (oE, 'visma_pay', 'visma_pay', 'cancelled', 10, now());
  perform pg_temp.ck(not booking._expired_web_order_archivable(oE), 'E1: peruttu korttimaksu paid_at:lla → estetty');

  -- F: peruttu nollaledgerin lahjakorttimaksu, mutta refunded_amount ≠ 0 → estetty
  oF := pg_temp.dead(v_rule, d, 'f@t310.example');
  p := pg_temp.gc_pay(oF, 'HHT310FFFFF1', 30, 'cancelled', true);
  update booking.payments set refunded_amount = 30 where id = p;
  perform pg_temp.ck(not booking._expired_web_order_archivable(oF), 'F1: hyvitetty (refunded_amount) → estetty');

  -- G: kirjaus toiselle kortille (+/- eri korteilla) → estetty
  oG := pg_temp.dead(v_rule, d, 'g@t310.example');
  p := pg_temp.gc_pay(oG, 'HHT310GGGGG1', 20, 'cancelled', false);
  insert into booking.gift_cards(code, issuer, kind, initial_amount, balance, status, source) values ('HHT310GGGGG2', 'own', 'value', 200, 220, 'active', 'native');
  insert into booking.gift_card_ledger(gift_card_id, order_id, payment_id, delta, balance_after, reason, note)
    select id, oG, p, 20, 220, 'refund', 't310' from booking.gift_cards where code = 'HHT310GGGGG2';
  perform pg_temp.ck(not booking._expired_web_order_archivable(oG), 'G1: palautus eri kortille → estetty');

  -- H: peruttu lahjakorttimaksu paid_at:lla ilman ainuttakaan ledger-riviä → estetty (varovainen)
  oH := pg_temp.dead(v_rule, d, 'h@t310.example');
  insert into booking.gift_cards(code, issuer, kind, initial_amount, balance, status, source) values ('HHT310HHHHH1', 'own', 'value', 200, 200, 'active', 'native');
  insert into booking.payments(order_id, method, provider, status, amount, paid_at, gift_card_id)
    select oH, 'gift_card', 'manual', 'cancelled', 15, now(), id from booking.gift_cards where code = 'HHT310HHHHH1';
  perform pg_temp.ck(not booking._expired_web_order_archivable(oH), 'H1: ei ledger-rivejä → estetty');

  -- S: sweep arkistoi vain A:n; asiakkaan markkinointilupasääntö ennallaan
  select customer_id into cA from booking.orders where id = oA;
  update booking.customers set marketing_consent = true, marketing_consent_at = now() where id = cA;
  update booking.settings set value = 'false'::jsonb where key = 'expired_unpaid_auto_archive_paused';
  v := booking.expired_web_orders_archive_sweep(200);
  perform pg_temp.ck((select archived_at is not null and archive_reason = 'auto:expired_unpaid' and status = 'cancelled' from booking.orders where id = oA),
                 'S1: A arkistoitu ' || v::text);
  perform pg_temp.ck((select bool_and(archived_at is null) from booking.orders where id in (oB, oC, oD, oE, oF, oG, oH)), 'S2: B–H eivät arkistoidu');
  perform pg_temp.ck((select archived_at is null from booking.customers where id = cA), 'S3: markkinointiluvan antanut asiakas jää näkyviin');
  perform pg_temp.ck((select status = 'active' and balance = 200 from booking.gift_cards where code = 'HHT310AAAAA1')
                 and (select count(*) from booking.gift_card_ledger l join booking.gift_cards g on g.id = l.gift_card_id where g.code = 'HHT310AAAAA1') = 2
                 and (select status from booking.payments where order_id = oA and method = 'gift_card') = 'cancelled',
                 'S4: lahjakortti, ledger ja maksu ennallaan (ei rahaliikettä)');
  -- verify-kyselyn rahamääritelmä: A ei ole "rahaa"
  perform pg_temp.ck(not exists (select 1 from booking.payments p2 where p2.order_id = oA
                  and (p2.status in ('paid', 'partially_refunded', 'refunded') or coalesce(p2.refunded_amount, 0) <> 0
                       or (p2.paid_at is not null and not (p2.method = 'gift_card' and p2.status = 'cancelled' and p2.gift_card_id is not null
                            and exists (select 1 from booking.gift_card_ledger l where l.payment_id = p2.id)
                            and not exists (select 1 from booking.gift_card_ledger l where l.payment_id = p2.id and l.gift_card_id is distinct from p2.gift_card_id)
                            and (select sum(l.delta) from booking.gift_card_ledger l where l.payment_id = p2.id) = 0)))),
                 'S5: archived_with_money-määritelmä ei laske A:ta rahaksi');
  -- late payment ei koske: alerts 0
  perform pg_temp.ck((v ->> 'alerts_queued')::int = 0, 'S6: ei late_paid_archived-hälytystä');
  -- K: oikeudet ennallaan
  v := pg_temp.run('anon', format('select to_jsonb(booking._expired_web_order_archivable(%s))', oA), null, '10.30.9.253');
  perform pg_temp.ck(v ? 'err', 'K1: anon ei voi kutsua ' || v::text);
end $t$;
select 'RESULT ' || case when ok then 'ok' else 'NOT OK' end || ' - ' || label from t310_r;
select 'SUMMARY ' || count(*) filter (where not ok) || ' failed / ' || count(*) from t310_r;
rollback;
