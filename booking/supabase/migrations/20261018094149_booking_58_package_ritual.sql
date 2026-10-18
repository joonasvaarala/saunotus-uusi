-- ============================================================
-- booking_58_package_ritual: paketti kb 7 "Saunarituaali ja savusaunavuoro (la & su)" verkkokauppaan (slot-polku)
-- Logiikka oli jo toteutettu (booking_15/17a/21/23/25): legit 0–20 Rauni (rituaalipooli 17, 6 hlö jaettu saunotusrituaalin kanssa, session_exclusive-poissulku hoidoille/saunotuksille),
-- tauko 20–30, savusauna 30–120 (90 min, pooli yleinen_vkp_<alku+30>), aloitusajat 16:00/16:30/17:00 (time_window_rules 'ritual'), saunottajaleg 0–20.
-- Tämä migraatio vain KYTKEE tuotteen myyntiin: public_slots + bookable + shop_visible + public_weekdays = la, su, sekä korjaa kesto-tekstin (90 min) ja sulkee tarkistuslipun.
-- Hinta/ALV ennallaan (kb.products: 49 €/hlö, ALV 25,5 % sis.). Rollback: rollbacks/CHECKOUT_booking_58_ROLLBACK.sql
-- ============================================================
set local lock_timeout = '5s';

do $$
declare n_legs int; v_ok boolean;
begin
  -- varmistus: odotettu legirakenne (ei kytketä myyntiin rikkinäistä mallia)
  select count(*) into n_legs from booking.product_space_rules where product_id = 7 and active;
  select bool_and(case leg_no when 1 then (space_id = 1 and mode = 'shared' and offset_min = 30 and minutes = 90 and pool_id is null)
                              when 2 then (space_id = 12 and mode = 'shared' and offset_min = 0 and minutes = 20 and pool_id = 17) else false end) into v_ok
    from booking.product_space_rules where product_id = 7 and active;
  if n_legs <> 2 or v_ok is not true then raise exception 'tuotteen 7 legirakenne ei ole odotettu (legit=%, ok=%)', n_legs, v_ok; end if;
  if not exists (select 1 from booking.product_config where product_id = 7 and resource_class = 'resourced' and time_window_class = 'ritual' and start_pool_prefix = 'yleinen_vkp_') then
    raise exception 'tuotteen 7 product_config ei ole odotettu';
  end if;
end $$;

update booking.product_config
   set public_slots = true, public_weekdays = array[6, 7]::smallint[], bookable = true, shop_visible = true
 where product_id = 7;

update kb.products
   set duration_text = 'rituaali 20 min + tauko 10 min + savusauna 1 h 30 min (yhteensä 2 h)',
       needs_review = false,
       review_note = coalesce(review_note, '') || ' | 18.10.2026 Joonas: savusaunaosa on 90 min (alkaa 30 min kohdalla), ristiriita ratkaistu; kytketty verkkokauppaan (booking_58).'
 where id = 7;
