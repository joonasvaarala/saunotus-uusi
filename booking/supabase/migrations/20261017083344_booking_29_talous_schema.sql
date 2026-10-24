-- booking_29_talous_schema (17.10.2026): taloushallinnon taulut, vaihe A–D (additiivinen). Sopimus: /workspace/procountor/KOODARI_talous_A_D_fi.md
-- Uudet taulut: vat_rates, payment_lines, refunds, receipts (+receipt_counters), email_outbox, order_requests, accounting_outbox, integration_config.
-- Muutokset olemassa oleviin: payments + rounding, link_sent_at; role_permissions + payments.refund, reports.view, reports.daily; settings-avaimet.
-- Rollback: booking_29_ROLLBACK.sql. Ei kosketa kb- eikä public-skeemaan.

-- 1) ALV-kannat (validointi; vanhat kannat vain historiaa varten)
create table booking.vat_rates (
  rate       numeric(5,2) primary key check (rate >= 0 and rate <= 100),
  label      text not null,
  active     boolean not null default true,     -- sallittu uusille riveille
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);
insert into booking.vat_rates(rate, label, active, sort_order) values
  (0,    'ALV 0 % / verokanta nolla', true, 10),
  (13.5, 'ALV 13,5 %',                true, 20),
  (25.5, 'ALV 25,5 % (yleinen)',      true, 30),
  (10,   'ALV 10 % (vanha, vain historia)', false, 40),
  (14,   'ALV 14 % (vanha, vain historia)', false, 50),
  (24,   'ALV 24 % (vanha, vain historia)', false, 60);
create function booking._vat_active(p_rate numeric) returns boolean language sql stable security definer set search_path = '' as
$$ select exists (select 1 from booking.vat_rates where rate = p_rate and active) $$;
create function booking.vat_guard_trg() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_table_name = 'order_items' and new.external_source is not null then return new; end if;   -- Johku-historia saa vanhat kannat
  if new.vat_rate is null or not booking._vat_active(new.vat_rate) then
    perform booking._err('invalid_vat', 'ALV-kanta ei ole sallittu: ' || coalesce(new.vat_rate::text, 'tyhjä'));
  end if;
  return new;
end $$;
create trigger order_items_vat_guard before insert on booking.order_items for each row execute function booking.vat_guard_trg();
create trigger addons_vat_guard before insert or update of vat_rate on booking.addons for each row execute function booking.vat_guard_trg();

-- 2) maksun laskurivit (yksi maksu -> monta riviä; yksi tilaus -> monta maksua)
alter table booking.payments add column rounding numeric(6,2) not null default 0;      -- käteispyöristys (0,05 €)
alter table booking.payments add column link_sent_at timestamptz;
create table booking.payment_lines (
  id             bigint generated always as identity primary key,
  payment_id     bigint not null references booking.payments(id) on delete cascade,
  order_item_id  bigint references booking.order_items(id) on delete set null,
  description    text not null,
  kind           text not null default 'reservation',
  quantity       integer not null default 1,
  amount_gross   numeric(10,2) not null,                       -- voi olla negatiivinen (alennus)
  refunded_gross numeric(10,2) not null default 0 check (abs(refunded_gross) <= abs(amount_gross)),   -- hyvitetty osuus (sama etumerkki kuin amount_gross)
  vat_rate       numeric(5,2) not null check (vat_rate >= 0 and vat_rate <= 100),
  line_vat       numeric generated always as (round(amount_gross * vat_rate / (100 + vat_rate), 2)) stored,
  line_net       numeric generated always as (amount_gross - round(amount_gross * vat_rate / (100 + vat_rate), 2)) stored,
  created_at     timestamptz not null default now()
);
create index payment_lines_payment_idx on booking.payment_lines(payment_id);
create index payment_lines_item_idx on booking.payment_lines(order_item_id);

-- 3) hyvitykset
create table booking.refunds (
  id                 bigint generated always as identity primary key,
  payment_id         bigint not null references booking.payments(id) on delete restrict,
  order_id           bigint not null references booking.orders(id) on delete restrict,
  amount             numeric(10,2) not null check (amount > 0),
  reason             text,
  status             text not null default 'requested' check (status in ('requested','processing','done','failed','cancelled')),
  provider           text not null default 'manual',
  provider_refund_id text,
  provider_status    text,
  lines              jsonb,                                    -- [{payment_line_id, amount}]
  raw                jsonb,
  created_by         uuid,
  created_at         timestamptz not null default now(),
  done_at            timestamptz,
  updated_at         timestamptz not null default now()
);
create index refunds_payment_idx on booking.refunds(payment_id);
create index refunds_order_idx on booking.refunds(order_id);
create unique index refunds_provider_uq on booking.refunds(provider, provider_refund_id) where provider_refund_id is not null;

