# Roolit ja kb-muokkaus

Roolit ja oikeudet ovat **taulupohjaisia**: `booking.roles` (rooli: `code`, `label`, `is_staff`) ja `booking.role_permissions` (rooli → oikeus). Henkilöstö on taulussa `booking.staff` (`user_id` → `auth.users`, `role` → `roles.code`, `active`). Pelkkä Supabase Auth -tunnus **ei** anna mitään oikeuksia; ilman aktiivista `staff`-riviä kaikki hallinnan kutsut palauttavat "Ei oikeuksia" ja RLS palauttaa 0 riviä. Epäaktiivinen rivi = ei oikeuksia (testattu). Oikeudet pakotetaan tietokannassa (`admin_*`-funktiot kutsuvat `_require_permission(...)`, RLS käyttää `has_permission(...)`); hallinnan UI vain piilottaa/lukitsee kentät saman oikeuslistan (`admin_my_permissions()`) mukaan.

## Roolit

| Rooli | Kuka | Henkilöstö? | Oikeudet |
|---|---|:-:|---|
| `admin` | Joonas, Koodari | ✔ | kaikki |
| `manager` (ylläpitäjä) | Otto, Laura | ✔ | varaukset, asiakkaat, maksut, sulut + hinnat/kuvaukset/tuoteasetukset (`catalog.edit`), muut asetukset (`settings.edit`), resurssit/kapasiteetit (`resources.edit`), vuorosäännöt (`rules.edit`), vuosikortit (`annual_cards.manage`). **Ei** henkilöstöhallintaa eikä audit-lokia |
| `staff` (peruskäyttäjä) | kaikki työntekijät | ✔ | varausten ja asiakkaiden katselu, luonti ja muokkaus (`bookings.manage`, `customers.manage`), maksujen kirjaus (`payments.manage`), sulut (`blocks.manage`). **Ei** hinta-, tuote- eikä asetusmuokkausta |
| `customer` | verkkoasiakas | ✘ | ei hallinnan oikeuksia (ei voi olla `staff`-rivin roolina – FK `roles(code, is_staff)`) |
| `annual_card` | vuosikorttiasiakas | ✘ | ei hallinnan oikeuksia; ilmaiset varaukset yleisiin vuoroihin (1 hlö, yksi tuleva kerrallaan) – moottoritason säännöt, ks. alla |

Oikeudet (`role_permissions.permission`): `bookings.manage`, `customers.manage`, `payments.manage`, `blocks.manage`, `catalog.edit`, `settings.edit`, `resources.edit`, `rules.edit`, `annual_cards.manage`, `staff.manage`, `audit.read`.

| Toiminto | anon | staff | manager | admin |
|---|:-:|:-:|:-:|:-:|
| Katalogi, vapaat vuorot, varauksen teko (rate limit), oman varauksen muutos (≥ 48 h, token) | ✔ | ✔ | ✔ | ✔ |
| Varausten ja asiakkaiden lukeminen, haku | ✘ | ✔ | ✔ | ✔ |
| Manuaalinen varaus, varauksen muutos, tilan muutos, peruutus, maksun kirjaus, sulut | ✘ | ✔ | ✔ | ✔ |
| Asiakastietojen muokkaus + markkinointiluvan kirjaus | ✘ | ✔ | ✔ | ✔ |
| **Tuotteiden nimet/kuvaukset/hinnat/ALV (kb), hintavariantit, tuoteasetukset** | ✘ | **✘ (vain luku)** | ✔ | ✔ |
| Asetukset (`admin_set_setting`), resurssit/kapasiteetit | ✘ | ✘ | ✔ | ✔ |
| Vuorosääntöjen muokkaus (nimi, päällä/pois, hlömäärät, deadline, voimassaolo) | ✘ | ✘ | ✔ | ✔ |
| Vuosikortin myöntö / jatko / peruutus | ✘ | ✘ | ✔ | ✔ |
| Vuosikorttivarauksen teko hallinnasta | ✘ | ✔ | ✔ | ✔ |
| Henkilökunta ja roolit, audit-loki | ✘ | ✘ | ✘ | ✔ |
| Maksuadapteri (`payment_*`) | ✘ | ✘ | ✘ | ✘ (vain `service_role`, palvelinpuoli) |

