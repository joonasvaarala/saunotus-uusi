# Maksut ja Visma Pay (RAJAPINTA, EI TOTEUTETTU)

> **MobilePay** on toteutettu erikseen suorana Vipps MobilePay ePayment -integraationa (kytketty pois, `mobilepay.mode='off'`): ks. `KOODARI_talous_A_D_fi.md` §14 ja `talous-integraatiot.md` §3b. Tämä dokumentti koskee Visma Pay -runkoa.

**Maksupalveluntarjoaja on Visma Pay (ei Paytrail).** Verkkomaksua ei ole toteutettu: tämä on suunniteltu liitoskohta, jotta toteutus on myöhemmin pieni ja turvallinen. Mitään oikeaa maksua ei voi tehdä.

## Nykytila: kaksi maksutilaa (`booking.settings.public_payment_mode`)

| Tila | Käyttäytyminen |
|---|---|
| `pay_later` (oletus) | Verkkovaraus vahvistuu heti (`confirmed`), `payment_status = unpaid`; maksu paikan päällä. Kauppa kertoo tämän asiakkaalle. |
| `hold_until_paid` | Varaus luodaan `pending` + pito (`hold_minutes`, oletus 15 min). Vahvistuu kun maksu kirjataan (`payment_mark_paid`). Vanhentuessaan paikka vapautuu automaattisesti (myös ilman cronia). Tämä on tila, jota Visma Pay käyttää. |

Hallinnasta henkilökunta voi kirjata maksun käsin (`admin_record_payment`: käteinen, kortti paikan päällä, lasku, MobilePay-käsin jne.; tapa `booking.payment_methods`), ja luoda **maksulinkki-placeholderin** (`admin_create_payment_link`), joka palauttaa tällä hetkellä viestin "ei vielä käytössä".

## Tietomalli

`booking.payments`: `order_id`, `method` (FK `payment_methods`), `provider` (`manual` | `visma_pay`), `provider_ref` (Visman tunniste), `status` (`pending|paid|failed|cancelled|refunded|partially_refunded`), `amount`, `currency`, `link_url`, `link_token`, `provider_status`, `raw jsonb`, `paid_at`.
`orders.payment_status` päivittyy automaattisesti maksujen summasta (`unpaid|pending|partially_paid|paid|refunded…`).

## Adapterifunktiot (vain `service_role`; eivät koskaan selaimelle)

| Funktio | Tarkoitus |
|---|---|
| `booking.payment_prepare(order_id) → {payment_id}` | Luo `pending`-maksurivin tilaukselle (provider `visma_pay`) |
| `booking.payment_attach_provider_ref(payment_id, provider_ref, link_url, raw)` | Tallentaa Visman palauttaman tunnisteen / maksulinkin |
| `booking.payment_mark_paid(provider, provider_ref, amount, raw) → {ok, already?}` | **Idempotentti.** Merkitsee maksetuksi, vahvistaa tilauksen ja varaukset (poistaa pidon) |
| `booking.payment_mark_failed(provider, provider_ref, status, raw)` | Merkitsee epäonnistuneeksi/peruutetuksi (varaus vanhenee pidon mukana) |

Testit: `supabase/tests/05_admin.test.sql` ("maksuadapteri").

## Toteutussuunnitelma (kun päätös tehdään)

Visma Pay Web Payment API (https://vismapay.github.io/ tai Visman nykyinen dokumentaatio – **tarkista rajapinnan nykyinen versio ja allekirjoitusmenetelmä ennen toteutusta**). Tarvitaan kauppiastunnukset (merchant API key + private key, testitunnukset) sekä palautus-/ilmoitusosoitteet.

1. **Supabase Edge Function `vismapay-start`** (service_role palvelinpuolella, avaimet Supabase secrets -hallintaan, ei koskaan repoon):
   * ottaa `public_token`in (ei tilausnumeroa), hakee tilauksen, kutsuu `payment_prepare`, luo maksun Visma Paylle, tallentaa `payment_attach_provider_ref`, palauttaa ohjausosoitteen.
   * Kaupan vahvistussivu ohjaa asiakkaan maksamaan (nappi "Maksa nyt") kun tila on `pending`.
2. **Edge Function `vismapay-notify`** (Visman palautus-/notify-osoite): varmistaa allekirjoituksen (MAC) → `payment_mark_paid` / `payment_mark_failed`. Älä luota selaimen paluuosoitteeseen; vain palvelimelta palvelimelle -ilmoitus vahvistaa maksun.
3. `public_payment_mode` → `hold_until_paid`; asiakkaalle näytetään pidon laskuri; `expire_holds()` (pg_cron tai kevyt ajastus) vapauttaa vanhentuneet.
4. Hallinnan "Luo maksulinkki" -nappi kutsuu samaa `payment_prepare`-polkua (sähköpostiin/tekstiviestinä lähetettävä `link_token`-linkki, esim. koulutusten osamaksut).
5. Palautukset: `payments.status = refunded` + Visma Payn portaali/API; kirjaus `admin_*`-funktiolla (lisätään kun tarvitaan).
6. Täsmäytys: `provider_ref` + `paid_at` + summa → kuukausiraportti ALV-kannoittain (`order_items.line_vat`).

## Huomioita Johku-vanhoista maksuista
Johku ei tallenna Visma Pay -tapahtumatunnistetta API:iin (ks. `johku-vientiselvitys.md` §6). Tuoduille tilauksille `payments.method` mäpätään `payment_methods.johku_codes`-sarakkeella, `provider_ref` jää tyhjäksi.