-- 4) kuitit (muuttumaton snapshot; aukoton numerointi)
create table booking.receipt_counters (
  series   text not null,
  year     integer not null,
  last_seq integer not null default 0,
  primary key (series, year)
);
create table booking.receipts (
  id                  bigint generated always as identity primary key,
  receipt_no          text not null unique,
  kind                text not null check (kind in ('receipt','refund_receipt')),
  series              text not null,
  year                integer not null,
  seq                 integer not null,
  order_id            bigint not null references booking.orders(id) on delete restrict,
  payment_id          bigint not null references booking.payments(id) on delete restrict,
  refund_id           bigint references booking.refunds(id) on delete restrict,
  original_receipt_id bigint references booking.receipts(id) on delete restrict,
  issued_at           timestamptz not null default now(),
  total_gross         numeric(10,2) not null,                  -- negatiivinen hyvityskuitilla
  currency            text not null default 'EUR',
  locale              text not null default 'fi',
  snapshot            jsonb not null,
  text_body           text not null,
  public_token        uuid not null default gen_random_uuid() unique,
  pdf_path            text,
  pdf_generated_at    timestamptz,
  sent_at             timestamptz,
  created_by          uuid,
  unique (series, year, seq),
  check ((kind = 'receipt' and refund_id is null) or (kind = 'refund_receipt' and refund_id is not null))
);
create unique index receipts_one_per_payment on booking.receipts(payment_id) where kind = 'receipt';
create unique index receipts_one_per_refund on booking.receipts(refund_id) where refund_id is not null;
create index receipts_order_idx on booking.receipts(order_id);
create index receipts_issued_idx on booking.receipts(issued_at);
create function booking.receipts_guard_trg() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then perform booking._err('receipt_immutable', 'Kuittia ei voi poistaa (säilytysvelvollisuus 6 v)'); end if;
  if (new.receipt_no, new.kind, new.series, new.year, new.seq, new.order_id, new.payment_id, new.refund_id, new.original_receipt_id, new.issued_at, new.total_gross, new.snapshot, new.text_body, new.public_token)
     is distinct from
     (old.receipt_no, old.kind, old.series, old.year, old.seq, old.order_id, old.payment_id, old.refund_id, old.original_receipt_id, old.issued_at, old.total_gross, old.snapshot, old.text_body, old.public_token) then
    perform booking._err('receipt_immutable', 'Kuittia ei voi muuttaa (vain pdf_path/pdf_generated_at/sent_at)');
  end if;
  return new;
end $$;
create trigger receipts_guard before update or delete on booking.receipts for each row execute function booking.receipts_guard_trg();

-- 5) sähköpostijono (Resend; send-emails edge-funktio)
create table booking.email_outbox (
  id              bigint generated always as identity primary key,
  kind            text not null check (kind in ('order_confirmation','payment_link','receipt','refund_receipt','cancel_request_ack','order_change')),
  order_id        bigint references booking.orders(id) on delete cascade,
  receipt_id      bigint references booking.receipts(id) on delete restrict,
  payment_id      bigint references booking.payments(id) on delete cascade,
  locale          text not null default 'fi',
  dedupe_key      text not null unique,
  status          text not null default 'pending' check (status in ('pending','sending','sent','failed','dead','skipped','dry_run')),
  attempts        integer not null default 0,
  max_attempts    integer not null default 6,
  next_attempt_at timestamptz not null default now(),
  locked_at       timestamptz,
  provider_id     text,
  last_error      text,
  payload         jsonb not null default '{}'::jsonb,           -- ei henkilötietoja; vastaanottaja luetaan lähetyshetkellä
  created_at      timestamptz not null default now(),
  sent_at         timestamptz
);
create index email_outbox_due_idx on booking.email_outbox(next_attempt_at) where status in ('pending','failed');
create index email_outbox_order_idx on booking.email_outbox(order_id);

-- 6) asiakkaan pyynnöt (peruutus, aikamuutos, hyvitys erotuksesta) – henkilökunta käsittelee aina
create table booking.order_requests (
  id          bigint generated always as identity primary key,
  order_id    bigint not null references booking.orders(id) on delete cascade,
  kind        text not null check (kind in ('cancel','change','refund_due')),
  status      text not null default 'open' check (status in ('open','handled','rejected')),
  reason      text check (reason is null or char_length(reason) <= 1000),
  payload     jsonb,
  created_at  timestamptz not null default now(),
  handled_by  uuid,
  handled_at  timestamptz,
  note        text
);
create unique index order_requests_one_open on booking.order_requests(order_id, kind) where status = 'open';
create index order_requests_status_idx on booking.order_requests(status, created_at);

