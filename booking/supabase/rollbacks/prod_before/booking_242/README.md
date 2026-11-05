# booking_242_pikakassa_vapaa_rivi

Pikakassaan vapaa laskurivi ilman katalogituotetta (`order_items.kind = 'custom'`).

## Tiedostot
- `up.sql` – kind-check + custom_shape + `_counter_lines` / `_counter_checkout` / `admin_pos_checkout`
- `rollback.sql` – prod_before-funktiot + kind-check ilman customia (vaatii ettei custom-rivejä ole)
- `prod_before/` – PROD-määritelmät ennen muutosta
- `t242_pikakassa_vapaa_rivi.sql` – paikallinen testi (ROLLBACK)
- `KOODARILLE.md` – frontin rajapinta

## Paikallinen ajo (portti 54237)
1. Lataa `prod_before/*.sql` (tai käytä pohjaa jossa vanhat funktiot)
2. `up.sql` → `t242_*.sql` → `rollback.sql` → `up.sql`
