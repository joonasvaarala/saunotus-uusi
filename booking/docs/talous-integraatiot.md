# Talousintegraatiot – käyttöönotto-ohje (Resend, Visma Pay, Procountor)

Tila 17.10.2026. Kaikki integraatiot on rakennettu valmiiksi **ilman ulkoisia yhteyksiä**: mitään ei lähde ulos, ennen kuin (1) salaisuus on asetettu ja (2) `booking.integration_config.mode` on vaihdettu `live`-tilaan. Salaisuuksia **ei koskaan** tallenneta tietokantaan tai repoon – vain Supabasen Edge Function -salaisuuksiin (Dashboard → Edge Functions → Secrets, tai `supabase secrets set`).

## 1. Tilat (`booking.integration_config`)

| key | mode nyt | merkitys |
|---|---|---|
| `resend` | `dry_run` | `off` = viestit merkitään `skipped`; `dry_run` = viestit renderöidään ja merkitään `dry_run`, **ei lähetetä**; `live` = lähetetään (`settings.transport`, oletus Resend). Epätyhjä `settings.test_recipients` rajaa live-vastaanottajat |
| `vismapay` | `off` | `off` = ei verkkomaksua (`online_payment_enabled=false`, maksulinkkejä ei luoda asiakkaalle); `live` = maksulinkit/verkkomaksu käytössä |
| `procountor` | `off` | `off` = kuittijonoa ei kirjoiteta eikä päiväkirjausta tehdä. `dry_run`/`live` kopioi kuitit `accounting_outbox`-jonoon, mutta lähetys on päivän tosite (`daily_enabled`) ja laskun välitys. Ks. docs/procountor-integraatio.md. |

Vaihto (ylläpitäjä, SQL-editori; kirjautuneena ei vielä admin-RPC:tä):
```sql
update booking.integration_config set mode = 'live', updated_at = now() where key = 'resend';
```
`integration_config.settings` (ei salaisuuksia): `resend.settings` = `{"from":"Sipoonjoen Perinnesauna <savusauna@saunotus.fi>","reply_to":"savusauna@saunotus.fi"}`.

Lisäasetukset (eivät ole salaisuuksia):

- `transport`: `resend` (oletus, jos kenttä puuttuu) tai `gmail_smtp` (valinnainen testivaiheen SMTP, ks. alla). Resend-haara ja sen idempotenssiavain pysyvät ennallaan.
- `test_recipients`: taulukko sähköpostiosoitteita lowercasena, esim. `["oma@example.com"]`. Kun taulukko on epätyhjä ja `mode` on `live`, `send-emails` merkitsee ennen renderöintiä ja lähetystä `skipped`-tilaan (`ei allowlistissa`) jokaisen rivin, jonka vastaanottaja ei ole listalla. Vertailu on kirjainkoosta riippumaton ja trimmaa välilyönnit. Tarkistus koskee kaikkia vastaanottajia (`to` ja mahdolliset `cc`/`bcc`); yksikin listan ulkopuolinen estää koko viestin. Tyhjä tai puuttuva lista ei rajaa. `dry_run` ja `off` eivät käytä listaa.

