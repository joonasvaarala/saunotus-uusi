-- Vain SELECT. Aja Supabase-projektissa sxbofnuisemspgquoxyv (skeema kb), tallenna tulos JSON-tiedostoon
-- (sarake d) ja aja: node scripts/kb-snapshot.mjs polku/export.json
select jsonb_build_object(
  'businesses', (select jsonb_agg(to_jsonb(b)) from kb.businesses b),
  'locations',  (select jsonb_agg(to_jsonb(l)) from kb.locations l),
  'products',   (select jsonb_agg(to_jsonb(p) order by id) from kb.products p),
  'variants',   (select jsonb_agg(to_jsonb(v) order by id) from kb.product_price_variants v),
  'hours',      (select jsonb_agg(to_jsonb(o) order by id) from kb.opening_hours o),
  'events',     (select jsonb_agg(to_jsonb(e) order by id) from kb.event_dates e),
  'policies',   (select jsonb_agg(to_jsonb(p) order by id) from kb.policies p where coalesce(internal,false) = false),
  'faq',        (select jsonb_agg(to_jsonb(f) order by id) from kb.faq f),
  -- booking_158: uuden kaupan tapahtumat etusivun kortteihin (anon-RPC, vain julkiset kentät). Vaatii migraation
  -- 20261024185009_booking_158_events.sql (ajettu tuotannossa); ilman sitä poista tämä rivi (kb-snapshot jättää events_shopin silloin pois → vanha polku).
  'events_shop', booking.public_events(current_date, 'shop')
) as d;
