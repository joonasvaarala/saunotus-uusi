# Talous: tilauslistan oletus on maksetut

Hallinnan Talous-sivun tilauslista (`booking/admin/views/talous-orders.js`). Migraatio `booking_76` lisää `admin_list_orders`-funktioon parametrin `p_payment_filter` (oletus `paid`). Migraatiota ei ole ajettu tuotantoon tästä muutoksesta.

## Maksutilat ja tilauksen tila

`orders.payment_status` (booking_02): `unpaid`, `pending`, `paid`, `partially_paid`, `refunded`, `partially_refunded`, `failed`.

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
| Kaikki | `all` | ei maksu- eikä peruutusrajausta (muut suodattimet ennallaan) |
| Hyvitetyt | `refunded` | refunded ja partially_refunded |
| Peruttu | `cancelled` | tilauksen tila cancelled tai expired |

`partially_refunded` näkyy sekä Maksetuissa että Hyvitetyissä. Peruttu kattaa myös vanhentuneen pidon (`expired`), koska se on pois oletuksesta eikä sillä ole omaa valintaa.

Vanha parametri `p_payment_status` rajaa yhä yhteen maksutilaan ja yhdistyy AND-ehtona. Kutsu, joka haluaa pelkän vanhan tarkan tilan koko kannasta, lähettää `p_payment_filter` = `all`.

## Haku

Palvelin ei laajenna hakua itse. Hallinta lähettää `p_payment_filter` = `all`, kun hakukentässä on tekstiä ja valinta on yhä oletus Maksetut. Maksamaton tilaus löytyy numerolla tai nimellä. Jos käyttäjä on valinnut Maksamattomat, Hyvitetyt, Peruttu tai Kaikki, haku pysyy siinä joukossa. Kun haku tyhjennetään, oletus palaa. Haun aikana näkyy teksti «Haku kaikista tilauksista».

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