## 2. Resend (sähköposti) – tarvitaan ennen live-tilaa
1. Resend-tili (resend.com) ja **verkkotunnus** `saunotus.fi` lisättynä Resendiin; DNS-tietueet (SPF, DKIM, suositus DMARC) lisätty verkkotunnuksen DNS:ään ja tunnus merkitty Resendissä *Verified*. Lähettäjäosoite oltava vahvistetulla verkkotunnuksella (`savusauna@saunotus.fi`).
2. API-avain (Sending access) → Edge-salaisuus **`RESEND_API_KEY`**.
3. Tarkista `settings.site_base_url` (nyt `https://uusi.saunotus.com`; vaihda varsinaiseksi osoitteeksi ennen live-tilaa, koska viestien linkit rakentuvat siitä): `update booking.settings set value = to_jsonb('https://…'::text) where key = 'site_base_url';`
4. Testilähetys: aseta ensin `test_recipients` (omat osoitteet), sitten `resend.mode='live'`. Tarkista viestit ja PDF-liite ja että `email_outbox.status='sent'`. Osoite, joka ei ole listalla, merkitään `skipped` (`ei allowlistissa`) eikä lähde.
5. Live-tilassa viestit lähtevät: tilausvahvistus (45 s viiveellä), kuitti ja hyvityskuitti (PDF liitteenä), maksulinkki, peruutuspyynnön vastaanottoviesti, tilausmuutosviesti. Virheet: uudelleenyritys (`attempts²` min), `dead` kun `max_attempts` täynnä; seuranta: `select kind,status,last_error,count(*) from booking.email_outbox group by 1,2,3;`
6. `send-emails` ajetaan pg_cronilla (`booking_send_emails`, 1 min); tunnistus `x-sync-secret` = Vault-salaisuus `calendar_sync_cron_secret` (jo olemassa; ei lisäsalaisuutta).
- Huom: dry_run-tilassa merkityt (`dry_run`) viestit **eivät lähde jälkikäteen**; live-tilaan siirryttäessä vain `pending`-rivit lähtevät. Jos haluat lähettää kuitin uudelleen: `admin_resend_receipt`.

### Testivaiheen lähetys Gmail SMTP:llä (valinnainen)

Resend pysyy oletuksena (`transport` puuttuu tai on `resend`). Testivaiheessa voi asettaa `settings.transport = 'gmail_smtp'`. Yhteys on `smtp.gmail.com` portti **465**, TLS (`npm:nodemailer@10.1.2`, versio lukittu). From on aina `Sipoonjoen Perinnesauna <GMAIL_SMTP_USER>` (Gmail vaatii oman osoitteen). `reply_to` tulee `settings.reply_to`-asetuksesta kuten Resendissä. Liitteet (kuitti, hyvityskuitti, lasku, lahjakortin PDF) haetaan samalla logiikalla kuin Resend-haarassa.

Salaisuudet vain Supabasen Edge Function -salaisuuksiin (Dashboard → Edge Functions → Secrets, tai `supabase secrets set`). Niitä **ei** kirjoiteta repoon eikä chattiin:

- `GMAIL_SMTP_USER`
- `GMAIL_SMTP_APP_PASSWORD` (Google-sovellussalasana)

Jos salaisuuksia ei ole asetettu, viesti merkitään `failed` ja `last_error` on `GMAIL_SMTP_* puuttuu` (ajo ei kaadu, muita rivejä käsitellään). Portin 465 toimivuus Supabasen edge-ympäristössä varmistetaan kokeilemalla tuotannossa, ei koodissa. Deployn ja `integration_config`-muutokset tekee Bottiavustus.

Rajat: Gmailin lähetyskiintiö on noin 500 viestiä vuorokaudessa. From on Gmail-osoite, ei `savusauna@saunotus.fi`. Roskapostiriski on suurempi kuin Resendillä. `reply_to`-osoitteen on oltava toimiva, jotta vastaukset tulevat perille.

## 3. Visma Pay (verkkomaksu) – ei toteutettu, runko valmiina
Valmiina: `payments`-rakenne (`provider='visma_pay'`, `provider_ref`, `provider_status`, `link_token`, `link_expires_at`, `raw`), maksulinkit (`/maksa/?p=<link_token>`), `payment_mark_paid(p_provider text, p_provider_ref text, p_amount numeric, p_raw jsonb)` (vanha, olemassa oleva; service_role; idempotentti `already:true`; hakee maksun `provider`+`provider_ref`-parilla – `vismapay-start` tallentaa Visma Payn palauttaman tokenin `provider_ref`iin maksun luonnin jälkeen; maksu → `paid` käynnistää kuitin ja kuittiviestin triggerillä), `admin_refund` (jää `pending`/kirjataan käsin, kunnes `vismapay-refund` toteutetaan), edge-funktiot `vismapay-start`, `vismapay-notify`, `vismapay-refund` (palauttavat nyt 501).
Tarvitaan käyttöönottoon:
- Visma Pay -kauppiastili ja **API-avain (`api_key`) + yksityinen avain (`private_key`)** → Edge-salaisuudet **`VISMAPAY_API_KEY`**, **`VISMAPAY_PRIVATE_KEY`**.
- Visma Pay -kauppiasportaaliin: palautus-/ilmoitusosoitteet: success/cancel-paluu `https://<verkkokauppa>/maksa/` (Koodari päättää paluusivun), notify `{SUPABASE_URL}/functions/v1/vismapay-notify`.
- Maksutavat sopimuksessa (kortti, verkkopankit, MobilePay) ja hyvitys-API (`create_refund`) otettava käyttöön tilillä.
- Toteutus (vaihe E): Web Payment API w3.2: `auth_payment` (authcode = HMAC-SHA256(private_key, api_key|order_number-sidottu body)), notify-vahvistus `RETURN_CODE|ORDER_NUMBER|SETTLED|INCIDENT_ID` (HMAC-SHA256, vakioaikavertailu) + `check_payment_status`; `create_refund`. Testi: Visma Pay -testitunnukset (testiympäristö) ennen tuotantoavaimia.
- Kun valmis: `vismapay.mode='live'` (silloin asiakkaan tilaussivu alkaa luoda maksulinkkejä lisäyksille).

