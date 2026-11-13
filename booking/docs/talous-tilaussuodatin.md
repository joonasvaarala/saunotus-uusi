# Talous: tilauslistan oletus on maksetut

Hallinnan Talous-sivun tilauslista (`booking/admin/views/talous-orders.js`). Migraatio `booking_76` lisää `admin_list_orders`-funktioon parametrin `p_payment_filter` (oletus `paid`). Migraatiota ei ole ajettu tuotantoon tästä muutoksesta.

## Maksutilat ja tilauksen tila

`orders.payment_status` (booking_02, booking_90): `unpaid`, `pending`, `paid`, `partially_paid`, `refunded`, `partially_refunded`, `failed`, `invoiced`.

`orders.status`: `draft`, `pending`, `confirmed`, `cancelled`, `expired`, `completed`.

Maksurivin tila on eri joukko (`pending`, `paid`, `failed`, `cancelled`, `refunded`, `partially_refunded`). Listan nettomaksu lasketaan riveistä, joiden tila on `paid`, `partially_refunded` tai `refunded`, miinus `refunded_amount`.

## Päätös

Oletus `paid` (valikon **Maksetut**) näyttää tilauksen vain kun kaikki kolme täyttyvät:

1. `payment_status` on `paid` tai `partially_refunded`. Osittainen hyvitys on ollut maksettu, joten se pysyy oletuksessa.
2. Nettomaksu on yli 0,00 €. Kokonaan hyvitetty (`refunded`, netto 0) ei näy.
3. Tilauksen tila ei ole `cancelled` eikä `expired`.

`partially_paid` ei ole oletuksessa. Rahaa on tullut, mutta tilaus ei ole kokonaan maksettu. Se on valikossa **Maksamattomat**.

Johku-tilauksella ei ole `payments`-rivejä (booking_41). Jos maksutila on `paid` tai `partially_refunded` eikä maksurivejä ole, nettomaksuna käytetään `total_gross`. Muuten Johku-maksetut katoaisivat listasta, koska `paid`-summa riveistä on 0.

| Valinta | `p_payment_filter` | Mitä näkyy |
|---|---|---|
| Maksetut (oletus) | `paid` | paid ja partially_refunded, netto > 0, ei peruttu eikä vanhentunut |
| Maksamattomat | `unpaid` | unpaid, pending, failed, partially_paid; ei peruttu eikä vanhentunut |
| Laskutetut | `invoiced` | payment_status invoiced; ei peruttu eikä vanhentunut. Ei kuulu Maksetut-suodattimeen (raha ei ole vielä tullut). |
| Kaikki | `all` | ei maksu- eikä peruutusrajausta (muut suodattimet ennallaan) |
| Hyvitetyt | `refunded` | refunded ja partially_refunded |
| Peruttu | `cancelled` | tilauksen tila cancelled tai expired |

`partially_refunded` näkyy sekä Maksetuissa että Hyvitetyissä. Peruttu kattaa myös vanhentuneen pidon (`expired`), koska se on pois oletuksesta eikä sillä ole omaa valintaa.

Vanha parametri `p_payment_status` rajaa yhä yhteen maksutilaan ja yhdistyy AND-ehtona. Kutsu, joka haluaa pelkän vanhan tarkan tilan koko kannasta, lähettää `p_payment_filter` = `all`.

## Haku

Palvelin ei laajenna hakua itse. Hallinta lähettää `p_payment_filter` = `all`, kun hakukentässä on tekstiä ja valinta on yhä oletus Maksetut. Maksamaton tilaus löytyy numerolla tai nimellä. Jos käyttäjä on valinnut Maksamattomat, Laskutetut, Hyvitetyt, Peruttu tai Kaikki, haku pysyy siinä joukossa. Kun haku tyhjennetään, oletus palaa. Haun aikana näkyy teksti «Haku kaikista tilauksista».

Valittu maksutila näkyy siruna, kun suodatinpaneeli on kiinni. Oletus Maksetut ei kasvata «Suodattimia: N» -lukua, koska se on oletus. Kaikki kasvattaa.

## Yhteensopivuus

