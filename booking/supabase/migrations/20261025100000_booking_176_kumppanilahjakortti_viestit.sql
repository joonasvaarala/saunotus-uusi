-- booking_176: kumppanilahjakorttivarauksen asiakasviestit yhteen (omistaja Joonas, hyväksytty malli 25.10.2026).
-- Koskee vain kumppanilahjakorttivarauksia (voucher_claims; maksutavat partner_voucher, partner_voucher_kokemuskauppa, partner_voucher_offerilla, partner_voucher_elamyslahjat).
--   1) Varauksen jälkeen YKSI varausvahvistus (voucher_claim_received, uusi sisältö send-emailsissä): ei erillistä tilausvahvistusta (order_confirmation)
--      eikä ajastettua ohjeviestiä (product_message, kategoria instruction). Ohjeet tulevat vahvistukseen (email_outbox_claim → order.instructions).
--      Useampi koodi samalle tilaukselle → ei uutta vahvistusta, jos edellinen on jonossa tai lähetetty. Jos jonotuksen pyyntö perutaan/vanhenee ennen lähetystä,
--      mutta tilauksella on voimassa oleva pyyntö, sama viesti lähtee sen tiedoilla (email_outbox_claim) → tilaus saa vahvistuksen tasan kerran.
--   2) Lahjakortti kattaa koko summan → lunastuksesta ei viestiä (ennallaan: kumppanimaksun kuitti ilman sähköpostia, booking_174).
--   3) Lahjakortti kattaa osan → yksi yhdistetty viesti (payment_link / voucher_difference: lunastettu ja vahvistettu, summa, arvo, erotus, Maksa nyt).
--      Sama logiikka nyt myös botille (svc_mark_voucher_claim_redeemed) ja vanhalle polulle (admin_/svc_resolve_voucher_claim tila 'redeemed') yhteisen _vc_redeem-funktion kautta.
--   4) Erotus maksettu → ei kuittisähköpostia (vc_difference_payments, seuranta tilauksen/pyynnön mukaan: myös korvaava linkki tai muu tilaussivun maksu erotuslinkin jälkeen);
--      kuitti näkyy tilaussivulla (public_get_order.receipts).
--   5) Lunastus epäonnistuu → ei automaattista viestiä (_vc_notify_problem palauttaa aina false).
--   6) Muiden varausten viestit ennallaan.
--   korvataan (tuotanto -> booking_176):
--     booking._on_payment_paid(bigint): de9084871640d213d10527a045157bf2 -> af7f99e87ba7e00e0d5e3d5b6cbf2400
--     booking.email_outbox_claim(integer): 2db9a1233a06e6293d0877f17de1ab72 -> 70602f6500703e8750e1539ae8809d38
--     booking.orders_confirmed_mail_trg(): 85e59930421bf098d24d7fcebd50507d -> de9df39ff7972a951e61684f8f2db87b
--     booking.public_submit_voucher_claim(uuid,text,text,bigint): de84e5ce9b1062111c4248e7c582fdb8 -> d28a31d27147f4cf7bceb12150c9e77c
--     booking.messages_dispatch(integer): 11a25a5f1e02fe5e635a92d8fea3a69f -> 4b1f94601e23d9dc3eec34bcd5b4dc08
--     booking._vc_notify_problem(bigint): 85f500444e3af880009fc3b6c0e3a402 -> 3414022269f6db113f1085208eb6f040
--     booking.admin_mark_voucher_claim_redeemed(bigint,numeric,text,text): 525d1fa96fd7c37df4d7e502edf1bf71 -> a4e69cb26eb44b72eacce7c167342884
--     booking.svc_mark_voucher_claim_redeemed(bigint,numeric,text,text): ed28a9a7240b2ae62f5abef66885bc5d -> 673f26a88054b2b31dcbab872557e383
--     booking.admin_resolve_voucher_claim(bigint,text,text,text,numeric,text): b7d61783b74032374626c25ea60397b0 -> 41a4f3cc89e802f18e5131f849394188
--     booking.svc_resolve_voucher_claim(bigint,text,text,text,numeric,text): 96bf311a66fb5292f141bcc86621254f -> cc67ebd8ce012211eb603b7f2b1c3ef4
--   uudet funktiot:
--     booking._vc_partner_order(bigint): 9221478413d1e3869021d9e20c20e567
--     booking._vc_redeem(bigint,numeric,text,text,text): 6f52789346960d95370169446a61451b
--   riippuvuudet, ei muuteta (tuotanto = vaadittu):
--     booking._issue_receipt(bigint) ae8b663945b78d1849b0028987689c8e
--     booking.email_outbox_claim_base_146(integer) 9c63ce8c8b6f46347692859a117d110d
--     booking.email_outbox_claim_base_132(integer) 0b10986533285645d8592449a90a1e0c
--     booking.email_outbox_mark(bigint,text,text,text) 2ba0222fdfee71942fb09053bd7ea803
--     booking._enqueue_email(text,bigint,bigint,bigint,text,jsonb) 350304b26e7240c42a6cf38f604eb689
--     booking._vc_pay(booking.orders,booking.voucher_claims,numeric) 3c24fd721b0e8bc6f1bdfb8a800c5a0e
--     booking._vc_due(booking.orders,booking.voucher_claims) bea9cd9a32eb273ee72caed0aedd1e2e
--     booking._vc_mark_redeemed(bigint,numeric,text,text,text) b394cc612bcce278b66f57122aff4ff9
--     booking._vc_resolve(bigint,text,text,text,numeric,text,text) fbd7286dba538f3c223ffd0d1eb1c4b4
--     booking._vc_keep_reserved(bigint) 58d6fb6e5d928b327e122a695a5b557d
--     booking._create_link_payment(bigint,integer,text) 533ac9af831c0c11e1f504e377a17827
--     booking._link_json(bigint) 6244354a24ab97f251f9f80c4b240e1b
--     booking._vismapay_online() defebda157e3c0113a334c3e925dd101
--     booking._is_partner_method(text) 4796edc6ebadaf599fd78287a75d29e8
--     booking._order_short_instructions(bigint,text) a941437f2ef1a380f4213813f207b766
--     booking._order_message_rows(bigint,text,boolean) 47856353d6e38335e14105507af89803
--     booking.admin_create_payment_link(bigint,boolean,integer,text) fef2fe9aa3acf79b233086c133809918
--     booking.public_get_order(uuid) f570384af308e18227c5909d67f451ab
--     booking._clean_company(jsonb) 53fa5a8a98e98aeb4a97000d2f6b37ec
--     booking._stamp_order_billing(bigint,bigint,jsonb) 693f24abfe0dddfbf4a2e345e1596e73
--     booking._invoice_allocate(bigint) 46a3326812f896077fc2614ba783ff3d
--     booking.orders_invoice_draft_trg() a48fe50340cff5f6e9709ad46055ecb9
--     booking._vc_mask(text) 9e612ee37728ef0971d428765ab47e1a
-- Rollback: rollbacks/20261025100000_booking_176_ROLLBACK.sql. Testi: tests/giftcards/t176_kumppanilahjakortti_viestit.sql (BEGIN … ROLLBACK).
set local lock_timeout = '5s';

