# booking_242 – rajapinta Koodarille (pikakassa vapaa rivi)

## admin_pos_checkout(p_items, p_locale, p_email)

`p_items` on taulukko, jossa rivit ovat joko:

### Tuoterivi (ennallaan)
```json
{ "product_id": 123, "quantity": 2 }
```
Hintaa / ALV:ia ei saa antaa (`price_locked`).

### Vapaa rivi (uusi)
```json
{
  "kind": "custom",
  "description": "Pyyhevuokra",
  "quantity": 1,
  "unit_price": 5.50,
  "vat_rate": 25.5
}
```
Tai sentteinä: `"unit_price_cents": 550` (kokonaisluku ≥ 0) `unit_price`:n sijaan.

Säännöt:
- `description` pakollinen, trimattu, 1–200 merkkiä, ei `<`
- `quantity` kokonaisluku 1–20
- `unit_price` ≥ 0 €, max 2 desimaalia, max 100000
- `vat_rate` vain `booking.vat_rates` missä `active` (nyt 0 / 13.5 / 25.5)
- vain pikakassa (`pos`); kylmälaite hylkää
- tilauksen `total` pitää olla > 0 (`nothing_to_pay`); 0 € vapaa rivi ok, jos mukana on maksettavaa
- enintään 12 riviä (tuoteaggregaatti + vapaat)

Vastauksen `lines[]` sisältää `kind` (`product` | `custom`). Customilla `product_id` on null.

## Tallennus
`order_items`: `kind='custom'`, `product_id` null, `product_name` = kuvaus. Kuitti / lasku / hyvitys lukevat `product_name` / payment_lines.description – ei muutoksia edge-funktioihin.

## UI
Pikakassa: "Lisää vapaa rivi" → kuvaus, määrä, hinta (€), ALV-select (`admin_list_vat_rates` active). Ostoskoriin kuten tuotteet; `checkoutItems` lähettää uuden muodon.