-- 7) integraatioiden tila ja kirjanpidon jono (valmius; ei käytössä)
create table booking.integration_config (
  key        text primary key check (key in ('resend','vismapay','procountor')),
  mode       text not null default 'off' check (mode in ('off','dry_run','live')),
  settings   jsonb not null default '{}'::jsonb,               -- EI salaisuuksia (ne Edge-salaisuuksiin)
  notes      text,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
insert into booking.integration_config(key, mode, settings, notes) values
  ('resend',    'dry_run', '{"from":"Sipoonjoen perinnesauna <savusauna@saunotus.fi>","reply_to":"savusauna@saunotus.fi"}', 'Salaisuus RESEND_API_KEY (Edge). live vasta kun avain ja domain on todennettu.'),
  ('vismapay',  'off',     '{"version":"w3.2","currency":"EUR"}', 'Salaisuudet VISMAPAY_API_KEY, VISMAPAY_PRIVATE_KEY. Vaatii kauppiassopimuksen ja hyvityksen aktivoinnin Vismalta.'),
  ('procountor','off',     '{"environment":"pts"}', 'Salaisuudet PROCOUNTOR_CLIENT_ID, PROCOUNTOR_CLIENT_SECRET, PROCOUNTOR_API_KEY. Ks. PLAN_fi.md.');
create table booking.accounting_outbox (
  id               bigint generated always as identity primary key,
  kind             text not null check (kind in ('sales_invoice','credit_note','daily_summary','receipt','refund_receipt','invoice_payment','giftcard_sale','giftcard_redemption','customer_upsert')),
  target           text not null default 'procountor' check (target in ('procountor')),
  environment      text not null default 'pts' check (environment in ('pts','prod')),
  order_id         bigint references booking.orders(id) on delete restrict,
  payment_id       bigint references booking.payments(id) on delete restrict,
  receipt_id       bigint references booking.receipts(id) on delete restrict,
  summary_date     date,
  dedupe_key       text not null unique,
  payload          jsonb not null,
  status           text not null default 'pending' check (status in ('pending','processing','sent','failed','dead','skipped','needs_review')),
  attempts         integer not null default 0,
  max_attempts     integer not null default 8,
  last_error       text,
  next_attempt_at  timestamptz not null default now(),
  locked_at        timestamptz,
  locked_by        text,
  procountor_ids   jsonb,
  created_at       timestamptz not null default now(),
  processed_at     timestamptz,
  check (order_id is not null or summary_date is not null)
);
create index accounting_outbox_due_idx on booking.accounting_outbox(next_attempt_at) where status in ('pending','failed');

-- 7b) asetukset (myyjän tiedot kuitille kb.businesses-taulusta; muokattavissa settings-avaimella)
insert into booking.settings(key, value, description, is_public)
select 'seller', jsonb_build_object('name', 'Havuhattu Oy / Sipoonjoen perinnesauna', 'legal_name', b.legal_name, 'trade_name', b.trade_name,
         'business_id', b.business_id, 'vat_id', 'FI' || regexp_replace(b.business_id, '\D', '', 'g'),
         'street', b.street_address, 'postal_code', b.postal_code, 'city', b.city, 'country', b.country,
         'email', b.email, 'phone', b.phone, 'website', b.website, 'logo_url', null, 'footer', 'Kiitos käynnistä!'),
       'Myyjän tiedot kuiteille (kuitin snapshot kopioi nämä)', false
  from kb.businesses b where b.id = 1
on conflict (key) do nothing;
insert into booking.settings(key, value, description, is_public) values
  ('site_base_url', to_jsonb('https://saunotus.fi'::text), 'Verkkokaupan osoite (linkit viesteihin); vahvista lopullinen osoite', false),
  ('payment_link_path', to_jsonb('/maksa/'::text), 'Maksulinkin polku (?p=<link_token>)', false),
  ('order_page_path', to_jsonb('/tilaus/'::text), 'Asiakkaan tilaussivun polku (?t=<public_token>)', false)
on conflict (key) do nothing;

-- 8) oikeudet ja RLS
insert into booking.role_permissions(role_code, permission) values
  ('manager','payments.refund'), ('admin','payments.refund'),
  ('manager','reports.view'), ('admin','reports.view'),
  ('staff','reports.daily'), ('manager','reports.daily'), ('admin','reports.daily')
on conflict do nothing;

do $$ declare t text; begin
  foreach t in array array['vat_rates','payment_lines','refunds','receipt_counters','receipts','email_outbox','order_requests','integration_config','accounting_outbox'] loop
    execute format('alter table booking.%I enable row level security', t);
    execute format('revoke all on booking.%I from public, anon, authenticated', t);
    execute format('grant all on booking.%I to service_role', t);
  end loop;
  foreach t in array array['vat_rates','payment_lines','refunds','receipts','email_outbox','order_requests','integration_config'] loop
    execute format('grant select on booking.%I to authenticated', t);
    execute format('create policy staff_read on booking.%I for select to authenticated using ((select booking.is_staff()))', t);
  end loop;
  foreach t in array array['vat_rates','payment_lines','refunds','receipts','order_requests','integration_config'] loop
    perform booking._add_audit(format('booking.%I', t)::regclass);
  end loop;
end $$;
grant usage, select on all sequences in schema booking to service_role;
