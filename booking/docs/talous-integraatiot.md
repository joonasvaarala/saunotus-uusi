# Talousintegraatiot – käyttöönotto-ohje (Resend, Visma Pay, Procountor)

Tila 17.10.2026. Kaikki integraatiot on rakennettu valmiiksi **ilman ulkoisia yhteyksiä**: mitään ei lähde ulos, ennen kuin (1) salaisuus on asetettu ja (2) `booking.integration_config.mode` on vaihdettu `live`-tilaan. Salaisuuksia **ei koskaan** tallenneta tietokantaan tai repoon – vain Supabasen Edge Function -salaisuuksiin (Dashboard → Edge Functions → Secrets, tai `supabase secrets set`).

## 1. Tilat (`booking.integration_config`)

| key | mode nyt | merkitys |
|---|---|---|
| `resend` | `dry_run` | `off` = viestit merkitään `skipped`; `dry_run` = viestit renderöidään ja merkitään `dry_run`, **ei lähetetä**; `live` = lähetetään Resendillä |
| `vismapay` | `off` | `off` = ei verkkomaksua (`online_payment_enabled=false`, maksulinkkejä ei luoda asiakkaalle); `live` = maksulinkit/verkkomaksu käytössä |
| `procountor` | `off` | `off` = kirjanpitojonoon ei kirjoiteta; `dry_run`/`live` = jokainen kuitti ja hyvityskuitti kopioidaan `accounting_outbox`-jonoon |

Vaihto (ylläpitäjä, SQL-editori; kirjautuneena ei vielä admin-RPC:tä):
```sql
update booking.integration_config set mode = 'live', updated_at = now() where key = 'resend';
```
`integration_config.settings` (ei salaisuuksia): `resend.settings` = `{"from":"Sipoonjoen perinnesauna <savusauna@saunotus.fi>","reply_to":"savusauna@saunotus.fi"}`.

## 2. Resend (sähköposti) – tarvitaan ennen live-tilaa
1. Resend-tili (resend.com) ja **verkkotunnus** `saunotus.fi` lisättynä Resendiin; DNS-tietueet (SPF, DKIM, suositus DMARC) lisätty verkkotunnuksen DNS:ään ja tunnus merkitty Resendissä *Verified*. Lähettäjäosoite oltava vahvistetulla verkkotunnuksella (`savusauna@saunotus.fi`).
2. API-avain (Sending access) → Edge-salaisuus **`RESEND_API_KEY`**.
3. Tarkista `settings.site_base_url` (nyt `https://uusi.saunotus.com`; vaihda varsinaiseksi osoitteeksi ennen live-tilaa, koska viestien linkit rakentuvat siitä): `update booking.settings set value = to_jsonb('https://…'::text) where key = 'site_base_url';`
4. Testilähetys: aseta `resend.mode='live'` vain hetkeksi omalla osoitteellasi tehtyä testitilausta vasten (tilauksen sähköposti = oma osoite), tarkista viestit ja PDF-liite, ja tarkista että `email_outbox.status='sent'`.
5. Live-tilassa viestit lähtevät: tilausvahvistus (45 s viiveellä), kuitti ja hyvityskuitti (PDF liitteenä), maksulinkki, peruutuspyynnön vastaanottoviesti, tilausmuutosviesti. Virheet: uudelleenyritys (`attempts²` min), `dead` kun `max_attempts` täynnä; seuranta: `select kind,status,last_error,count(*) from booking.email_outbox group by 1,2,3;`
6. `send-emails` ajetaan pg_cronilla (`booking_send_emails`, 1 min); tunnistus `x-sync-secret` = Vault-salaisuus `calendar_sync_cron_secret` (jo olemassa; ei lisäsalaisuutta).
- Huom: dry_run-tilassa merkityt (`dry_run`) viestit **eivät lähde jälkikäteen**; live-tilaan siirryttäessä vain `pending`-rivit lähtevät. Jos haluat lähettää kuitin uudelleen: `admin_resend_receipt`.

