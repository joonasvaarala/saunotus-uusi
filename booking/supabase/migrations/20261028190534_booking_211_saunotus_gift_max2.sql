-- booking_211: lahjakorttipaketti "Savusaunaelämys ja saunotus" (saunotus_2) enintään 2 hengelle (Joonas 28.10.2026).
-- Hinta ja sisältö ennallaan (2 hlö = 328 €). Palvelin hylkää > 2 hengen oston booking._gc_quote:n kautta (invalid_persons),
-- ja public_gift_card_packages palauttaa max_persons = 2, jolloin lahjakorttisivun henkilömäärävalitsin pysähtyy kahteen.
update booking.gift_card_packages
   set max_persons = 2, updated_at = now()
 where code = 'saunotus_2' and max_persons is distinct from 2;

do $$
begin
  if (select max_persons from booking.gift_card_packages where code = 'saunotus_2') is distinct from 2
     or (select price from booking.gift_card_packages where code = 'saunotus_2') is distinct from 328.00 then
    raise exception 'booking_211: saunotus_2 max_persons/price ei odotettu';
  end if;
end $$;
