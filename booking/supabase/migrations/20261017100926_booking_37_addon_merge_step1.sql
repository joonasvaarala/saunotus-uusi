-- booking_37_addon_merge_step1 (17.10.2026): Johku-lisäpalvelurivit (kb 45 Jalkakylpy ja turvenaamio) -> addon-rivi emovarauksen tietoihin.
-- Additiivinen sarake (näkyvyys) + 7 order_items-rivin muunto paikallaan (kind reservation -> addon id 1). EI uusia rivejä, EI payments/payment_lines/receipts/email_outbox,
-- orders.total_gross ja payment_status EIVÄT muutu (summa sisälsi jo lisäpalvelun). Varmuuskopio: staging/lisapalvelu/backup_before_20261017.json. Rollback: booking_37_38_ROLLBACK.sql.
alter table booking.reservations add column if not exists hidden_at timestamptz;
alter table booking.reservations add column if not exists hidden_reason text;
comment on column booking.reservations.hidden_at is 'Piilotettu näkyvistä (ei poistettu): rivi on yhdistetty emovarauksen lisäpalveluksi. Käytetään yhdessä status=cancelled kanssa (saatavuus/kalenteri ohittavat), listaukset suodattavat hidden_at is null.';
comment on column booking.reservations.hidden_reason is 'Piilotuksen syy, esim. merged_into_addon:order_item=<id>.';

do $$
declare m record; n int; v_a booking.addons; v_before numeric; v_after numeric;
begin
  select * into v_a from booking.addons where id = 1 and code = 'turvenaamio_jalkakylpy';
  if not found then raise exception 'addon 1 puuttuu'; end if;
  for m in select * from (values
    (13679,11596,10223,13678,2,30),
    (13686,11602,10228,13685,2,30),
    (13386,11369,10238,13384,5,75),
    (13691,11606,10263,13690,2,30),
    (13573,11510,10297,13572,1,15),
    (13674,11593,10363,13673,5,75),
    (13641,11569,10382,13640,2,30)
  ) as t(item_id, order_id, res_id, parent_item_id, qty, line_total) loop
    select total_gross into v_before from booking.orders where id = m.order_id;
    update booking.order_items i set
        kind = 'addon', addon_id = v_a.id, product_id = null, product_name = v_a.name,
        price_breakdown = coalesce(i.price_breakdown, '{}'::jsonb) || jsonb_build_object(
            'addon_code', v_a.code, 'name_en', v_a.name_en, 'unit_price', i.unit_price_gross, 'quantity', i.quantity, 'max_per_person', v_a.max_per_person,
            'prepaid', true, 'paid_in', 'johku', 'note', 'Maksettu Johkussa',
            'merged_from', jsonb_build_object('order_item_kind', 'reservation', 'product_id', 45, 'product_name', i.product_name, 'reservation_id', m.res_id, 'migration', 'booking_37'))
      where i.id = m.item_id and i.order_id = m.order_id and i.kind = 'reservation' and i.product_id = 45 and i.parent_item_id = m.parent_item_id
        and i.quantity = m.qty and i.line_total_gross = m.line_total;
    get diagnostics n = row_count;
    if n <> 1 then raise exception 'order_item % ei vastannut odotettua (rows=%)', m.item_id, n; end if;
    select total_gross into v_after from booking.orders where id = m.order_id;
    if v_before is distinct from v_after then raise exception 'orders.total_gross muuttui tilauksella %', m.order_id; end if;
    if (select coalesce(sum(line_total_gross),0) from booking.order_items where order_id = m.order_id) <> v_after then raise exception 'rivisumma <> total tilauksella %', m.order_id; end if;
    if not exists (select 1 from booking.order_items p where p.id = m.parent_item_id and p.order_id = m.order_id and p.kind = 'reservation') then raise exception 'emorivi puuttuu %', m.parent_item_id; end if;
  end loop;
end $$;