## 3b. MobilePay (Vipps MobilePay ePayment API, suora integraatio) – valmis, kytketty pois (`mobilepay.mode = 'off'`)

Suora integraatio ilman Visma Payta: maksu `POST /epayment/v1/payments` (WEB_REDIRECT, `profile.scope = name email phoneNumber`), webhook + capture, hyvitys `…/refund`. Tilaus merkitään maksetuksi vasta capturen jälkeen. Rajapinta Koodarille: `KOODARI_talous_A_D_fi.md` §14.

**Edge-salaisuudet** (Supabase → Edge Functions → Secrets; ei koskaan koodiin/lokiin/tiedostoon):
| Nimi | Mistä |
|---|---|
| `MOBILEPAY_CLIENT_ID` | portal.vippsmobilepay.com → Developer → myyntiyksikkö (testi: "Uudet sivut") → API keys: `client_id` |
| `MOBILEPAY_CLIENT_SECRET` | sama: `client_secret` |
| `MOBILEPAY_SUBSCRIPTION_KEY` | sama: `Ocp-Apim-Subscription-Key` (primary) |
| `MOBILEPAY_MSN` | myyntiyksikön Merchant Serial Number |
| `MOBILEPAY_WEBHOOK_SECRET` | syntyy webhookin rekisteröinnissä (alla); Vipps näyttää sen vain kerran |
| `MOBILEPAY_WEBHOOK_URL` (valinnainen) | rekisteröity webhook-osoite (allekirjoituksen polun varmistus) |
| `MOBILEPAY_ALLOWED_ORIGINS` (valinnainen) | pilkuilla erotetut sivuston originit CORSia varten (oletus `*`) |

Testi- ja tuotantoavaimet ovat eri: `mode='test'` käyttää https://apitest.vipps.no, `mode='live'` https://api.vipps.no – **avaimet vaihdetaan samalla kun tila vaihdetaan** (testiavaimilla ei voi `live`-tilassa maksaa).

Asetus: `booking.settings` `site_base_url` (https) ja `order_page_path` (oletus `/tilaus/`) – asiakas palaa tähän maksun jälkeen.

