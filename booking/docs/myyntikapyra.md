# Myyntikäyrä (Talous)

Sipoonjoen Perinnesauna, hallinnan Talous-sivu. Migraatio `booking_71_sales_chart` (ei ajettu tästä PR:stä). Sopimus: `KOODARI_talous_A_D_fi.md` §20.

## Mitä ruudulla näkyy

Pylväs on välilehtien yläpuolella, kun käyttäjällä on `reports.view` (manager tai admin). Henkilökunta, jolla on vain `reports.daily`, `payments.manage` tai `giftcards.manage`, ei näe käyrää eikä voi kutsua RPC:tä.

Vuosi on oletuksena kuluva vuosi (Helsinki). 12 kuukautta piirretään aina. Tuleva kalenterikuukausi ilman maksua jää tyhjäksi: kassaperusteessa ennakkomaksu näkyy sinä kuukautena, jona kuitti annettiin, ei käyntikuukautena.

Pino alhaalta ylös: **myynti ilman ALV**, **ALV**, ja tarvittaessa **brutto, ALV ei eritelty**. Vuoden summat ovat pylvään alla.

## Datalähteet

| Osa | Lähde | Päivä |
|---|---|---|
| Uusi järjestelmä | `booking.receipts`, joista `not booking._acct_excluded` | `issued_at` → Helsingin päivä. Sama joukko kuin raportin `gross_after_refunds` / `vat_after_refunds` / `net_ex_vat_after_refunds` |
| Johku | `booking.orders`, joissa `external_source='johku'` tai `johku_order_no` tai `source_channel='johku_import'`, tila `paid` / `partially_refunded` / `refunded` | `external_meta.johku.paid_at` (`booking._try_ts`), Helsingin päivä |

Uutta Johku-dataa ei tuoda. Tauluihin ei tehdä muutoksia.

## ALV

Kuitin netto ja ALV luetaan kuitin snapshotista (`total_net`, `total_vat`). Ne on laskettu samoin kuin muu kirjanpito.

Johku-metassa on brutto (`johku.amount`, muuten `orders.total_gross`), ei eriteltyä ALV:tä. Rivien `order_items.vat_rate` on tuotu (24 / 25,5 / 14 / 13,5 / 10 / 0) ja `line_vat` on generoitu sarake. Käyrä jakaa Johkun bruton samassa suhteessa:

`ALV = round(brutto × sum(line_vat) / sum(line_total_gross), 2)`, `netto = brutto − ALV`.

Jos rivien brutto ei ole positiivinen, kantaa ei keksitä. Summa jää kohtaan `unsplit_gross`.

Kokonaan hyvitetty Johku-tilaus (`payment_status = refunded`) vähennetään alkuperäisen maksupäivän kuusta. Erillistä hyvityspäivää ei ole metassa. Osittain hyvitetty pidetään Johkun koko summana: osahyvityksen määrää ei ole `external_meta.johku`-objektissa.

## Miten Johku pysyy pois raporteista

`admin_sales_chart` on uusi funktio. Se ei korvaa `_report_json`, `admin_report_daily`, `admin_report_month` eikä `admin_report_csv`.

Johku-tilaus ei saa kuittia (`receipts_no_johku`, `BK001 johku_not_accounted`). Raportit lukevat kuitteja, joista `_acct_excluded` on rajattu pois. CSV ja PDF käyttävät samaa rajausta.

Käyrän Johku-puoli ohittaa lisäksi tilauksen, jolla on kuitti ja `_acct_excluded` on false. Sama tilausrivi ei siis ole sekä kuitissa että Johku-pylväässä.

Lahjakortit: käyrän natiivi osa on samat kuitit kuin myyntiraportti. `at_sale`- ja Johku-kortin lunastus on `_acct_excluded` (kerran, myynnissä tai Johkussa). `at_redemption`-myynnin 0 %:n kuitti ja lunastuskuitti ovat molemmat raportissa, joten ne ovat molemmat myös käyrän natiivi osassa.

## Oikeudet

`_require_staff()` ja `_require_permission('reports.view')`. `revoke` public/anon/authenticated, `grant` service_role ja authenticated. Runko estää muut kuin reports.view.

Jos funktiota ei ole vielä kannassa, hallinta ei näytä keksimiään lukuja: käyrä ilmoittaa, ettei se ole käytettävissä. `?mock=1` käyttää edelleen mock-dataa.

## Avoimet kysymykset

1. Poistetaanko raporttivälilehden harmaa `statistics.johku` -lohko, kun käyrä on käytössä? Tätä PR:ää ei muutettu sitä.
2. Johkun osahyvityksen määrää ei ole metassa. Käyrä käyttää koko summaa.
3. Kokonaan hyvitetty Johku-tilaus vähennetään maksupäivän kuusta, ei hyvityspäivältä.
4. Ilman rivien ALV-kantaa summa näytetään erittelemättömänä bruttona.
5. Samaa kauppaa ei tunnisteta, jos se on sekä Johku-tuontitilaus että erillinen uusi tilaus.
6. `at_redemption`-lahjakortin myyntikuitti (0 %) ja lunastuskuitti ovat molemmat mukana, koska raporttikin laskee ne niin.
7. Käyrä vaatii `reports.view`. Kaikki Talous-sivun käyttäjät eivät sitä näe. `reports.daily` ei riitä.
8. Tuontitiedosto on `content/site-texts.pending-import-4.json`. Numerot 1–3 ovat jo käytössä; 6 ei ollut seuraava vapaa.
9. Jos Johkun `amount` eroaa rivien summasta, ALV skaalataan niin, että pylvään brutto on Johkun summa.

## Bottiavustus

- Aja migraatio `20261018190000_booking_71_sales_chart.sql`. Rollback on `20261018190000_booking_71_ROLLBACK.sql` (pelkkä `drop function`).
- Aja testi `booking/supabase/tests/talous/t70_sales_chart.sql` (transaktio päättyy tahalliseen poikkeeseen `TESTRESULT`).
- Tuo `content/site-texts.pending-import-4.json` funktiolla `admin_texts_import` (enintään 500 riviä; tiedostossa myyntikäyrän ja suodatinpainikkeen tekstit). Älä ylikirjoita olemassa olevia avaimia.
- Älä yhdistä PR:ää tästä ajosta.
