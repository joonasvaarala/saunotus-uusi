# Johku-tuonti (rakenne valmis, tuontiskriptiä ei ole ajettu)

Johkuun ei kosketa (vain GET). Tuonti tehdään erillisellä ajolla, jossa data muunnetaan ja kirjoitetaan `booking`-skeemaan **vain migraatio-/tuontiputken kautta Bottiavustuksella**. Tämä PR ei sisällä oikeaa asiakasdataa eikä tuontiskriptiä – vain skeeman, joka ottaa tuonnin vastaan.

## Kenttäkartoitus

| Johku | `booking` |
|---|---|
| `customers.id` | `customers.external_source='johku'`, `external_id` |
| `customers.allowmarketing` = 1 | `marketing_consent=true`, `_source='johku_import'`, `_at` = tilauksen aika/tuontipäivä, `_text_version='johku'`; tyhjä/0 = **ei lupaa** |
| `customers` duplikaatit (sama sähköposti, 82 kpl) | yhdistetään sähköpostilla (`lower(email)`), ensimmäinen `external_id` säilytetään |
| `orders.id` | `orders.external_source='johku'`, `external_id`; `johku_order_no` = näkyvä tilausnumero; `source_channel='johku_import'` |
| tilausrivi (`ownItem`) | `order_items` (`vat_rate` rivikohtaisesti: 24 / 25.5 / 14 / 13.5 / 10 / 0) |
| varaus (tuleva) | `reservations` (`rule_id` null, `mode` tuotteen mukaan; trigger tarkistaa päällekkäisyydet → ristiriidat tulevat esiin) |
| maksutapa (`orders.payment`) | `payments.method` via `payment_methods.johku_codes` (esim. `paybywaychannel` → Visma Pay, `creditcard`, `mobilepay`, `voucher`, `admincard`, `invoice`) |
| lahjakortti (`valuecards`) | `gift_cards` + `gift_card_ledger` (alkusaldo + käytöt) |
| sarjakortti | `gift_cards` (tyyppi sarja; laajennetaan tarvittaessa) |

Idempotenssi: uniikki `(external_source, external_id)` sekä tilauksille että asiakkaille → tuonnin voi ajaa uudelleen.

## Ajojärjestys (ehdotus)
1. Asiakkaat → 2. Tilaukset + rivit + maksut → 3. Tulevat varaukset (huom. kapasiteettitarkistus) → 4. Lahjakortit/sarjakortit → 5. Täsmäytys Johkun raportteihin (summat ALV-kannoittain).
Rinnakkaisajon aikana Johku on totuus; tuonti toistetaan juuri ennen siirtymää.

## GDPR
Tuo vain asiakkaat, joille on laskutus-/kirjanpito-/varaustarve; vanhat tarpeettomat anonymisoidaan (`customers.anonymized_at`). Markkinointilupa vain kun `allowmarketing=1`.
