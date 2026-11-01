-- t227: tuntematon Johku-tuote menee tarkistukseen, eikä tilaan ei_resurssia.
-- Varaus, joka jo istuu tilassa ei_resurssia ja jonka meta tarvitsee huoneen tai saunottajan,
-- sulkee Raunin ja saunottajan (booking_227).
-- Ajo migraatioiden jälkeen: psql -X -v ON_ERROR_STOP=1 -f booking/supabase/tests/t227_johku_unmapped_review.sql
-- Lopun poikkeus kumoaa rivit. Ei tuotantoon.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '90s';
create temp table t227_r(ok boolean, label text) on commit drop;
grant all on t227_r to public;
create function pg_temp.ck(p_ok boolean, p_label text) returns void language sql as $$
  insert into t227_r values (coalesce(p_ok, false), p_label) $$;

do $t$
declare
  v jsonb;
  v_ei bigint;
  v_rauni bigint;
  v_none bigint;
  v_oid bigint;
  v_bad bigint;
  v_harmless bigint;
  v_cancelled bigint;
  v_code text;
  v_slack_hit integer;
  v_slack_free integer;
  v_start timestamptz := '2031-06-03 12:00:00+03';
  v_end timestamptz := '2031-06-03 14:30:00+03';
  v_free_start timestamptz := '2031-08-04 12:00:00+03';
  v_free_end timestamptz := '2031-08-04 14:30:00+03';