## 3. Visma Pay (verkkomaksu) – ei toteutettu, runko valmiina
Valmiina: `payments`-rakenne (`provider='visma_pay'`, `provider_ref`, `provider_status`, `link_token`, `link_expires_at`, `raw`), maksulinkit (`/maksa/?p=<link_token>`), `payment_mark_paid(p_provider text, p_provider_ref text, p_amount numeric, p_raw jsonb)` (vanha, olemassa oleva; service_role; idempotentti `already:true`; hakee maksun `provider`+`provider_ref`-parilla – `vismapay-start` tallentaa Visma Payn palauttaman tokenin `provider_ref`iin maksun luonnin jälkeen; maksu → `paid` käynnistää kuitin ja kuittiviestin triggerillä), `admin_refund` (jää `pending`/kirjataan käsin, kunnes `vismapay-refund` toteutetaan), edge-funktiot `vismapay-start`, `vismapay-notify`, `vismapay-refund` (palauttavat nyt 501).
Tarvitaan käyttöönottoon:
- Visma Pay -kauppiastili ja **API-avain (`api_key`) + yksityinen avain (`private_key`)** → Edge-salaisuudet **`VISMAPAY_API_KEY`**, **`VISMAPAY_PRIVATE_KEY`**.
- Visma Pay -kauppiasportaaliin: palautus-/ilmoitusosoitteet: success/cancel-paluu `https://<verkkokauppa>/maksa/` (Koodari päättää paluusivun), notify `{SUPABASE_URL}/functions/v1/vismapay-notify`.
- Maksutavat sopimuksessa (kortti, verkkopankit, MobilePay) ja hyvitys-API (`create_refund`) otettava käyttöön tilillä.
- Toteutus (vaihe E): Web Payment API w3.2: `auth_payment` (authcode = HMAC-SHA256(private_key, api_key|order_number-sidottu body)), notify-vahvistus `RETURN_CODE|ORDER_NUMBER|SETTLED|INCIDENT_ID` (HMAC-SHA256, vakioaikavertailu) + `check_payment_status`; `create_refund`. Testi: Visma Pay -testitunnukset (testiympäristö) ennen tuotantoavaimia.
- Kun valmis: `vismapay.mode='live'` (silloin asiakkaan tilaussivu alkaa luoda maksulinkkejä lisäyksille).

## 4. Procountor (kirjanpito) – ei toteutettu, runko valmiina
Valmiina: `accounting_outbox` (kind, order_id, payment_id, receipt_id, `dedupe_key`, `payload` = kuitin snapshot, `status`, `attempts`, `environment`), täyttö kuiteista kun `procountor.mode <> 'off'`, edge-funktio `procountor-sync` (501), asetus `procountor_env` (`pts`/`prod`).
Tarvitaan käyttöönottoon:
- Procountor-yrityksen **API-käyttöoikeus**: OAuth2-asiakas (`client_id`, `client_secret`) + API-avain, yrityksen tunniste (company id) ja käyttäjätunnus-sidonta → Edge-salaisuudet **`PROCOUNTOR_CLIENT_ID`**, **`PROCOUNTOR_CLIENT_SECRET`**, **`PROCOUNTOR_API_KEY`**; ympäristö: aloita PTS-testiympäristössä (`procountor_env='pts'`).
- Kirjanpidon päätökset: tilikartta (myyntitilit ALV-kannoittain 25,5 % / 13,5 % / 0 %, hyvitykset, käteispyöristys), maksutapa → kassa-/pankki-/korttitili, kuittityyppi (myyntilasku vs. ostolasku/kuitti-kirjaus), ALV-koodit, Visma Pay -tilitykset. Nämä sovitaan kirjanpitäjän kanssa; toteutus mäppää snapshotin `lines`/`vat`/`payment.method` niihin.
- Ennen `live`-tilaa: `dry_run` (jono täyttyy, mitään ei lähetetä) ja täsmäytys Raportit-näkymään.