**Käyttöönotto testitilassa (vaatii Joonaksen luvan):**
1. Aseta edge-salaisuudet (`supabase secrets set …` tai Dashboard).
2. Rekisteröi webhook (tallentaa `MOBILEPAY_WEBHOOK_SECRET`:n suoraan Supabaseen, ei tulosta): `deno run -A booking/scripts/mobilepay-webhook.ts register test --project-ref sxbofnuisemspgquoxyv` (avaimet ympäristömuuttujissa). Tapahtumat: authorized, aborted, expired, terminated. Listaus/poisto: `list` / `delete`.
3. Kytke päälle: `update booking.integration_config set mode='test', settings = settings || jsonb_build_object('approved_by','Joonas Vaarala <pvm>') where key='mobilepay';` (trigger vaatii `approved_by`:n; `dry_run` ei ole sallittu MobilePaylle).
4. Testaa: tee testitilaus, maksa MobilePay Test -sovelluksella (testikäyttäjä; testisummat: https://developer.vippsmobilepay.com/docs/test-environment/), tarkista kuitti + hyvitys.
5. Live: aseta tuotantoavaimet, rekisteröi webhook `live`, `mode='live'` + `approved_by`.
Pois: `update booking.integration_config set mode='off' where key='mobilepay';` (painike katoaa heti; olemassa olevat avoimet maksut jäävät pending/vanhenevat).

Turvallisuus: webhookin HMAC-allekirjoitus tarkistetaan, tila haetaan aina Vippsistä (`GET /payments/{reference}`), Idempotency-Key kaikissa kirjoittavissa kutsuissa, yritysviitteet `sauna-o<tilausnro>-p<maksu>-a<yritys>`, asiakkaan henkilötietoja ei tallenneta lokiin/`raw`-kenttään, Johku-tilaukset eristetty. Testit: `booking/supabase/tests/mobilepay/t49_mobilepay.sql` (60 tarkistusta, rullaa takaisin) ja `deno test booking/supabase/functions/_tests/mobilepay_test.ts` (32 testiä, mock-Vipps).

## 4. Procountor (kirjanpito) – adapteri, oletuksena pois päältä
Sopimus ja lähteet: [docs/procountor-integraatio.md](../../docs/procountor-integraatio.md). Edge-funktio `procountor-sync` (verify_jwt pois; tunnistus `x-sync-secret`). Ilman `PROCOUNTOR_*`-salaisuuksia toiminto on dry_run: mitään ei lähetetä.

Myyntikirjaus on **päivän tosite** (`POST /ledgerreceipts`, tyyppi JOURNAL). Se kootaan `booking._report_json`-raportista, ei kuitteja uudelleen laskemalla. `accounting_outbox` täyttyy yhä kuiteista kun `procountor.mode <> 'off'`, mutta `procountor-sync` ei lähetä niitä (sama myynti ei kirjaudu kahdesti).

Laskun välitys on erillinen: `action=send_invoice` ja normalisoitu JSON. Tauluja `booking.invoices` / `booking.invoice_lines` tämä ei luo. `invoice-dispatch` on tästä erillinen dry_run-kerros (`booking/docs/laskutus.md`): se lukee laskujonon ja kutsuu provider-rajapintaa, eikä lähetä mitään ulos ennen kuin provider vaihdetaan.

Tila: `booking.accounting_exports` (RLS: luku `settings.edit`). Hallinnan asetuksissa näkyy yhdistetty / harjoitusajo / pois, viimeisin ajo ja virheet. Ei salaisuuksia.

Salaisuudet vain Edgeen: **`PROCOUNTOR_CLIENT_ID`**, **`PROCOUNTOR_CLIENT_SECRET`**, **`PROCOUNTOR_API_KEY`**, **`PROCOUNTOR_REDIRECT_URI`**. Tilit ja ALV-tila ovat `integration_config.settings` (ei salaisuuksia). Ajastus `booking_procountor_daily` (04:20) on paikallaan, mutta ei tee mitään ennen kuin `mode <> 'off'` ja `settings.daily_enabled = true` ja salaisuudet on asetettu. Aloita PTS-testissä (`settings.environment` oletus `pts`).

## 5. Muut käyttöönoton tarkistukset
- **Kuitin tiedot:** `settings.seller` (nimi, y-tunnus 3018112-1, ALV-tunnus FI30181121 – johdettu y-tunnuksesta, vahvista, osoite, yhteystiedot, `logo_url`, alatunniste). Logo: `settings.seller.logo_url` = julkinen PNG (`https://joonasvaarala.github.io/saunotus-uusi/img/logo-kuitti.png` kun julkaistu); **asetettu 17.10.2026** (URL palauttaa 200 image/png). Vaihto: `update booking.settings set value = jsonb_set(value, '{logo_url}', to_jsonb('…'::text)) where key = 'seller';`. Muuten PDF tehdään ilman logoa.
- **Numerointi:** sarjat `receipt_series` (`K`/`H`), vuosi Helsingin ajassa, aukoton; kuitteja ei voi muuttaa tai poistaa (trigger `receipt_immutable`). Älä muuta sarjaa tuotannossa kuin uuden vuoden/sarjan alussa.
- **Säilytys:** kuitit ovat `booking.receipts`-taulussa (snapshot + teksti) ja PDF-välimuisti yksityisessä Storage-bucketissa `receipts` (voi luoda uudelleen snapshotista). Säilytä vähintään 6 vuotta; taulun varmuuskopiointi Supabasen PITR/varmuuskopioilla.
- **Edge-funktiot (verify_jwt):** `receipt-pdf` (ei; token), `invoice-pdf` (ei; token), `send-emails`, `procountor-sync` ja `invoice-dispatch` (ei; `x-sync-secret`), `vismapay-start`/`vismapay-notify` (ei; ulkoinen kutsuja/allekirjoitus), `vismapay-refund`/`report-pdf` (kyllä).
- **Raportit:** kassaperuste (kuitin antopäivä). Ennen kuittijärjestelmää tehdyt maksut eivät näy raporteissa; ne näkyvät `unreceipted`-täsmäytysavaimessa.

## Sähköpostipohjat (`send-emails/templates.ts`)
- `render(kind, data, locale)` → `{subject, text, html}`; kielet FI/EN (`locale` parametri tai datan `locale`, oletus fi); tyypit `order_confirmation`, `payment_link`, `receipt`, `refund_receipt`, `cancel_request_ack`, `order_change`.
- HTML on taulukkopohjainen ja inline-tyylitelty (sähköpostiyhteensopiva), mukana tekstiversio. Värit: tumma vihreä (#1f3d2b) ja hiekka (#efe7d6), ei sinistä. Logo = `<sivusto>/img/logo-kuitti.png`; sivusto johdetaan tilaus-/maksulinkistä (`site_base_url` + `order_page_path`/`payment_link_path`), muuten oletus `https://joonasvaarala.github.io/saunotus-uusi/img/logo-kuitti.png`.
- Linkit kulkevat vain `https://`-muodossa (muut pudotetaan), kaikki data HTML-escapataan. `dry_run`-tila ennallaan: viesti renderöidään ja merkitään `dry_run`, mitään ei lähetetä.
- Testit: `node --test booking/supabase/functions/send-emails/templates.test.mjs` ja `node --test booking/supabase/functions/send-emails/mailer.test.mjs` (allowlist ja mockattu SMTP, ei verkkoa). Tarvitsee Node ≥ 22.18, jossa .ts-tuonti toimii; vanhemmalla Nodella testit ohitetaan; CI ajaa Node 22:lla. Tyyppitarkistus: kopioi `functions/` kansioon, jonka yläpuolella ei ole `node_modules`, ja aja `deno check */index.ts`.
- Käyttöönotto-huomio: `send-emails` (live-tilassa) hakee PDF:n `receipt-pdf`-funktiosta; tuotannossa `receipt-pdf` ei ollut vielä julkaistu 17.10.2026 → julkaise ennen `resend.mode='live'`.
- Lahjakortit (migraatio 45, sopimus §13.9): `gift_card_buyer` (yksi viesti per tilaus, kaikki kortit) ja `gift_card_recipient` (vain jos `recipient_email`). `send-emails` hakee jokaiselle kortille PDF:n `gift-card-pdf?t=<public_token>&lang=…` ja liittää sen; viestissä on PDF-linkki mutta ei kortin koodia. Peruttu/maksamaton kortti → rivi `skipped`. Testit: `templates.test.mjs` (Node ≥ 22.18) ja Deno-apuajot `gift-card-pdf/test_render.ts`, `send-emails/test_gift_templates.ts` (`deno run -A --node-modules-dir=none …`).
- `gift-card-pdf` (verify_jwt=false): `GET ?t=<public_token>[&lang=fi|en]` → A5-vaaka-PDF (`pdf-lib`), 404 tuntematon token, 409 kortti ei valmis, ei välimuistia. Logo `settings.seller.logo_url` (`docs/giftcards/logo.png` on testiajojen kopio).
