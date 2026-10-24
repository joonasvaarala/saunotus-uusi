-- =============================================================================
-- booking_154: vuosikortin koodi sähköpostiin myös hallinnasta myönnetylle kortille.
-- 1) booking._annual_card_email_trg: ostettu kortti (purchase_order_id not null) → täsmälleen sama polku kuin booking_146
--    (_enqueue_email tilauksen kautta). Hallinnasta myönnetty kortti (purchase_order_id null) → oma outbox-rivi ilman
--    tilausta: kind 'annual_card_code', order_id null, dedupe_key 'annual_card_code:<kortin id>' (sama avain kuin
--    ostetulla kortilla → yksi viesti per kortti), payload {card_id, source 'admin'} (ei henkilötietoja),
--    locale asiakkaan kielestä (en → en, muuten fi), status kuten _enqueue_email: resend off → skipped, muuten pending.
--    Ei riviä, jos kortti ei ole käytössä, on peruttu, koodi puuttuu, asiakkaalla ei ole kelvollista sähköpostia tai
--    hallinta valitsi "älä lähetä" (transaktiokohtainen asetus booking.annual_card_email = 'skip').
--    Trigger on vain AFTER INSERT: kortin päivitys, uudelleenaktivointi tai koodin vaihto ei koskaan jonota uutta
--    viestiä. Jonossa odottava viesti lukee koodin ja tilan lähetyshetkellä (peruttu / pois käytöstä → ei lähetetä).
--    Jonotuksen virhe ei kaada kortin myöntämistä: virhe audit_logiin (annual_card_email_failed).
-- 2) email_outbox_claim: annual_card-lohkoon kenttä source ('admin' / 'purchase'); tilauksettomalle hallinnan kortin
--    riville vastaanottaja (to, to_name) kortin asiakkaalta lähetyshetkellä. Ostetun kortin rivi ennallaan.
--    send-emails: allowlist ja annualCardBlock ennallaan; pohja käyttää source 'admin' -riville omaa johdantoa.
-- 3) booking.admin_create_annual_card(p_customer_id, p_valid_from, p_valid_to, p_code, p_notes, p_send_email):
--    uusi ylikuormitus (ei oletusarvoja), kutsuu 5-parametrista versiota (ennallaan) ja palauttaa lisäksi
--    email {status}: pending / skipped (lähetys pois päältä) / not_requested / no_email / not_queued.
-- EI takautuvaa lähetystä: migraatio ei lisää outbox-rivejä olemassa oleville korteille (trigger koskee vain uusia).
-- Ei muuta hintoja, ALV:tä, kortin myöntämissääntöjä, admin_annual_card_for_order-funktiota eikä public-skeemaa.
-- Uudelleenajettava: create or replace / drop if exists.
-- Rollback: ../rollbacks/20261024134645_booking_154_ROLLBACK.sql
-- =============================================================================
set local lock_timeout = '5s';

-- ---------------------------------------------------------------- 1) jonotus kortin syntyessä
create or replace function booking._annual_card_email_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_email text; v_lang text; v_mode text;
begin
  if new.purchase_order_id is not null then   -- ostettu kortti: booking_146:n polku sellaisenaan
    begin
      perform booking._enqueue_email('annual_card_code', new.purchase_order_id, null, null,
                                     'annual_card_code:' || new.id::text, jsonb_build_object('card_id', new.id));
    exception when others then   -- viesti ei saa kaataa kortin myöntämistä eikä maksun kirjausta
      insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
      values (null, booking._jwt_role(), 'annual_cards', new.id::text, 'annual_card_email_failed', null,
              jsonb_build_object('order_id', new.purchase_order_id, 'error', sqlerrm));
    end;
    return new;
  end if;
  -- booking_154: hallinnasta myönnetty kortti
  if coalesce(current_setting('booking.annual_card_email', true), '') = 'skip' then return new; end if;
  if new.active is distinct from true or new.revoked_at is not null or btrim(coalesce(new.code, '')) = '' then return new; end if;
  begin
    select c.email, c.language into v_email, v_lang
      from booking.customers c where c.id = new.customer_id and c.anonymized_at is null;
    if v_email is null or not booking._valid_email(v_email) then return new; end if;
    select mode into v_mode from booking.integration_config where key = 'resend';
    insert into booking.email_outbox(kind, order_id, receipt_id, payment_id, locale, dedupe_key, status, payload)
    values ('annual_card_code', null, null, null, case when lower(coalesce(v_lang, '')) like 'en%' then 'en' else 'fi' end,
            'annual_card_code:' || new.id::text, case when coalesce(v_mode, 'off') = 'off' then 'skipped' else 'pending' end,
            jsonb_build_object('card_id', new.id, 'source', 'admin'))
    on conflict (dedupe_key) do nothing;
  exception when others then
    insert into booking.audit_log(actor, actor_role, table_name, row_pk, action, old_data, new_data)
    values (null, booking._jwt_role(), 'annual_cards', new.id::text, 'annual_card_email_failed', null,
            jsonb_build_object('source', 'admin', 'error', sqlerrm));
  end;
  return new;