Turvasäännöt: manager ei voi muokata henkilöstön rooleja eikä antaa admin-oikeutta (vain `admin` / `staff.manage`); viimeistä aktiivista adminia ei voi alentaa tai poistaa käytöstä. Testit: `06_roles.test.sql`.

## Uuden roolin lisääminen (ei koodimuutoksia)

Roolit eivät ole kovakoodattu enum. Esimerkki: kirjanpitäjä, joka saa vain kirjata maksuja.
```sql
insert into booking.roles (code, label, description, is_staff, sort_order) values ('bookkeeper', 'Kirjanpitäjä', 'Maksujen kirjaus', true, 25);
insert into booking.role_permissions (role_code, permission) values ('bookkeeper', 'payments.manage');
-- sen jälkeen valittavissa hallinnan henkilöstölistassa (admin_list_roles) ja annettavissa: insert into booking.staff (...) role = 'bookkeeper'
```
Ei-henkilöstöroolit (`is_staff = false`) eivät voi olla `staff.role`. Uusi **oikeus** (esim. `reports.read`) vaatii lisäksi, että funktio kutsuu `perform booking._require_permission('reports.read')` – tähän tarvitaan koodimuutos funktioon, mutta ei roolitauluihin.

## Vuosikortti (`annual_card`)
* Taulu `booking.annual_cards` (`customer_id`, `valid_from`, `valid_to`, `active`, `notes`); asiakkaan `customer_type` vaihtuu automaattisesti `annual_card` ↔ `customer`. Kortti ei voi olla päällekkäinen saman asiakkaan toisen aktiivisen kortin kanssa.
* Varausmoottorin trigger pakottaa: vain yleinen vuoro, tilauksen summa 0 €, kortti aktiivinen ja voimassa vuoron päivänä, kortti kuuluu varauksen asiakkaalle, henkilömäärä ≤ `annual_card_max_persons` (oletus 1) ja korttia kohti vain yksi tuleva `pending`/`confirmed`-varaus (`starts_at > now()`). Ei yksityisvuoroja.
* Hallinnasta: `admin_grant_annual_card`, `admin_update_annual_card`, `admin_revoke_annual_card(id, cancel_future)`, `admin_list_annual_cards`, `admin_create_annual_card_booking`.
* **Itsepalvelua ei vielä ole.** Rakenne on valmis: `customers.auth_user_id` (→ `auth.users`) ja `annual_card`-rooli. Myöhemmin riittää kirjautuminen + RLS-politiikka/funktio, joka tunnistaa asiakkaan `auth.uid()`:llä.

## kb-muokkaus
* `admin_update_product(id, patch)`: sallitut kentät `name, name_en, description, description_en, price, price_text, vat_rate, active` (ALV vain 0/10/13.5/14/24/25.5, hinta 0–100000).
* `admin_update_price_variant(id, patch)`: `label, price, notes, active, included_persons, extra_person_price`.
* Kumpikin kirjaa `booking.audit_log` (vanha + uusi rivi) **ja** `kb.change_log` (`actor = 'booking-admin:<uid>'`). Muut kb-sarakkeet ja -taulut eivät ole muokattavissa tätä kautta.
* Funktiot ovat `SECURITY DEFINER`, `search_path=''`, vain `authenticated`-oikeudella ja oikeus `catalog.edit` (manager, admin) tarkistetaan funktion sisällä.
* **kb-skeemaan ei tehdä migraatioita tässä PR:ssä.** Jos haluat että muokkaus kulkee kb:n omien oikeuksien kautta tai muutokset vaativat muita kb-sarakkeita, pyydä erikseen Bottiavustukselta.

## Ensimmäinen admin
`supabase/manual/02_first_admin.sql`: kolme erillistä lohkoa – admin (Joonas, Koodari), manager (Otto, Laura), staff (muut). Lisähenkilöt hallinnasta (Asetukset → Henkilökunta; vain admin) kun admin on olemassa; Authin käyttäjä luodaan aina ensin Supabase Authissa.
