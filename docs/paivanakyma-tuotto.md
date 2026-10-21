# Hallinnan päivänäkymä: tuotto ja tapahtumat

Sipoonjoen Perinnesauna. Näytetään hallinnan päivänäkymän yläosassa (`booking/admin/views/day.js`) vain rooleille `admin` ja `manager`. Luku tulee funktiosta `booking.admin_day_revenue(p_date date)` (migraatio `booking_69_day_revenue_role`, vain luku). `booking.admin_day_extras` palauttaa tapahtumat kaikille henkilökunnan rooleille ja tuottokentät vain adminille ja managerille. Selain laskee saman summan uudelleen riveistä (`booking/admin/day-logic.js`). Otsikot tulevat `site_texts`-avaimista `ui.admin.day.*`; sanakirja `booking/admin/day-texts.js` on varalla.

Työntekijä ja muut roolit eivät näe tuottoa: näkymä ei piirrä korttia eikä kutsu `admin_day_revenue`. Tapahtumat näkyvät samoille käyttäjille kuin vuorot.

## Mitä tuotto on

Tuotto on **sen päivän käyntien arvo**: varaukset, joiden `starts_at` osuu kyseiseen Helsingin vuorokauteen (`Europe/Helsinki`, puolelta yöltä seuraavaan). Se ei ole sinä päivänä tehtyjen tilausten summa eikä sinä päivänä kirjattujen maksujen summa.

Arvo on brutto, **sisältäen ALV:n**, sama luku kuin tilausrivin `line_total_gross` (ALV-erä `line_vat` ja nettopohja `line_net` ovat kannan generoimia sarakkeita, kuten tilausnäkymässä). Mukaan lasketaan varausrivi ja sen lapsirivit (`parent_item_id`: lisäpalvelu ja rivikohtainen alennus). Päiväkortti näyttää vain brutton ja merkinnän «sis. alv». Eri verokantoja ei pyöristetä päivän tasolla uudelleen (kuitti ryhmittelee ALV:n omalla säännöllään).

Lahjakortilla maksettu varaus lasketaan **varauksen arvona**. Maksun määrää ei vähennetä, eikä lahjakorttia käsitellä alennuksena.

## Mitä ei lasketa

| Tila | Tuotossa |
|---|---|
| `confirmed`, `completed` | mukana |
| sama, mutta `payment_status` on `unpaid`, `pending` tai `failed` | mukana, ja merkitty «Josta maksamatta» |
| `pending` ja pito (`hold_expires_at`) on vielä voimassa | ei bruttossa; näytetään «Vahvistamatta» |
| `cancelled`, `expired`, `no_show` | ei |
| `pending` ja pito on päättynyt tai puuttuu | ei (käsitellään vanhentuneena, kuten varauslistassa) |
| `hidden_at` ei ole tyhjä | ei (yhdistetty lisäpalvelurivi) |

Johku-tuonti (`external_source = 'johku'`) **on mukana**. Tämä on päivän toiminnallinen arvo, ei kirjanpidon kassaraportti (raportit rajaavat Johkun erikseen).

Monen päivän varauksen koko arvo lasketaan sille päivälle, jona se alkaa. Sitä ei jaeta päiville eikä lasketa kahdesti.

Tilauksen yleinen alennus, jota ei ole kytketty varausriviin (`parent_item_id` tyhjä), ei siirry tälle päivälle. Varaus ilman tilausriviä (`order_item_id` tyhjä) on arvossa 0.

## Tapahtumat

Päivän listassa näkyvät `kb.event_dates`-rivit, jotka ovat voimassa (`active`) ja joiden väli `starts_on … coalesce(ends_on, starts_on)` sisältää päivän. Kortti on samaa muotoa kuin vuoro: aika (`time_text`, tai osallistujien väli, tai «Koko päivä»), nimi, henkilömäärä, osallistujat (nimi, henkilömäärä, tila, maksu, tilausnumero). Tyhjä tapahtuma näkyy silti. Osallistuja on varaus samalle tuotteelle, joka leikkaa Helsingin vuorokauden ja on vahvistettu, toteutunut tai odottaa voimassa olevalla pidolla. Peruttu osallistuja ei ole kortilla. Sama varaus ei näy sekä tapahtumana että erillisenä slotissa.

Koulutuksen viikonloppu (esim. tuote 35, luokka `training`) näkyy, jos sillä on rivi `kb.event_dates`-taulussa. Rajaus ei ole «vain luokka event».

## Lahjakorttivaraukset vuoron alla

Johku-tuonnissa lahjakortilla tehdyn varauksen tilausrivin nimi on «Yleinen vuoro - Lahjakorttivaraus» (Johku-tuote 119). Tuonti kirjasi sen tuotteelle 1 (Yleinen vuoro) viikonpäivästä riippumatta, ilman `rule_id`:tä ja usein 30 min saapumisikkunana (esim. ti 16:00–16:30). Kapasiteettipooli on silti saman hetken tavallisen vuoron pooli, joten palvelimen «Vapaana»-luku sisältää varauksen jo.

Päivänäkymä (`day-logic.js`, `assignDayCards`) sijoittaa varauksen näin:

1. Saman tuotteen vuoro: `rule_id`, sitten tarkka alku + loppu, sitten sama alku (kuten muillakin varauksilla).
2. Vain lahjakorttivaraus: jos saman tuotteen vuoroa ei ole, samaan aikaan alkava tavallinen yhteisvuoro (`mode = 'shared'`, ei yksityisvuoro), esim. tiistaina Naisten sauna 16–19.
3. Muuten oma ryhmä normalisoidulla avaimella (Helsingin päivä + alku + loppu hetkinä + tuote). Saman tuotteen ja ajan tavallinen varaus on samassa ryhmässä. Otsikko on tuotteen nimi ilman «- Lahjakorttivaraus»-liitettä.

Vuoron henkilömäärä laskee kortin kaikki varaukset kerran (sama `reservation_id` vain kerran, perutut pois). «Vapaana» tulee palvelimelta sellaisenaan eikä ole koskaan negatiivinen. Rivillä on pieni «Lahjakortti»-merkki (`ui.admin.day.gift_card_badge`, tuonti `content/site-texts.pending-import-32.json`); Johku-merkki pysyy ennallaan. Ei migraatiota.

## Kun funktiota ei vielä ole

Ennen kuin migraatio on ajettu, päivänäkymä toimii kuten ennen ja tuoton kohdalla lukee, ettei tieto ole vielä käytettävissä. Tyhjä onnistunut vastaus on 0,00 €, ei puuttuva tieto.
