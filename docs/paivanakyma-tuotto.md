# Hallinnan päivänäkymä: tuotto ja tapahtumat

Sipoonjoen Perinnesauna. Näytetään hallinnan päivänäkymän yläosassa (`booking/admin/views/day.js`). Luku tulee funktiosta `booking.admin_day_extras(p_date date)` (migraatio `booking_68_admin_day_extras`, vain luku). Selain laskee saman summan uudelleen riveistä (`booking/admin/day-logic.js`), jotta näkymä ja testi käyttävät samaa koodia. Otsikot tulevat `site_texts`-avaimista `ui.admin.day.*`; sanakirja `booking/admin/day-texts.js` on varalla.

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

## Kun funktiota ei vielä ole

Ennen kuin migraatio on ajettu, päivänäkymä toimii kuten ennen ja tuoton kohdalla lukee, ettei tieto ole vielä käytettävissä. Tyhjä onnistunut vastaus on 0,00 €, ei puuttuva tieto.