end $$;
drop trigger if exists annual_cards_email on booking.annual_cards;
create trigger annual_cards_email after insert on booking.annual_cards
  for each row execute function booking._annual_card_email_trg();

-- ---------------------------------------------------------------- 2) claim: source + vastaanottaja tilauksettomalle riville
create or replace function booking._annual_card_mail(p_outbox_id bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('card_id', a.id, 'code', a.code, 'valid_from', a.valid_from, 'valid_to', a.valid_to,
           'active', a.active, 'revoked', a.revoked_at is not null,
           'source', case when a.purchase_order_id is null then 'admin' else 'purchase' end,
           'booking_url', rtrim(coalesce(booking._setting('site_base_url') #>> '{}', ''), '/')
                          || case when e.locale = 'en' then '/en/book/' else '/varaa/' end)
    from booking.email_outbox e
    join booking.annual_cards a on a.id = case when e.payload ->> 'card_id' ~ '^[0-9]+$' then (e.payload ->> 'card_id')::bigint end
   where e.id = p_outbox_id;
$$;

-- vastaanottaja vain tilauksettomalle riville hallinnan kortista: kortin asiakkaan sähköposti lähetyshetkellä
create or replace function booking._annual_card_admin_to(p_outbox_id bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('to', case when booking._valid_email(c.email) then c.email end, 'to_name', c.name)
    from booking.email_outbox e
    join booking.annual_cards a on a.id = case when e.payload ->> 'card_id' ~ '^[0-9]+$' then (e.payload ->> 'card_id')::bigint end
    join booking.customers c on c.id = a.customer_id and c.anonymized_at is null
   where e.id = p_outbox_id and e.order_id is null and a.purchase_order_id is null;
$$;

create or replace function booking.email_outbox_claim(p_limit integer default 20) returns jsonb
language sql volatile security definer set search_path = '' as $$
  select coalesce(jsonb_agg(case when z.item->>'kind' = 'annual_card_code'
    then z.item || jsonb_build_object('annual_card', booking._annual_card_mail((z.item->>'id')::bigint))
                || coalesce(booking._annual_card_admin_to((z.item->>'id')::bigint), '{}'::jsonb)
    else z.item end order by z.ord), '[]'::jsonb)
  from jsonb_array_elements(booking.email_outbox_claim_base_146(p_limit)) with ordinality as z(item, ord);
$$;

-- ---------------------------------------------------------------- 3) Myönnä-dialogin valinta "Lähetä koodi asiakkaalle"
create or replace function booking.admin_create_annual_card(p_customer_id bigint, p_valid_from date, p_valid_to date,
                                                            p_code text, p_notes text, p_send_email boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r jsonb; v_send boolean := coalesce(p_send_email, true); v_status text; v_email text;
begin
  perform booking._require_permission('annual_cards.manage');
  perform set_config('booking.annual_card_email', case when v_send then '' else 'skip' end, true);
  r := booking.admin_create_annual_card(p_customer_id, p_valid_from, p_valid_to, p_code, p_notes);
  perform set_config('booking.annual_card_email', '', true);
  if not v_send then
    v_status := 'not_requested';
  else
    select e.status into v_status from booking.email_outbox e where e.dedupe_key = 'annual_card_code:' || (r ->> 'id');
    if v_status is null then
      select c.email into v_email from booking.customers c where c.id = p_customer_id;
      v_status := case when v_email is null or not booking._valid_email(v_email) then 'no_email' else 'not_queued' end;
    end if;
  end if;
  return r || jsonb_build_object('email', jsonb_build_object('status', v_status));
end $$;

revoke all on function booking._annual_card_email_trg() from public, anon, authenticated;
revoke all on function booking._annual_card_mail(bigint) from public, anon, authenticated;
revoke all on function booking._annual_card_admin_to(bigint) from public, anon, authenticated;
revoke all on function booking.email_outbox_claim(integer) from public, anon, authenticated;
revoke all on function booking.admin_create_annual_card(bigint, date, date, text, text, boolean) from public, anon;
grant execute on function booking.email_outbox_claim(integer) to service_role;
grant execute on function booking.admin_create_annual_card(bigint, date, date, text, text, boolean) to authenticated, service_role;