## 5. Muut käyttöönoton tarkistukset
- **Kuitin tiedot:** `settings.seller` (nimi, y-tunnus 3018112-1, ALV-tunnus FI30181121 – johdettu y-tunnuksesta, vahvista, osoite, yhteystiedot, `logo_url`, alatunniste). Logo: `settings.seller.logo_url` = julkinen PNG (`https://joonasvaarala.github.io/saunotus-uusi/img/logo-kuitti.png` kun julkaistu); **asetettu 17.10.2026** (URL palauttaa 200 image/png). Vaihto: `update booking.settings set value = jsonb_set(value, '{logo_url}', to_jsonb('…'::text)) where key = 'seller';`. Muuten PDF tehdään ilman logoa.
- **Numerointi:** sarjat `receipt_series` (`K`/`H`), vuosi Helsingin ajassa, aukoton; kuitteja ei voi muuttaa tai poistaa (trigger `receipt_immutable`). Älä muuta sarjaa tuotannossa kuin uuden vuoden/sarjan alussa.
- **Säilytys:** kuitit ovat `booking.receipts`-taulussa (snapshot + teksti) ja PDF-välimuisti yksityisessä Storage-bucketissa `receipts` (voi luoda uudelleen snapshotista). Säilytä vähintään 6 vuotta; taulun varmuuskopiointi Supabasen PITR/varmuuskopioilla.
- **Edge-funktiot (verify_jwt):** `receipt-pdf` (ei; token), `send-emails` (ei; `x-sync-secret`), `vismapay-start`/`vismapay-notify` (ei; ulkoinen kutsuja/allekirjoitus), `vismapay-refund`/`procountor-sync`/`report-pdf` (kyllä).
- **Raportit:** kassaperuste (kuitin antopäivä). Ennen kuittijärjestelmää tehdyt maksut eivät näy raporteissa; ne näkyvät `unreceipted`-täsmäytysavaimessa.

## Sähköpostipohjat (`send-emails/templates.ts`)
- `render(kind, data, locale)` → `{subject, text, html}`; kielet FI/EN (`locale` parametri tai datan `locale`, oletus fi); tyypit `order_confirmation`, `payment_link`, `receipt`, `refund_receipt`, `cancel_request_ack`, `order_change`.
- HTML on taulukkopohjainen ja inline-tyylitelty (sähköpostiyhteensopiva), mukana tekstiversio. Värit: tumma vihreä (#1f3d2b) ja hiekka (#efe7d6), ei sinistä. Logo = `<sivusto>/img/logo-kuitti.png`; sivusto johdetaan tilaus-/maksulinkistä (`site_base_url` + `order_page_path`/`payment_link_path`), muuten oletus `https://joonasvaarala.github.io/saunotus-uusi/img/logo-kuitti.png`.
- Linkit kulkevat vain `https://`-muodossa (muut pudotetaan), kaikki data HTML-escapataan. `dry_run`-tila ennallaan: viesti renderöidään ja merkitään `dry_run`, mitään ei lähetetä.
- Testit: `node --test booking/supabase/functions/send-emails/templates.test.mjs` (tarvitsee Node ≥ 22.18, jossa .ts-tuonti toimii; vanhemmalla Nodella testit ohitetaan; CI ajaa Node 22:lla). Tyyppitarkistus: kopioi `functions/` kansioon, jonka yläpuolella ei ole `node_modules`, ja aja `deno check */index.ts`.
- Käyttöönotto-huomio: `send-emails` (live-tilassa) hakee PDF:n `receipt-pdf`-funktiosta; tuotannossa `receipt-pdf` ei ollut vielä julkaistu 17.10.2026 → julkaise ennen `resend.mode='live'`.