do $g$
declare v text; ok boolean := true; msg text := '';
begin
  v := md5(pg_get_functiondef(to_regprocedure('booking._on_payment_paid(bigint)')));
  if v is null or v not in ('de9084871640d213d10527a045157bf2', 'af7f99e87ba7e00e0d5e3d5b6cbf2400') then ok := false; msg := msg || ' _on_payment_paid=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.email_outbox_claim(integer)')));
  if v is null or v not in ('2db9a1233a06e6293d0877f17de1ab72', '70602f6500703e8750e1539ae8809d38') then ok := false; msg := msg || ' email_outbox_claim=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.orders_confirmed_mail_trg()')));
  if v is null or v not in ('85e59930421bf098d24d7fcebd50507d', 'de9df39ff7972a951e61684f8f2db87b') then ok := false; msg := msg || ' orders_confirmed_mail_trg=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_submit_voucher_claim(uuid,text,text,bigint)')));
  if v is null or v not in ('de84e5ce9b1062111c4248e7c582fdb8', 'd28a31d27147f4cf7bceb12150c9e77c') then ok := false; msg := msg || ' public_submit_voucher_claim=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.messages_dispatch(integer)')));
  if v is null or v not in ('11a25a5f1e02fe5e635a92d8fea3a69f', '4b1f94601e23d9dc3eec34bcd5b4dc08') then ok := false; msg := msg || ' messages_dispatch=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._vc_notify_problem(bigint)')));
  if v is null or v not in ('85f500444e3af880009fc3b6c0e3a402', '3414022269f6db113f1085208eb6f040') then ok := false; msg := msg || ' _vc_notify_problem=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_mark_voucher_claim_redeemed(bigint,numeric,text,text)')));
  if v is null or v not in ('525d1fa96fd7c37df4d7e502edf1bf71', 'a4e69cb26eb44b72eacce7c167342884') then ok := false; msg := msg || ' admin_mark_voucher_claim_redeemed=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.svc_mark_voucher_claim_redeemed(bigint,numeric,text,text)')));
  if v is null or v not in ('ed28a9a7240b2ae62f5abef66885bc5d', '673f26a88054b2b31dcbab872557e383') then ok := false; msg := msg || ' svc_mark_voucher_claim_redeemed=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_resolve_voucher_claim(bigint,text,text,text,numeric,text)')));
  if v is null or v not in ('b7d61783b74032374626c25ea60397b0', '41a4f3cc89e802f18e5131f849394188') then ok := false; msg := msg || ' admin_resolve_voucher_claim=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.svc_resolve_voucher_claim(bigint,text,text,text,numeric,text)')));
  if v is null or v not in ('96bf311a66fb5292f141bcc86621254f', 'cc67ebd8ce012211eb603b7f2b1c3ef4') then ok := false; msg := msg || ' svc_resolve_voucher_claim=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._vc_partner_order(bigint)')));
  if v is not null and v <> '9221478413d1e3869021d9e20c20e567' then ok := false; msg := msg || ' _vc_partner_order=' || v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._vc_redeem(bigint,numeric,text,text,text)')));
  if v is not null and v <> '6f52789346960d95370169446a61451b' then ok := false; msg := msg || ' _vc_redeem=' || v; end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._issue_receipt(bigint)')));
  if v is distinct from 'ae8b663945b78d1849b0028987689c8e' then ok := false; msg := msg || ' _issue_receipt=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.email_outbox_claim_base_146(integer)')));
  if v is distinct from '9c63ce8c8b6f46347692859a117d110d' then ok := false; msg := msg || ' email_outbox_claim_base_146=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.email_outbox_claim_base_132(integer)')));
  if v is distinct from '0b10986533285645d8592449a90a1e0c' then ok := false; msg := msg || ' email_outbox_claim_base_132=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.email_outbox_mark(bigint,text,text,text)')));
  if v is distinct from '2ba0222fdfee71942fb09053bd7ea803' then ok := false; msg := msg || ' email_outbox_mark=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._enqueue_email(text,bigint,bigint,bigint,text,jsonb)')));
  if v is distinct from '350304b26e7240c42a6cf38f604eb689' then ok := false; msg := msg || ' _enqueue_email=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._vc_pay(booking.orders,booking.voucher_claims,numeric)')));
  if v is distinct from '3c24fd721b0e8bc6f1bdfb8a800c5a0e' then ok := false; msg := msg || ' _vc_pay=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._vc_due(booking.orders,booking.voucher_claims)')));
  if v is distinct from 'bea9cd9a32eb273ee72caed0aedd1e2e' then ok := false; msg := msg || ' _vc_due=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._vc_mark_redeemed(bigint,numeric,text,text,text)')));
  if v is distinct from 'b394cc612bcce278b66f57122aff4ff9' then ok := false; msg := msg || ' _vc_mark_redeemed=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._vc_resolve(bigint,text,text,text,numeric,text,text)')));
  if v is distinct from 'fbd7286dba538f3c223ffd0d1eb1c4b4' then ok := false; msg := msg || ' _vc_resolve=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._vc_keep_reserved(bigint)')));
  if v is distinct from '58d6fb6e5d928b327e122a695a5b557d' then ok := false; msg := msg || ' _vc_keep_reserved=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._create_link_payment(bigint,integer,text)')));
  if v is distinct from '533ac9af831c0c11e1f504e377a17827' then ok := false; msg := msg || ' _create_link_payment=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._link_json(bigint)')));
  if v is distinct from '6244354a24ab97f251f9f80c4b240e1b' then ok := false; msg := msg || ' _link_json=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._vismapay_online()')));
  if v is distinct from 'defebda157e3c0113a334c3e925dd101' then ok := false; msg := msg || ' _vismapay_online=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._is_partner_method(text)')));
  if v is distinct from '4796edc6ebadaf599fd78287a75d29e8' then ok := false; msg := msg || ' _is_partner_method=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._order_short_instructions(bigint,text)')));
  if v is distinct from 'a941437f2ef1a380f4213813f207b766' then ok := false; msg := msg || ' _order_short_instructions=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._order_message_rows(bigint,text,boolean)')));
  if v is distinct from '47856353d6e38335e14105507af89803' then ok := false; msg := msg || ' _order_message_rows=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.admin_create_payment_link(bigint,boolean,integer,text)')));
  if v is distinct from 'fef2fe9aa3acf79b233086c133809918' then ok := false; msg := msg || ' admin_create_payment_link=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.public_get_order(uuid)')));
  if v is distinct from 'f570384af308e18227c5909d67f451ab' then ok := false; msg := msg || ' public_get_order=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._clean_company(jsonb)')));
  if v is distinct from '53fa5a8a98e98aeb4a97000d2f6b37ec' then ok := false; msg := msg || ' _clean_company=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._stamp_order_billing(bigint,bigint,jsonb)')));
  if v is distinct from '693f24abfe0dddfbf4a2e345e1596e73' then ok := false; msg := msg || ' _stamp_order_billing=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._invoice_allocate(bigint)')));
  if v is distinct from '46a3326812f896077fc2614ba783ff3d' then ok := false; msg := msg || ' _invoice_allocate=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking.orders_invoice_draft_trg()')));
  if v is distinct from 'a48fe50340cff5f6e9709ad46055ecb9' then ok := false; msg := msg || ' orders_invoice_draft_trg=' || coalesce(v, 'puuttuu'); end if;
  v := md5(pg_get_functiondef(to_regprocedure('booking._vc_mask(text)')));
  if v is distinct from '9e612ee37728ef0971d428765ab47e1a' then ok := false; msg := msg || ' _vc_mask=' || coalesce(v, 'puuttuu'); end if;
  if not exists (select 1 from pg_trigger t where t.tgrelid = 'booking.orders'::regclass and t.tgname = 'orders_confirmed_upd'
                  and t.tgfoid = 'booking.orders_confirmed_mail_trg()'::regprocedure and not t.tgisinternal) then
    ok := false; msg := msg || ' trigger orders_confirmed_upd puuttuu';
  end if;
  if not ok then raise exception 'booking_176: funktioiden md5 ei vastaa tuotantoa eikä booking_176:tta (%); mitään ei muutettu', msg; end if;
