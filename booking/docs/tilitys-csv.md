# Tilitys-CSV (Saunotus-tilitys-CSV v1)

booking_349 (K9). Maksuvälittäjän tilitysraportti tuodaan tällä muodolla. Tuonti tapahtuu hallinnassa (Talous → Raportit → Provisiot → Tilitykset) tai kutsulla `booking.svc_import_settlement_csv` (service_role, Bottiavustus).

## Tiedosto

- UTF-8. BOM saa olla. Rivinvaihto `\n` tai `\r\n`. Tyhjät rivit ohitetaan.
- Erotin päätellään otsikkorivistä: `;` → puolipiste, muuten sarkain, muuten `,`.
- Kenttä voi olla lainausmerkeissä (`"a;b"`). Lainausmerkki kentän sisällä kirjoitetaan kahdesti (`""`).
- Enintään 5000 riviä ja 1 Mt.
- Ensimmäinen rivi on otsikko. Sarakkeiden järjestys on vapaa. Tuntemattomat sarakkeet ohitetaan, mutta ne tallentuvat rivin `raw`-kenttään.

## Sarakkeet

| Sarake | Hyväksytyt otsikot | Pakollinen | Sisältö |
|---|---|---|---|
| erä | `erä`, `era`, `batch`, `batch_id`, `batch_ref`, `settlement_id`, `payout_id` | kyllä | Välittäjän tilityserän tunnus. Saman erän rivien pitää olla samalta päivältä. |
| päivä | `päivä`, `paiva`, `pvm`, `date`, `settled_on`, `settlement_date`, `payout_date` | kyllä | Tilityspäivä `2026-11-20` tai `20.11.2026`. |
| laji | `laji`, `tyyppi`, `type` | kyllä | `maksu`/`payment`/`sale`/`myynti`, `hyvitys`/`refund`, `kulu`/`fee`/`palkkio`, `oikaisu`/`adjustment`/`korjaus`. |
| viite | `viite`, `reference`, `ref`, `merchant_reference`, `order_reference`, `transaction_id` | ei | Maksulla: `payments.provider_ref` (esim. `sauna-o15384`) tai Montonion `order_uuid`. Hyvityksellä: `refunds.provider_refund_id`. |
| maksu_id | `maksu_id`, `payment_id` | ei | Saunotuksen `payments.id`. Jos annettu, sitä käytetään viitteen sijaan. |
| brutto | `brutto`, `gross`, `amount` | kyllä | Maksu positiivinen, hyvitys negatiivinen. Kululla 0. |
| kulu | `kulu`, `palkkio`, `provisio`, `fee`, `fees` | kyllä | Välittäjän kulu positiivisena. |
| netto | `netto`, `net` | ei | Jos annettu, pitää olla brutto − kulu (±0,01). Muuten lasketaan. |
| valuutta | `valuutta`, `currency` | ei | Vain `EUR`. |

Luvut voi kirjoittaa suomalaisittain tai pisteellä: `1 234,56`, `1.234,56`, `1,234.56`, `1234.56`, `-10,00`, `12 €`.

## Esimerkki

```
erä;päivä;laji;viite;brutto;kulu;netto
M-2026-11-20;2026-11-20;maksu;sauna-o15384;50,00;0,85;49,15
M-2026-11-20;2026-11-20;hyvitys;rf-123;-10,00;0,00;-10,00
M-2026-11-20;2026-11-20;kulu;kuukausimaksu;0;4,90;-4,90
```

## Tuonti

1. **Esikatselu** (`p_dry_run = true`, oletus). Mitään ei tallenneta. Vastaus sisältää erät ja niiden summat, kohdistamattomat rivit, kuluristiriidat ja kulutilin.
2. **Tuonti** (`p_dry_run = false`) tallentaa erät (`booking.settlements`) ja rivit (`booking.settlement_items`).
   - Kohdistetun maksun `payments.provider_fee` ja hyvityksen `refunds.provider_fee` täytetään, jos kenttä on tyhjä.
   - Jos maksulla on jo eri suuruinen kulu, sitä ei muuteta, ja rivi merkitään `conflict`-tilaan. Poikkeus: `p_overwrite_fees = true` (`overwritten`).
3. Kaikki tai ei mitään. Yksikin virheellinen rivi tai jo tuotu erä (sama palvelu + erä) kumoaa koko tuonnin.
4. Kohdistamattomat rivit tallentuvat (`unmatched`/`ambiguous`), mutta kuluja ei täytetä niille.

## Kulutili

- Tili luetaan Procountor-asetuksesta `accounts.provider_fee`. Sen voi asettaa hallinnassa tai kutsulla `admin_set_provider_fee_account`.
- Tili tallentuu tuontihetken arvona erälle (`settlements.fee_account`).
- **Kuluja ei vielä kirjata** kirjanpitoon (`posted = false`), eikä Procountoriin lähetetä mitään.

## Avoin

Montonion ja SumUpin omat tilitysraportit eivät ole tässä muodossa. Sarakkeiden aliakset kattavat yleisimmät nimet, mutta todellinen raportti pitää tarkistaa ja tarvittaessa muuntaa tähän muotoon, ennen kuin sen voi tuoda.
