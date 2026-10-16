# Roolit ja kb-muokkaus

Roolit ovat taulussa `booking.staff` (`user_id` → `auth.users`, `role` `admin` | `staff`, `active`). Pelkkä Supabase Auth -tunnus **ei** anna mitään oikeuksia; ilman aktiivista `staff`-riviä kaikki hallinnan kutsut palauttavat "Ei oikeuksia" ja RLS palauttaa 0 riviä. Epäaktiivinen rivi = ei oikeuksia (testattu).

| Toiminto | anon | staff | admin |
|---|:-:|:-:|:-:|
| Katalogi, vapaat vuorot, varauksen teko (rate limit) | ✔ | ✔ | ✔ |
| Varausten ja asiakkaiden lukeminen, haku | ✘ | ✔ | ✔ |
| Manuaalinen varaus, tilan muutos, peruutus, maksun kirjaus, sulut | ✘ | ✔ | ✔ |
| Asiakastietojen muokkaus + markkinointiluvan kirjaus | ✘ | ✔ | ✔ |
| **Tuotteiden nimet/kuvaukset/hinnat/ALV (kb)** | ✘ | **✘ (vain luku)** | ✔ |
| Hintavariantit (kb) | ✘ | ✘ | ✔ |
| Verkkokaupan tuoteasetukset, resurssit/kapasiteetit, asetukset | ✘ | ✘ (luku) | ✔ |
| Henkilökunta ja roolit, audit-loki | ✘ | ✘ | ✔ |
| Maksuadapteri (`payment_*`) | ✘ | ✘ | ✘ (vain `service_role`, palvelinpuoli) |

**Ehdotus: staff ei muokkaa hintoja** (virheen tai väärinkäytön riski, ja hinnat ovat sivuston ja botin yhteinen totuus). Jos halutaan sallia, muutos on yhden rivin: `_require_admin()` → `_require_staff()` funktiossa `admin_update_product` (uusi migraatio).

## kb-muokkaus
* `admin_update_product(id, patch)`: sallitut kentät `name, name_en, description, description_en, price, price_text, vat_rate, active` (ALV vain 0/10/13.5/14/24/25.5, hinta 0–100000).
* `admin_update_price_variant(id, patch)`: `label, price, notes, active, included_persons, extra_person_price`.
* Kumpikin kirjaa `booking.audit_log` (vanha + uusi rivi) **ja** `kb.change_log` (`actor = 'booking-admin:<uid>'`). Muut kb-sarakkeet ja -taulut eivät ole muokattavissa tätä kautta.
* Funktiot ovat `SECURITY DEFINER`, `search_path=''`, vain `authenticated`-oikeudella ja rooli tarkistetaan funktion sisällä.
* **kb-skeemaan ei tehdä migraatioita tässä PR:ssä.** Jos haluat että muokkaus kulkee kb:n omien oikeuksien kautta tai muutokset vaativat muita kb-sarakkeita, pyydä erikseen Bottiavustukselta.

## Ensimmäinen admin
`supabase/manual/02_first_admin.sql` (ks. README). Lisähenkilöt hallinnasta (Asetukset → Henkilökunta) kun admin on olemassa; Authin käyttäjä luodaan aina ensin Supabase Authissa.