end $g$;

-- Kumppanilahjakortin erotuksen maksulinkit (booking_174/176). Näiden maksujen kuitista ei lähetetä sähköpostia; kuitti näkyy tilaussivulla.
create table if not exists booking.vc_difference_payments(
  id bigint generated always as identity primary key,
  order_id bigint not null references booking.orders(id) on delete cascade,
  claim_id bigint references booking.voucher_claims(id) on delete set null,
  payment_id bigint unique references booking.payments(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists vc_difference_payments_order_idx on booking.vc_difference_payments(order_id);
comment on table booking.vc_difference_payments is 'booking_176: kumppanilahjakortin erotuksen maksulinkit (tilaus, pyyntö, payments.id). _on_payment_paid ei jonota kuittisähköpostia tämän linkin eikä sen jälkeen luodun saman tilauksen maksun (korvaava linkki, tilaussivu) kuitista, kun pyyntö on yhä lunastettu; kuitti näkyy tilaussivulla.';
alter table booking.vc_difference_payments enable row level security;
revoke all on table booking.vc_difference_payments from public, anon, authenticated;
-- jo luodut booking_174-erotuslinkit (jono ja audit)
insert into booking.vc_difference_payments(order_id, claim_id, payment_id, created_at)
select max(p.order_id), max(x.cid), x.pid, min(p.created_at) from (
  select e.payment_id as pid, nullif(e.payload ->> 'claim_id', '')::bigint as cid
    from booking.email_outbox e where e.kind = 'payment_link' and e.payload ->> 'variant' = 'voucher_difference' and e.payment_id is not null
  union all
  select (a.new_data ->> 'link_payment_id')::bigint, a.row_pk::bigint
    from booking.audit_log a where a.action = 'VOUCHER_DIFFERENCE_LINK' and a.table_name = 'booking.voucher_claims' and a.new_data ->> 'link_payment_id' ~ '^[0-9]+$' and a.row_pk ~ '^[0-9]+$'
) x
join booking.payments p on p.id = x.pid
where (x.cid is null or exists (select 1 from booking.voucher_claims vc where vc.id = x.cid))
group by x.pid
on conflict (payment_id) do nothing;

-- 1) booking._vc_partner_order(bigint)
CREATE OR REPLACE FUNCTION booking._vc_partner_order(p_order_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (select 1 from booking.voucher_claims vc where vc.order_id = p_order_id and vc.status in ('open', 'processing', 'problem', 'redeemed'))
$function$;

-- 2) booking._vc_redeem(bigint,numeric,text,text,text)
CREATE OR REPLACE FUNCTION booking._vc_redeem(p_id bigint, p_amount numeric, p_partner_ref text, p_note text, p_by text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c booking.voucher_claims; o booking.orders; v jsonb; v_due numeric; v_link jsonb; v_pid bigint; v_diff numeric; v_mail boolean := false;
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
  -- booking_174 (booking_176: myös botti): arvo pienempi kuin maksettava → erotus maksulinkkinä asiakkaalle (Visma Pay -linkki, sähköposti payment_link / voucher_difference)
  if v_due is not null and p_amount < v_due and not coalesce((v ->> 'already')::boolean, false) and (v ->> 'payment_id') is not null then
    select * into o from booking.orders where id = o.id;
    v_link := booking._create_link_payment(o.id, 14, 'Kumppanilahjakortin erotus, pyyntö #' || p_id);
    v_pid := (v_link ->> 'payment_id')::bigint;
    v_diff := (v_link ->> 'amount')::numeric;
    v_mail := booking._enqueue_email('payment_link', o.id, null, v_pid, 'payment_link:voucher_difference:' || p_id || ':' || v_pid,
                jsonb_build_object('variant', 'voucher_difference', 'claim_id', p_id, 'voucher_value', (v ->> 'amount')::numeric, 'difference', v_diff,
                                   'total', (v ->> 'amount')::numeric + v_diff));
    -- booking_176: erotuksen maksusta ei kuittisähköpostia (_on_payment_paid)
    insert into booking.vc_difference_payments(order_id, claim_id, payment_id) values (o.id, p_id, v_pid) on conflict (payment_id) do nothing;
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
    values (auth.uid(), booking._jwt_role(), 'booking.voucher_claims', p_id::text, 'VOUCHER_DIFFERENCE_LINK', null,
            jsonb_build_object('voucher_value', (v ->> 'amount')::numeric, 'due', v_due, 'difference', v_diff, 'link_payment_id', v_pid, 'email_queued', v_mail, 'by', p_by));
  end if;
  return v || jsonb_build_object('voucher_value', case when (v ->> 'already')::boolean then null else (v ->> 'amount')::numeric end, 'due', v_due,
    'difference', v_diff, 'payment_link', case when v_pid is not null then booking._link_json(v_pid) || jsonb_build_object('online_payment_enabled', booking._vismapay_online()) end,
    'email_queued', v_mail);
end $function$;

-- 3) booking._on_payment_paid(bigint)
CREATE OR REPLACE FUNCTION booking._on_payment_paid(p_payment_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_id bigint; v_order bigint; v_method text;
begin
  v_id := booking._issue_receipt(p_payment_id);
  if v_id is not null then
    select order_id, method into v_order, v_method from booking.payments where id = p_payment_id;
    -- booking_174: kumppanilahjakortti → kuitti vain kirjanpitoon, ei kuittisähköpostia
    if booking._is_partner_method(v_method) then return; end if;
    -- booking_176: kumppanilahjakortin erotuksen maksu → kuitti näkyy tilaussivulla, ei kuittisähköpostia. Seuranta tilauksen/pyynnön mukaan: myös korvaava linkki
    -- (uusi payments.id) tai muu tapa maksaa erotus (tilaussivu) erotuslinkin luonnin jälkeen, kun lunastettu pyyntö on yhä voimassa.
    if exists (select 1 from booking.vc_difference_payments d
                where d.payment_id = p_payment_id
                   or (d.order_id = v_order
                       and d.created_at <= (select pp.created_at from booking.payments pp where pp.id = p_payment_id)
                       and (d.claim_id is null or exists (select 1 from booking.voucher_claims vc where vc.id = d.claim_id and vc.status = 'redeemed')))) then
      return;
    end if;
    perform booking._enqueue_email('receipt', v_order, v_id, p_payment_id, 'receipt:' || v_id);
  end if;
end $function$;

-- 4) booking.email_outbox_claim(integer)
CREATE OR REPLACE FUNCTION booking.email_outbox_claim(p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(case when z.item->>'kind' = 'annual_card_code'
    then z.item || jsonb_build_object('annual_card', booking._annual_card_mail((z.item->>'id')::bigint))
                || coalesce(booking._annual_card_admin_to((z.item->>'id')::bigint), '{}'::jsonb)
    when z.item->>'kind' = 'payment_link'
    then z.item || coalesce((select jsonb_build_object('voucher_difference', jsonb_build_object('total', e.payload -> 'total', 'voucher_value', e.payload -> 'voucher_value', 'difference', e.payload -> 'difference'))
                               from booking.email_outbox e where e.id = (z.item->>'id')::bigint and e.payload ->> 'variant' = 'voucher_difference'), '{}'::jsonb)
    when z.item->>'kind' = 'voucher_claim_received'
    then z.item || coalesce((select jsonb_build_object('order', (z.item->'order') || jsonb_build_object('instructions', booking._order_short_instructions(e.order_id, coalesce(nullif(e.locale, ''), o.locale, 'fi'))))
                               from booking.email_outbox e join booking.orders o on o.id = e.order_id where e.id = (z.item->>'id')::bigint and jsonb_typeof(z.item->'order') = 'object'), '{}'::jsonb)
                -- booking_176: vahvistus tilausta kohden; jos jonotuksen pyyntö on peruttu/vanhentunut mutta tilauksella on voimassa oleva pyyntö, viesti lähtee sen tiedoilla (send-emails ohittaa vain, jos voimassa olevaa ei ole)
                || coalesce((select jsonb_build_object('voucher_claim', jsonb_build_object('claim_id', vc.id, 'status', vc.status, 'source', vc.source, 'code_masked', booking._vc_mask(vc.code), 'problem_code', vc.problem_code,
                                   'hold_until', vc.hold_until, 'created_at', vc.created_at, 'customer_name', vc.customer_name))
                               from booking.email_outbox e join booking.voucher_claims vc on vc.order_id = e.order_id
                              where e.id = (z.item->>'id')::bigint and coalesce(z.item #>> '{voucher_claim,status}', 'cancelled') in ('cancelled', 'expired')
                                and vc.status in ('open', 'processing', 'problem', 'redeemed')
                              order by vc.created_at, vc.id limit 1), '{}'::jsonb)
    else z.item end order by z.ord), '[]'::jsonb)
  from jsonb_array_elements(booking.email_outbox_claim_base_146(p_limit)) with ordinality as z(item, ord);
$function$;

-- 5) booking.orders_confirmed_mail_trg()
CREATE OR REPLACE FUNCTION booking.orders_confirmed_mail_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pid bigint;
begin
  if new.external_source is not null then return null; end if;
  -- booking_176: kumppanilahjakorttivaraus (voucher_claims) → ei erillistä tilausvahvistusta; voucher_claim_received on ainoa varausvahvistus
  if not booking._vc_partner_order(new.id) then
    if booking._enqueue_email('order_confirmation', new.id, null, null, 'order_confirmation:' || new.id) then
      update booking.email_outbox set next_attempt_at = now() + interval '45 seconds' where dedupe_key = 'order_confirmation:' || new.id;
    end if;
  end if;
  for pid in select p.id from booking.payments p
              join booking.gift_cards g on g.id = p.gift_card_id
              where p.order_id = new.id and p.method = 'gift_card' and p.status in ('paid', 'partially_refunded')
                and not exists (select 1 from booking.receipts rc where rc.payment_id = p.id and rc.kind = 'receipt')
                and g.accounting_origin = 'native' and g.source is distinct from 'johku'
                and g.vat_treatment = 'at_sale' and g.complimentary = false
                and not booking._is_johku_row(new.id, p.id)
              order by p.id loop
    perform booking._issue_giftcard_info_receipt(pid);
  end loop;
  for pid in select p.id from booking.payments p
              where p.order_id = new.id and p.method = 'gift_card' and p.status in ('paid', 'partially_refunded')
                and not exists (select 1 from booking.receipts rc where rc.payment_id = p.id and rc.kind = 'receipt')
                and not booking._acct_excluded(new.id, p.id)
              order by p.id loop
    perform booking._on_payment_paid(pid);
  end loop;
  return null;
end $function$;

-- 6) booking.public_submit_voucher_claim(uuid,text,text,bigint)
CREATE OR REPLACE FUNCTION booking.public_submit_voucher_claim(p_token uuid, p_code text, p_source text, p_order_item_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o booking.orders; v_norm text := booking.gift_code_norm(p_code); v_src text := lower(btrim(coalesce(p_source, ''))); c booking.voucher_claims; ex booking.voucher_claims; cu booking.customers;
        v_guess jsonb; v_unpaid numeric; v_n int; v_max int; v_res bigint; v_detail text; v_msg text;
begin
  if booking._gc_rl_blocked() then return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen'); end if;
  if not booking._gc_flag('voucher_claims.enabled') then return jsonb_build_object('ok', false, 'code', 'voucher_claims_disabled', 'message', 'Kumppanilahjakorttien lunastus verkossa ei ole vielä käytössä'); end if;
  if p_token is null or not booking._order_rl('vcsub', p_token, 30, 10) then return jsonb_build_object('ok', false, 'code', 'rate_limited', 'message', 'Liian monta yritystä, yritä hetken kuluttua uudelleen'); end if;
  begin
    select * into o from booking.orders where public_token = p_token for update;
    if not found then perform booking._err('not_found', 'Tilausta ei löydy'); end if;
    if v_src not in ('elamyslahjat', 'kokemuskauppa', 'offerilla') then perform booking._err('invalid_source', 'Valitse lahjakortin myyjä (Kokemuskauppa, Offerilla tai Elämyslahjat)'); end if;
    if v_norm !~ '^[A-Z0-9]{6,24}$' then perform booking._err('invalid_code', 'Tarkista koodi'); end if;
    if o.external_source is not null or o.status not in ('pending', 'confirmed') then perform booking._err('order_not_editable', 'Tilaukselle ei voi kirjata maksua'); end if;
    if o.status = 'pending' and not exists (select 1 from booking.reservations r where r.order_id = o.id and r.status = 'pending' and r.hold_expires_at > now()) then perform booking._err('order_expired', 'Varaus on vanhentunut'); end if;
    if exists (select 1 from booking.order_items oi where oi.order_id = o.id and oi.kind = 'gift_card') then perform booking._err('gift_card_not_allowed', 'Lahjakortilla ei voi ostaa lahjakorttia'); end if;
    if exists (select 1 from booking.gift_cards g where g.code = v_norm and g.status not in ('cancelled', 'pending_payment')) then perform booking._err('use_own_card', 'Koodi on oma lahjakortti: käytä lahjakortin lunastusta'); end if;
    if p_order_item_id is not null and not exists (select 1 from booking.order_items oi where oi.id = p_order_item_id and oi.order_id = o.id) then perform booking._err('invalid_item', 'Tilausriviä ei löydy'); end if;
    v_unpaid := case when o.status = 'pending' then greatest(o.total_gross - (booking._order_balance(o.id) ->> 'net_paid')::numeric, 0) else (booking._order_balance(o.id) ->> 'unpaid')::numeric end;
    if v_unpaid <= 0 then perform booking._err('nothing_to_pay', 'Tilauksella ei ole maksettavaa'); end if;
    -- sama koodi jo aktiivisena tällä tilauksella -> idempotentti; muulla tilauksella tai jo lunastettu -> virhe
    select * into ex from booking.voucher_claims where code = v_norm and status in ('open', 'processing', 'redeemed') limit 1;
    if found then
      if ex.order_id = o.id and ex.status in ('open', 'processing') then
        perform booking._gc_log('ok');
        return jsonb_build_object('ok', true, 'already', true, 'claim_no', ex.id, 'status', 'open', 'source', ex.source, 'source_label', booking._vc_source_label(ex.source), 'code_masked', booking._vc_mask(ex.code), 'hold_until', null);
      end if;
      perform booking._err('code_already_claimed', 'Tämä koodi on jo käytössä toisella varauksella');
    end if;
    select count(*) into v_n from booking.voucher_claims where order_id = o.id and status in ('open', 'processing', 'problem');
    v_max := coalesce((booking._setting('voucher_claims.max_per_order', '10'::jsonb) #>> '{}')::int, 10);
    if v_n >= v_max then perform booking._err('too_many_claims', 'Liian monta lahjakoodia tilauksella'); end if;
    -- ongelmatilassa oleva pyyntö korvataan uudella koodilla/lähteellä
    update booking.voucher_claims set status = 'cancelled', resolved_at = now(), resolved_by = 'customer', notes = concat_ws(E'\n', notes, to_char(now() at time zone 'Europe/Helsinki', 'YYYY-MM-DD HH24:MI') || ' customer: korvattu uudella koodilla')
     where order_id = o.id and status = 'problem' and order_item_id is not distinct from p_order_item_id;
    v_guess := booking._vc_guess(v_norm);
    select * into cu from booking.customers where id = o.customer_id;
    select r.id into v_res from booking.reservations r where r.order_id = o.id and r.status in ('pending', 'confirmed') and r.hidden_at is null order by r.starts_at limit 1;
    insert into booking.voucher_claims(order_id, reservation_id, order_item_id, code, source, source_suggested, customer_name, customer_email, customer_phone, locale)
    values (o.id, v_res, p_order_item_id, v_norm, v_src, v_guess ->> 'source', cu.name, cu.email, cu.phone, case when o.locale in ('fi', 'en', 'sv') then o.locale else 'fi' end) returning * into c;
    perform booking._vc_keep_reserved(o.id);   -- booking_48: varaus ei vanhene pyynnön vuoksi (odottava varaus vahvistetaan, maksamaton saldo jää)
    -- booking_176: yksi varausvahvistus tilausta kohden. Lähettämätön tilausvahvistus ohitetaan; voucher_claim_received jonoon vain, jos tilauksella ei ole jo jonossa tai lähetettyä vahvistusta.
    update booking.email_outbox set status = 'skipped', last_error = 'booking_176: kumppanilahjakorttivaraus, vahvistus voucher_claim_received'
     where dedupe_key = 'order_confirmation:' || o.id and status = 'pending' and attempts = 0;
    if not exists (select 1 from booking.email_outbox e where e.order_id = o.id and e.kind = 'voucher_claim_received' and e.status in ('pending', 'sending', 'sent', 'dry_run', 'failed')) then
      perform booking._enqueue_email('voucher_claim_received', o.id, null, null, 'vcrecv:' || c.id, jsonb_build_object('claim_id', c.id));
    end if;
  exception when sqlstate 'BK001' then
    get stacked diagnostics v_detail = pg_exception_detail, v_msg = message_text;
    if v_detail in ('invalid_code', 'invalid_source', 'not_found') then perform booking._gc_log('invalid'); end if;
    return jsonb_build_object('ok', false, 'code', coalesce(v_detail, 'error'), 'message', v_msg);
  end;
  perform booking._gc_log('ok');
  return jsonb_build_object('ok', true, 'claim_no', c.id, 'status', 'open', 'source', c.source, 'source_label', booking._vc_source_label(c.source), 'code_masked', booking._vc_mask(c.code),
    'payment_method', booking._vc_method(c.source), 'payment_method_label', (select pm.label from booking.payment_methods pm where pm.code = booking._vc_method(c.source)),
    'hold_until', null, 'source_mismatch', (c.source_suggested is not null and c.source_suggested <> c.source and coalesce(v_guess ->> 'confidence', '') in ('high', 'medium')));
end $function$;

-- 7) booking.messages_dispatch(integer)
CREATE OR REPLACE FUNCTION booking.messages_dispatch(p_limit integer DEFAULT 50)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  n integer := 0;
  lim integer := greatest(least(coalesce(p_limit, 50), 200), 1);
  r record;
  v_dedupe text;
  v_action text;
  v_reason text;
  v_ok boolean;
begin
  if booking._setting('messages.timed_enabled', 'false'::jsonb) is distinct from 'true'::jsonb then
    return 0;
  end if;
  for r in
    with pairs as (
      select m.id as message_id, m.category, o.id as order_id, o.customer_id, o.created_at, o.status as order_status, o.payment_status, o.locale,
             coalesce(c.marketing_consent, false) as marketing_consent,
             m.send_amount, m.send_unit, m.send_direction, m.send_anchor,
             (select coalesce(array_agg(rv.starts_at order by rv.starts_at), '{}')
                from booking.reservations rv
                join booking.message_products mp2 on mp2.product_id = rv.product_id and mp2.message_id = m.id
               where rv.order_id = o.id and rv.status in ('confirmed', 'completed') and rv.hidden_at is null) as arrivals
        from booking.messages m
        join booking.orders o on o.status in ('confirmed', 'completed') and o.external_source is null
        left join booking.customers c on c.id = o.customer_id
       where m.active
         and m.delivery_mode = 'scheduled'
         and m.send_amount is not null
         and o.created_at > now() - interval '18 months'
         and exists (
           select 1 from booking.message_products mp
            where mp.message_id = m.id and mp.product_id = any (booking._order_product_ids(o.id)))
         and not exists (
           select 1 from booking.email_outbox e
            where e.dedupe_key = 'product_message:' || m.id::text || ':' || o.id::text)
    ), decided as (
      select p.*, booking._message_decision(p.created_at, p.arrivals, p.send_amount, p.send_unit, p.send_direction, p.send_anchor, now(), p.order_status, p.payment_status, false) as decision
        from pairs p
    )
    select * from decided
     where decision ->> 'action' in ('send', 'skip')
     order by case when decision ->> 'action' = 'send' then 0 else 1 end,
              (decision ->> 'send_at')::timestamptz nulls last, message_id, order_id
     limit lim
  loop
    v_action := r.decision ->> 'action';
    v_reason := coalesce(r.decision ->> 'reason', 'skip');
    v_dedupe := 'product_message:' || r.message_id::text || ':' || r.order_id::text;
    if v_action = 'send' and r.category = 'after_marketing' and r.customer_id is not null and r.marketing_consent is distinct from true then
      insert into booking.email_outbox(kind, order_id, locale, dedupe_key, status, payload, last_error)
      values ('product_message', r.order_id, coalesce(r.locale, 'fi'), v_dedupe, 'skipped', jsonb_build_object('message_id', r.message_id), 'no_consent')
      on conflict (dedupe_key) do nothing;
    elsif v_action = 'send' and r.category = 'instruction' and booking._vc_partner_order(r.order_id) then
      -- booking_176: kumppanilahjakorttivarauksen ohjeet ovat varausvahvistuksessa (voucher_claim_received) → ei erillistä ohjeviestiä
      insert into booking.email_outbox(kind, order_id, locale, dedupe_key, status, payload, last_error)
      values ('product_message', r.order_id, coalesce(r.locale, 'fi'), v_dedupe, 'skipped', jsonb_build_object('message_id', r.message_id), 'partner_voucher')
      on conflict (dedupe_key) do nothing;
    elsif v_action = 'send' then
      v_ok := booking._enqueue_email('product_message', r.order_id, null, null, v_dedupe, jsonb_build_object('message_id', r.message_id));
      if not v_ok and not exists (select 1 from booking.email_outbox e where e.dedupe_key = v_dedupe) then
        insert into booking.email_outbox(kind, order_id, locale, dedupe_key, status, payload, last_error)
        values ('product_message', r.order_id, coalesce(r.locale, 'fi'), v_dedupe, 'skipped', jsonb_build_object('message_id', r.message_id), 'no_email');
      end if;
    else
      insert into booking.email_outbox(kind, order_id, locale, dedupe_key, status, payload, last_error)
      values ('product_message', r.order_id, coalesce(r.locale, 'fi'), v_dedupe, 'skipped', jsonb_build_object('message_id', r.message_id), v_reason)
      on conflict (dedupe_key) do nothing;
    end if;
    n := n + 1;
  end loop;
  return n;
end $function$;

-- 8) booking._vc_notify_problem(bigint)
CREATE OR REPLACE FUNCTION booking._vc_notify_problem(p_id bigint)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  -- booking_176: epäonnistuneesta lunastuksesta ei lähetetä automaattista viestiä (henkilökunta ottaa yhteyttä itse). voucher_claims.problem_emails_enabled ei ohita tätä.
  return false;
end $function$;

-- 9) booking.admin_mark_voucher_claim_redeemed(bigint,numeric,text,text)
CREATE OR REPLACE FUNCTION booking.admin_mark_voucher_claim_redeemed(p_id bigint, p_amount numeric DEFAULT NULL::numeric, p_partner_ref text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform booking._require_permission('giftcards.manage');
  -- booking_176: lunastus + erotuksen maksulinkki yhteisessä _vc_redeem-funktiossa (sama botille)
  return booking._vc_redeem(p_id, p_amount, p_partner_ref, p_note, 'staff');
end $function$;

-- 10) booking.svc_mark_voucher_claim_redeemed(bigint,numeric,text,text)
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