Uusi parametri on viimeinen ja sillä on oletus `paid`. Vanha 11 argumentin kutsu toimii: PostgreSQL käyttää oletusta. Funktiosta on kannassa yksi versio (vanha allekirjoitus poistetaan), jotta PostgREST ei jää kahden ylikuormituksen väliin.

Kutsu ilman uutta parametria palauttaa siis maksetut, ei enää koko kantaa. Koko lista: `p_payment_filter` = `all`.

## Ajo

- Migraatio: `booking/supabase/migrations/20261018210000_booking_76_orders_payment_filter.sql`
- Rollback: `booking/supabase/rollbacks/20261018210000_booking_76_ROLLBACK.sql` (palauttaa booking_38:n funktion)
- SQL-testi: `booking/supabase/tests/talous/t76_list_orders_payment_filter.sql`
- Tekstit: `content/site-texts.pending-import-8.json` (`admin_texts_import`, ei ylikirjoita olemassa olevia avaimia)

Numerot 72–75 ovat varattuja. Tämä on 76.

## Maksutilanapit (booking_277)

Hallinnan Tilaukset-välilehdellä ei ole enää Maksutila-pudotusvalikkoa. Hakukentän alla on nappi jokaiselle maksutilalle: Maksetut, Maksamattomat, Laskutetut, Kaikki, Hyvitetyt ja Peruttu. Napit näkyvät myös silloin, kun suodatinpaneeli on kiinni.

- Napit ovat monivalinta. Lista näyttää kaikki valitut tilat (OR), ja sama tilaus näkyy vain kerran (esim. osittain hyvitetty, kun Maksetut ja Hyvitetyt on valittu).
- Valittu nappi on täysvihreä ja teksti valkoinen. Valitsematon nappi on valkoinen ja sillä on kapea vihreä reunus.
- Oletuksena valittuina ovat Maksetut ja Maksamattomat (Joonas 11.11.2026). Tyhjennä-painike palauttaa oletuksen.
- Maksamattoman tilauksen rivillä on hyvin haalea punainen tausta (`--unpaidbg` 40 % valkoiseen sekoitettuna, #fcf3f4, `.tl-row.is-unpaid`). Sääntö on sama kuin Maksamattomat-napissa: unpaid, pending, failed tai partially_paid, eikä tilaus ole peruttu tai vanhentunut.
- Kaikki valitsee vain itsensä. Kun muun tilan valitsee, Kaikki poistuu.
- Kun viimeisenkin tilan ottaa pois, näytetään kaikki tilaukset ja Kaikki-nappi syttyy. Lista ei siis koskaan ole tyhjä pelkän nappivalinnan takia.
- Haku toimii kuten ennen. Jos valintana on oletus (Maksetut ja Maksamattomat), haku käy kaikista tilauksista. Muu valinta pysyy haussa.
- Napit eivät kasvata «Suodattimia: N» -lukua, koska ne näkyvät aina.

Kanta: `booking_277` lisää `admin_list_orders`-funktioon viimeiseksi parametrin `p_payment_filters text[] DEFAULT NULL`. Ei-tyhjä taulukko ohittaa `p_payment_filter`-arvon. NULL tai tyhjä taulukko tarkoittaa vanhaa käytöstä. Vanha 12 argumentin versio poistetaan, jotta PostgREST ei jää kahden ylikuormituksen väliin.

Hallinta lähettää yhden tilan vanhalla `p_payment_filter`-parametrilla. Taulukko lähtee vain, kun tiloja on useampi, eli myös oletusnäkymässä. Jos kannassa ei vielä ole uutta parametria (PGRST202), hallinta käyttää vanhaa kutsua `p_payment_filter` = `all` (näyttää enemmän, ei piilota mitään), eikä lista siirry mockiin.

- Migraatio: `booking/supabase/migrations/20261111144714_booking_277_admin_list_orders_payment_filters.sql`
- Rollback: `booking/supabase/rollbacks/20261111144714_booking_277_ROLLBACK.sql` (palauttaa booking_270:n funktion, oikeudet ja kommentin)
- SQL-testi: `booking/supabase/tests/talous/t277_list_orders_payment_filters.sql`
