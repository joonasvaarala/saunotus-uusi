-- Rollback booking_58: paketti kb 7 takaisin piiloon (entiset arvot: public_slots=false, public_weekdays=null, bookable=false, shop_visible=false) ja alkuperäiset tekstit.
-- Jo tehdyt varaukset säilyvät (tämä ei peruuta varauksia).
set local lock_timeout = '5s';
update booking.product_config set public_slots = false, public_weekdays = null, bookable = false, shop_visible = false where product_id = 7;
update kb.products
   set duration_text = 'rituaali 20 min + savusauna 1 h 40 min (verkkokauppa)',
       needs_review = true,
       review_note = 'Ristiriita: verkkokauppa savusaunaa 1 h 40 min; uusi sivusto ''Sisältää 1,5 h savusaunavuoron''.'
 where id = 7;