-- 11) booking.admin_resolve_voucher_claim(bigint,text,text,text,numeric,text)
CREATE OR REPLACE FUNCTION booking.admin_resolve_voucher_claim(p_id bigint, p_status text, p_problem_code text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_amount numeric DEFAULT NULL::numeric, p_partner_ref text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  perform booking._require_permission('giftcards.manage');
  -- booking_176: lunastus ('redeemed') samaa polkua kuin admin_mark_voucher_claim_redeemed: arvon tarkistus ja osittaisesta arvosta erotuksen maksulinkki (_vc_redeem)
  if p_status = 'redeemed' and exists (select 1 from booking.voucher_claims vc where vc.id = p_id and vc.status in ('open', 'processing', 'problem')) then
    return booking._vc_redeem(p_id, p_amount, p_partner_ref, p_note, 'staff');
  end if;
  return booking._vc_resolve(p_id, p_status, p_problem_code, p_note, p_amount, p_partner_ref, 'staff');
end $function$;

-- 12) booking.svc_resolve_voucher_claim(bigint,text,text,text,numeric,text)
CREATE OR REPLACE FUNCTION booking.svc_resolve_voucher_claim(p_id bigint, p_status text, p_problem_code text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_amount numeric DEFAULT NULL::numeric, p_partner_ref text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  -- booking_176: lunastus ('redeemed') samaa polkua kuin svc_mark_voucher_claim_redeemed: arvon tarkistus ja osittaisesta arvosta erotuksen maksulinkki (_vc_redeem)
  if p_status = 'redeemed' and exists (select 1 from booking.voucher_claims vc where vc.id = p_id and vc.status in ('open', 'processing')) then
    return booking._vc_redeem(p_id, p_amount, p_partner_ref, p_note, 'bot');
  end if;
  return booking._vc_resolve(p_id, p_status, p_problem_code, p_note, p_amount, p_partner_ref, 'bot');
end $function$;

revoke all on function booking._vc_partner_order(bigint) from public, anon, authenticated;
revoke all on function booking._vc_redeem(bigint,numeric,text,text,text) from public, anon, authenticated;

do $v$
begin
  if md5(pg_get_functiondef('booking._vc_partner_order(bigint)'::regprocedure)) <> '9221478413d1e3869021d9e20c20e567' then raise exception 'booking_176: _vc_partner_order md5 ei vastaa odotettua'; end if;
  if md5(pg_get_functiondef('booking._vc_redeem(bigint,numeric,text,text,text)'::regprocedure)) <> '6f52789346960d95370169446a61451b' then raise exception 'booking_176: _vc_redeem md5 ei vastaa odotettua'; end if;
  if md5(pg_get_functiondef('booking._on_payment_paid(bigint)'::regprocedure)) <> 'af7f99e87ba7e00e0d5e3d5b6cbf2400' then raise exception 'booking_176: _on_payment_paid md5 ei vastaa odotettua'; end if;
  if md5(pg_get_functiondef('booking.email_outbox_claim(integer)'::regprocedure)) <> '70602f6500703e8750e1539ae8809d38' then raise exception 'booking_176: email_outbox_claim md5 ei vastaa odotettua'; end if;
  if md5(pg_get_functiondef('booking.orders_confirmed_mail_trg()'::regprocedure)) <> 'de9df39ff7972a951e61684f8f2db87b' then raise exception 'booking_176: orders_confirmed_mail_trg md5 ei vastaa odotettua'; end if;
  if md5(pg_get_functiondef('booking.public_submit_voucher_claim(uuid,text,text,bigint)'::regprocedure)) <> 'd28a31d27147f4cf7bceb12150c9e77c' then raise exception 'booking_176: public_submit_voucher_claim md5 ei vastaa odotettua'; end if;
  if md5(pg_get_functiondef('booking.messages_dispatch(integer)'::regprocedure)) <> '4b1f94601e23d9dc3eec34bcd5b4dc08' then raise exception 'booking_176: messages_dispatch md5 ei vastaa odotettua'; end if;
  if md5(pg_get_functiondef('booking._vc_notify_problem(bigint)'::regprocedure)) <> '3414022269f6db113f1085208eb6f040' then raise exception 'booking_176: _vc_notify_problem md5 ei vastaa odotettua'; end if;
  if md5(pg_get_functiondef('booking.admin_mark_voucher_claim_redeemed(bigint,numeric,text,text)'::regprocedure)) <> 'a4e69cb26eb44b72eacce7c167342884' then raise exception 'booking_176: admin_mark_voucher_claim_redeemed md5 ei vastaa odotettua'; end if;
  if md5(pg_get_functiondef('booking.svc_mark_voucher_claim_redeemed(bigint,numeric,text,text)'::regprocedure)) <> '673f26a88054b2b31dcbab872557e383' then raise exception 'booking_176: svc_mark_voucher_claim_redeemed md5 ei vastaa odotettua'; end if;
  if md5(pg_get_functiondef('booking.admin_resolve_voucher_claim(bigint,text,text,text,numeric,text)'::regprocedure)) <> '41a4f3cc89e802f18e5131f849394188' then raise exception 'booking_176: admin_resolve_voucher_claim md5 ei vastaa odotettua'; end if;
  if md5(pg_get_functiondef('booking.svc_resolve_voucher_claim(bigint,text,text,text,numeric,text)'::regprocedure)) <> 'cc67ebd8ce012211eb603b7f2b1c3ef4' then raise exception 'booking_176: svc_resolve_voucher_claim md5 ei vastaa odotettua'; end if;
end $v$;
