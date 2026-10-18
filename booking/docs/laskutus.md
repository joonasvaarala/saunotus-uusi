# Laskutus (booking_90–93)

Sipoonjoen Perinnesauna / Havuhattu Oy. Tämä kerros omistaa laskutaulut, hallinnan Laskut-näkymän, PDF:n ja sähköpostin. Procountor-asiakasta ei ole tässä: sen sopimus kirjoitetaan erikseen `docs/procountor-integraatio.md`-tiedostoon.

## Maksutila `invoiced`

Yritysvaraus verkkokaupassa vahvistetaan heti ja maksutilaksi tulee `invoiced` (odottaa laskua), ei `paid`. Kuluttajalle lasku ei ole maksutapa. Kassan lomake lähettää `require_einvoice: true`, jolloin OVT-tunnus (0037 + y-tunnuksen numerot) ja välittäjätunnus ovat pakollisia. Ilman lippua `_clean_company` säilyy entisellään, jotta vanhat testit ja hallinnan polut eivät hajoa.

Verkkomaksu ja lahjakortti piilotetaan, kun `payment_status = invoiced` tai `customer_kind = company`. `checkout_state` pysyy ennallaan (`confirmed_unpaid`), jotta kassan tilalista ei kasva.

Kun ylläpitäjä merkitsee veloituslaskun maksetuksi, avoin `invoice`-maksu kirjataan `paid` ja `booking._refresh_order_payment` päivittää tilauksen. Kuitti syntyy olemassa olevasta maksetriggeristä. Hyvityslaskua ei merkitä maksetuksi. Ennen maksua myyntikäyrä ei näytä laskua, koska käyrä lukee kuitteja.

## Numerointi ja viite

Sarja `L`, taulu `booking.invoice_counters`. Numero annetaan vasta kun luonnos lähtee, samassa transaktiossa (`pg_advisory_xact_lock`). Luonnoksella ei ole numeroa. Viitenumero on kansallinen viite: painot 7, 3, 1 oikealta. Normalisoidun JSON:n kenttä `reference` on tämä pankkiviite. Ostajan viite ("viitteenne") menee kenttään `buyer_reference` ja notes-alun riville `Viitteenne: …`.

## Lähetys

`settings.invoice_dispatch_mode` on oletuksena `dry_run` (ei uusi `integration_config`-avain; sallitut avaimet ovat jo resend, vismapay, procountor). dry_run merkitsee lähetyksen heti, ilman cronia. `live` jättää rivin jonoon `queued`. Edge `invoice-dispatch` lukee jonon, rakentaa JSON:n

`{customer:{name,business_id,vat_id,einvoice_address,einvoice_operator,email,address}, number, date, due_date, reference, currency, lines:[{description,quantity,unit,unit_price_net,vat_rate}], notes}`

ja kutsuu `booking/supabase/functions/_shared/invoice_provider.ts` (`dryRunProvider`, kunnes Procountor-agentti vaihtaa toteutuksen). Tämä kerros on erillään `procountor-sync`-adapterista. PDF-sähköposti on eri polku: `email_outbox.kind = invoice_pdf`. `email_outbox_claim` on booking_102:n funktio ja siihen on lisätty vain `invoice`-lohko. `send-emails` liittää PDF:n live-tilassa.

Pankkiyhteys on asetus `invoice_bank` (`iban`, `bic`, `name`). Se on tyhjä, kunnes se täytetään. Se ei ole salasana.

## Oikeudet

`invoices.manage` on pääkäyttäjällä (admin) ja ylläpitäjällä (manager). Ei anon-oikeuksia. Tauluissa vain luku RLS:llä. Kirjoitus vain SECURITY DEFINER -RPC:illä. Muutokset audit-lokiin. Lähetyksen jälkeen rivit lukitaan; korjaus on hyvityslasku, jonka rivit ovat alkuperäisen vastaluku (myös alennusrivi). Jos tilauksesta syntyvä luonnos epäonnistuu, varaus säilyy ja virhe kirjataan `raise warning`-viestinä sekä `booking.audit_log`-tauluun (`invoice_draft_failed`).

## Bottiavustus

Migraatiot ajetaan järjestyksessä booking_90–93. Rollback-tiedostot ovat `booking/supabase/rollbacks/`. Tuotantotietokantaan ei yhdistetä tästä haarasta. Tekstit: `content/site-texts.pending-import-13.json` (`admin_texts_import`, enintään 500 riviä). `site-texts-sync.mjs` ajetaan vasta, kun kannassa on yhteys, jotta `content/site-texts.fallback.json` vastaa tuotantoa. Fallbackiin lisättiin uudet kauppa-, sähköposti- ja PDF-avaimet, jotta CI:n generaattoritestit näkevät ne jo tuotannossa olevina siihen asti.