begin
  perform test.service();

  select id into v_ei from booking.resources where code = 'ei_resurssia';
  select id into v_rauni from booking.resources where code = 'rauni';
  select pc.product_id into v_none
    from booking.product_config pc
   where pc.resource_class in ('none', 'text_only')
     and not exists (
       select 1 from booking.product_space_rules psr
        where psr.product_id = pc.product_id and psr.active and psr.role = 'space' and psr.selection = 'auto')
   order by pc.product_id
   limit 1;
  perform pg_temp.ck(v_ei is not null and v_rauni is not null and v_none is not null, 'A0: ei_resurssia, rauni ja tilaton tuote');

  v := booking.svc_johku_sync_apply(jsonb_build_object(
    'customers', jsonb_build_array(jsonb_build_object(
      'external_id', '880227', 'name', 'T227 Asiakas', 'email', 't227@example.test',
      'country', 'FI', 'language', 'fi', 'customer_kind', 'private', 'marketing_consent', false)),
    'orders', jsonb_build_array(jsonb_build_object(
      'external_id', '8802271', 'johku_order_no', 8802271, 'customer_ext', '880227',
      'status', 'confirmed', 'payment_status', 'paid', 'total_gross', 270,
      'locale', 'fi', 'customer_kind', 'private')),
    'items', jsonb_build_array(jsonb_build_object(
      'external_id', '8802272', 'order_ext', '8802271', 'johku_product_id', '999002',
      'product_name', 'Tuntematon hoito', 'kind', 'reservation', 'quantity', 1,
      'unit_price_gross', 270, 'line_total_gross', 270, 'vat_rate', 25.5,
      'price_breakdown', jsonb_build_object('johku_role', 'line'))),
    'reservations', jsonb_build_array(jsonb_build_object(
      'external_id', '8802273', 'order_ext', '8802271', 'item_ext', '8802272',
      'johku_product_id', '999002', 'persons', 2, 'status', 'confirmed',
      'starts_at', '2031-06-02T11:00:00+03:00', 'ends_at', '2031-06-02T13:30:00+03:00',
      'pool_codes', '[]'::jsonb))));
  perform pg_temp.ck((v ->> 'ok')::boolean, 'A1: apply ok: ' || coalesce(v ->> 'code', ''));
  perform pg_temp.ck(exists (
      select 1 from jsonb_array_elements(v -> 'review') e
       where e ->> 'kind' = 'reservation' and e ->> 'external_id' = '8802273' and e ->> 'code' = 'unmapped_product'),
    'A2: tuntematon Johku-tuote → review unmapped_product');
  perform pg_temp.ck(not exists (
      select 1 from booking.reservations r where r.external_source = 'johku' and r.external_id = '8802273'),
    'A3: varausta ei luotu');

  v := booking.svc_johku_sync_apply(jsonb_build_object(
    'orders', jsonb_build_array(jsonb_build_object(
      'external_id', '8802275', 'johku_order_no', 8802275, 'customer_ext', '880227',
      'status', 'confirmed', 'payment_status', 'paid', 'total_gross', 10,
      'locale', 'fi', 'customer_kind', 'private')),
    'items', jsonb_build_array(jsonb_build_object(
      'external_id', '8802276', 'order_ext', '8802275', 'johku_product_id', '999001',
      'kb_product_id', v_none, 'product_name', 'Tilaton', 'kind', 'reservation', 'quantity', 1,
      'unit_price_gross', 10, 'line_total_gross', 10, 'vat_rate', 25.5,
      'price_breakdown', jsonb_build_object('johku_role', 'line'))),
    'reservations', jsonb_build_array(jsonb_build_object(
      'external_id', '8802277', 'order_ext', '8802275', 'item_ext', '8802276',
      'johku_product_id', '999001', 'kb_product_id', v_none, 'persons', 1, 'status', 'confirmed',
      'starts_at', '2031-06-02T11:00:00+03:00', 'ends_at', '2031-06-02T12:00:00+03:00',
      'pool_codes', '[]'::jsonb))));
  perform pg_temp.ck((v ->> 'ok')::boolean
      and not exists (select 1 from jsonb_array_elements(v -> 'review') e where e ->> 'external_id' = '8802277' and e ->> 'code' = 'unmapped_product'),
    'B1: resource_class none/text_only ei ole unmapped: ' || coalesce(v ->> 'review', '[]'));
  perform pg_temp.ck(exists (
      select 1 from booking.reservations r
       where r.external_source = 'johku' and r.external_id = '8802277' and r.space_id = v_ei and r.mode = 'shared'),
    'B2: tilaton tuote saa tilan ei_resurssia');

  v := booking.svc_johku_sync_apply(jsonb_build_object(
    'orders', jsonb_build_array(jsonb_build_object(
      'external_id', '8802278', 'johku_order_no', 8802278, 'customer_ext', '880227',
      'status', 'confirmed', 'payment_status', 'paid', 'total_gross', 149,
      'locale', 'fi', 'customer_kind', 'private')),
    'items', jsonb_build_array(jsonb_build_object(
      'external_id', '8802280', 'order_ext', '8802278', 'johku_product_id', '134',
      'product_name', 'Perinnesaunotus kahdelle', 'kind', 'reservation', 'quantity', 1,
      'unit_price_gross', 149, 'line_total_gross', 149, 'vat_rate', 25.5,
      'price_breakdown', jsonb_build_object('johku_role', 'line'))),
    'reservations', jsonb_build_array(jsonb_build_object(
      'external_id', '8802281', 'order_ext', '8802278', 'item_ext', '8802280',
      'johku_product_id', '134', 'persons', 2, 'status', 'confirmed',
      'starts_at', '2031-06-04T12:00:00+03:00', 'ends_at', '2031-06-04T14:30:00+03:00',
      'pool_codes', '[]'::jsonb))));
  perform pg_temp.ck((v ->> 'ok')::boolean, 'C0: mapped apply ok');
  perform pg_temp.ck(exists (
      select 1 from booking.reservations r
       where r.external_id = '8802281' and r.product_id = 23 and r.space_id = v_rauni and r.mode = 'exclusive'
         and r.claim_minutes is null and r.ends_at - r.starts_at = interval '2 hours 30 minutes'),
    'C1: Johku 134 ilman kb-id:tä → tuote 23, Rauni exclusive, 2,5 h säilyy');
  perform pg_temp.ck(not exists (
      select 1 from jsonb_array_elements(v -> 'review') e where e ->> 'external_id' = '8802281' and e ->> 'code' = 'unmapped_product'),
    'C2: kartoitettu tuote ei ole unmapped');

  insert into booking.orders(status, payment_status, total_gross, source_channel, customer_kind)
  values ('confirmed', 'paid', 270, 'johku_import', 'private')
  returning id into v_oid;

  insert into booking.reservations(
    order_id, space_id, mode, starts_at, ends_at, persons, status,
    external_source, external_id, external_meta, claim_offset_min)
  values (
    v_oid, v_ei, 'shared', v_start, v_end, 2, 'confirmed',
    'johku', '8802282', '{"source":"johku","johku_product_id":"134"}'::jsonb, 0)
  returning id into v_bad;

  insert into booking.reservations(
    order_id, space_id, mode, starts_at, ends_at, persons, status,
    external_source, external_id, external_meta, claim_offset_min)
  values (
    v_oid, v_ei, 'shared', v_free_start, v_free_end, 1, 'confirmed',
    'johku', '8802283', '{"model":{"kind":"rental","skill":null,"resource_class":"none"}}'::jsonb, 0)
  returning id into v_harmless;

  insert into booking.reservations(
    order_id, space_id, mode, starts_at, ends_at, persons, status,
    external_source, external_id, external_meta, claim_offset_min, cancelled_at, cancel_reason)
  values (
    v_oid, v_ei, 'shared', v_start, v_end, 2, 'cancelled',
    'johku', '8802284', '{"johku_product_id":"134"}'::jsonb, 0, now(), 'johku_import')
  returning id into v_cancelled;

  perform pg_temp.ck(booking._johku_unmapped_needs_room('{"johku_product_id":"134"}'::jsonb, null), 'D1: Johku 134 tarvitsee Raunin');
  perform pg_temp.ck(booking._johku_unmapped_skill('{"johku_product_id":"134"}'::jsonb) = 'saunotus', 'D2: Johku 134 taito saunotus');
  perform pg_temp.ck(
    booking._johku_unmapped_needs_room('{"model":{"resource_class":"resourced","skill":"saunotus","closure_group":"perinnesaunotus"}}'::jsonb, null)
    and booking._johku_unmapped_skill('{"model":{"resource_class":"resourced","skill":"saunotus","closure_group":"perinnesaunotus"}}'::jsonb) = 'saunotus',
    'D3: model.resource_class + skill');
  perform pg_temp.ck(
    not booking._johku_unmapped_needs_room('{"model":{"resource_class":"none","skill":null}}'::jsonb, null)
    and booking._johku_unmapped_skill('{"model":{"resource_class":"none","skill":null}}'::jsonb) is null,
    'D4: resource_class none ei tarvitse huonetta eikä saunottajaa');
  perform pg_temp.ck(
    not booking._johku_unmapped_needs_room('{"model":{"resource_class":"resourced","skill":"yleinen"}}'::jsonb, 27),
    'D5: kb 27 (auto-tila ei_resurssia) ei sulje Raunia');

  perform pg_temp.ck(exists (
      select 1 from booking.v_claims c
      join booking.resources rs on rs.id = c.resource_id and rs.code = 'rauni'
     where c.reservation_id = v_bad and c.role = 'space' and c.mode = 'exclusive'
       and c.claim_end - c.claim_start = interval '2 hours 30 minutes'),
    'E1: claim on Rauni, ikkuna on varauksen 2,5 h');
  perform pg_temp.ck(exists (
      select 1 from booking.v_claims c
      join booking.resources rs on rs.id = c.resource_id and rs.code = 'saunottaja'
     where c.reservation_id = v_bad and c.role = 'therapist' and c.skill = 'saunotus'),
    'E2: saunottaja-claim, taito saunotus');
  perform pg_temp.ck(
    booking._private_overlap_code(v_rauni, 'shared', v_start, v_end, null, null) = 'private_booked',
    'E3: jaettu vuoro Raunissa estyy');
  v_code := test.code(format(
    'select booking._check_claim(null, null, %s, ''space'', ''shared'', %L, %L, 1, null, null, null)',
    v_rauni, v_start, v_start + interval '20 minutes'));
  perform pg_temp.ck(v_code = 'private_booked', 'E4: _check_claim rituaali-ikkuna: ' || coalesce(v_code, 'null'));
  perform pg_temp.ck(
    booking._private_overlap_code(v_rauni, 'shared', v_free_start, v_free_end, null, null) is null,
    'E5: resource_class none ei sulje Raunia');
  perform pg_temp.ck(
    booking._private_overlap_code(v_rauni, 'shared', v_start, v_end, null, null) = 'private_booked'
    and not exists (
      select 1 from booking.v_claims c
      join booking.resources rs on rs.id = c.resource_id and rs.code = 'rauni'
     where c.reservation_id = v_cancelled and booking._res_active(c.status, c.hold_expires_at)),
    'E6: peruttu rivi ei ole aktiivinen claim');

  v_slack_hit := booking._therapist_slack('saunotus', v_start, v_end, 1, null, null, null);
  v_slack_free := booking._therapist_slack('saunotus', v_free_start, v_free_end, 1, null, null, null);
  perform pg_temp.ck(v_slack_hit < v_slack_free, 'E7: saunottajan slack pienenee päällekkäin (' || v_slack_hit || ' < ' || v_slack_free || ')');

  raise exception 'TESTRESULT pass=% fail=% :: %',
    (select count(*) from t227_r where ok),
    (select count(*) from t227_r where not ok),
    coalesce((select string_agg(label, ' | ') from t227_r where not ok), 'ALL OK');
end $t$;
