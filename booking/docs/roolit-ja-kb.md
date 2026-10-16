# Roolit ja kb-muokkaus

Roolit ja oikeudet ovat **taulupohjaisia**: `booking.roles` (rooli: `code`, `label`, `is_staff`) ja `booking.role_permissions` (rooli → oikeus). Henkilöstö on taulussa `booking.staff` (`user_id` → `auth.users`, `role` → `roles.code`, `active`). Pelkkä Supabase Auth -tunnus **ei** anna mitään oikeuksia; ilman aktiivista `staff`-riviä kaikki hallinnan kutsut palauttavat "Ei oikeuksia" ja RLS palauttaa 0 riviä. Epäaktiivinen rivi = ei oikeuksia (testattu). Oikeudet pakotetaan tietokannassa (`admin_*`-funktiot kutsuvat `_require_permission(...)`, RLS käyttää `has_permission(...)`); hallinnan UI vain piilottaa/lukitsee kentät saman oikeuslistan (`admin_my_permissions()`) mukaan.

## Roolit

| Rooli | Kuka | Henkilöstö? | Oikeudet |
|---|---|:-:|---|
| `admin` | Joonas, Koodari | ✔ | kaikki (13 oikeutta, myös käyttäjähallinta `staff.manage` ja `shifts.view` + `shifts.view_all`) |
| `manager` (ylläpitäjä) | Otto, Laura | ✔ | varaukset, asiakkaat, maksut, sulut + hinnat/kuvaukset/tuoteasetukset (`catalog.edit`), muut asetukset (`settings.edit`), resurssit/kapasiteetit (`resources.edit`), vuorosäännöt (`rules.edit`), vuosikortit (`annual_cards.manage`) + kaikkien työvuorojen katselu (`shifts.view_all`). **Ei** käyttäjähallintaa (`staff.manage`: kutsut, roolit, käytöstä poisto, linkitys) eikä audit-lokia |
| `staff` (peruskäyttäjä) | kaikki työntekijät | ✔ | varausten ja asiakkaiden katselu, luonti ja muokkaus (`bookings.manage`, `customers.manage`), maksujen kirjaus (`payments.manage`), sulut (`blocks.manage`) + **omien** työvuorojen katselu (`shifts.view`). **Ei** hinta-, tuote- eikä asetusmuokkausta |
| `customer` | verkkoasiakas | ✘ | ei hallinnan oikeuksia (ei voi olla `staff`-rivin roolina – FK `roles(code, is_staff)`) |
| `annual_card` | vuosikorttiasiakas | ✘ | ei hallinnan oikeuksia; ilmaiset varaukset yleisiin vuoroihin (1 hlö, yksi tuleva kerrallaan) – moottoritason säännöt, ks. alla |

Oikeudet (`role_permissions.permission`): `bookings.manage`, `customers.manage`, `payments.manage`, `blocks.manage`, `catalog.edit`, `settings.edit`, `resources.edit`, `rules.edit`, `annual_cards.manage`, `staff.manage`, `audit.read`, `shifts.view` (omat työvuorot), `shifts.view_all` (kaikkien työvuorot).

| Toiminto | anon | staff | manager | admin |
|---|:-:|:-:|:-:|:-:|
| Katalogi, vapaat vuorot, varauksen teko (rate limit), oman varauksen muutos (≥ 48 h, token) | ✔ | ✔ | ✔ | ✔ |
| Varausten ja asiakkaiden lukeminen, haku | ✘ | ✔ | ✔ | ✔ |
| Manuaalinen varaus, varauksen muutos, tilan muutos, peruutus, maksun kirjaus, sulut | ✘ | ✔ | ✔ | ✔ |
| Asiakastietojen muokkaus + markkinointiluvan kirjaus, **uuden asiakkaan lisäys (yksityinen/yritys)** | ✘ | ✔ | ✔ | ✔ |
| Lisäpalvelun valinta/muokkaus varaukselle (`admin_set_reservation_addons`), tilauksen laskutustietojen katselu | ✘ | ✔ | ✔ | ✔ |
| **Lisäpalvelujen nimet/kuvaukset/hinnat/ALV/aktiivisuus** (`catalog.edit`, kuten tuotetiedot) | ✘ | **✘ (vain luku)** | ✔ | ✔ |
| **Tuotteiden nimet/kuvaukset/hinnat/ALV (kb), hintavariantit, tuoteasetukset** | ✘ | **✘ (vain luku)** | ✔ | ✔ |
| Asetukset (`admin_set_setting`), resurssit/kapasiteetit | ✘ | ✘ | ✔ | ✔ |
| Vuorosääntöjen muokkaus (nimi, päällä/pois, hlömäärät, deadline, voimassaolo) | ✘ | ✘ | ✔ | ✔ |
| Vuosikortin myöntö / jatko / peruutus | ✘ | ✘ | ✔ | ✔ |
| Vuosikorttivarauksen teko hallinnasta | ✘ | ✔ | ✔ | ✔ |
| Käyttäjähallinta (kutsu, rooli, käytöstä poisto, linkitys työntekijään), audit-loki | ✘ | ✘ | ✘ | ✔ |
| Työvuorojen katselu (vain luku, `admin_upcoming_shifts`) | ✔ vain omat | ✔ vain omat | ✔ kaikki | ✔ kaikki |
| Maksuadapteri (`payment_*`) | ✘ | ✘ | ✘ | ✘ (vain `service_role`, palvelinpuoli) |

Turvasäännöt: **`staff.manage` on vain adminilla**, joten manager ei voi kutsua käyttäjiä, vaihtaa rooleja, poistaa käyttäjiä käytöstä eikä linkittää työntekijöitä. Manager ei voi muokata henkilöstön rooleja eikä antaa admin-oikeutta (vain `admin` / `staff.manage`); viimeistä aktiivista adminia ei voi alentaa tai poistaa käytöstä. Testit: `06_roles.test.sql`.

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

## Käyttäjähallinta (hallinnan Käyttäjät-näkymä, vain admin)

Näkymä `admin/views/users.js` (valikko **Käyttäjät**, näkyy vain oikeudella `staff.manage`):

| Toiminto | Miten | Missä säännöt |
|---|---|---|
| Kutsu käyttäjä sähköpostilla | Edge Function `admin-users` (`invite`): Auth Admin API `inviteUserByEmail` + `booking.staff`-rivi roolilla | `booking.svc_staff_upsert` (service_role) |
| Roolin vaihto | `booking.admin_set_staff_role(user_id, role)` | ei itseä, ei viimeistä aktiivista adminia, kohde aktiivinen ja jo `booking.staff`-taulussa, rooli olemassa ja `is_staff`, audit-loki |
| Poista käytöstä / aktivoi | Edge Function (`deactivate` / `reactivate`): `booking.staff.active` + Auth-esto (ban) | `booking.svc_staff_set_active`: ei itseä, ei viimeistä adminia |
| Linkitys työntekijään (työvuorot) | `booking.admin_list_public_staff()` + `booking.admin_link_public_staff(user_id, public_staff_id)` | `public.staff`-rivin pitää olla olemassa ja aktiivinen; sama työntekijä ei voi olla kahdella käyttäjällä (`public_staff_taken`); kirjoittaa vain `booking.staff`-tauluun |

Kutsuttavat roolit ovat sallittulistalta **admin / manager / staff**; `customer` ja `annual_card` eivät kelpaa (Edge Function hylkää, tietokanta tarkistaa vielä `booking.roles.is_staff`).
Kutsun hyväksyntä: sähköpostin linkki avaa hallinnan osoitteella `…/admin/#access_token=…&type=invite`; hallinta ottaa istunnon käyttöön, siivoaa tokenit osoiteriviltä ja pyytää käyttäjää asettamaan salasanan (min. 8 merkkiä).
Jos kutsutulla sähköpostilla on jo Auth-tunnus, uutta kutsua ei lähetetä, vaan tunnukselle annetaan vain rooli.
Edge Function: ks. [`bottiavustus-pyynto.md`](bottiavustus-pyynto.md) (deploy, salaisuudet) ja `supabase/functions/admin-users/`. Palvelurooliavain ei koskaan mene selaimeen: funktio tarkistaa kutsujan omalla JWT:llä (`booking.is_admin()`) ja käyttää avainta vasta sen jälkeen.

`booking.staff.public_staff_id` (uuid, uniikki, **ei viiteavainta** `public`-skeemaan): löyhä viittaus `public.staff.id`:hen. Viiteavain jätettiin pois, jotta `booking` ei riipu Työvuoro-Tapion skeemasta (migraatiot ja testit toimivat ilman sitä, eikä `public`-muutos voi rikkoa varausjärjestelmää).

## Työvuorot (vain luku, `public`-skeemasta)

Totuus on Google Calendar → Työvuoro-Tapio-synkka → `public.work_shifts`. Varausjärjestelmä **vain lukee** vuoroja (kalenterinäkymä); vuorojen muokkausta ei ole toteutettu eikä `public`-skeemaan kirjoiteta (ei INSERT/UPDATE/DELETE/DDL/GRANT; testattu: taulujen sisältö ei muutu eikä yksikään `booking`-funktio sisällä kirjoituslauseita `public.`-tauluihin).

`booking.admin_upcoming_shifts(p_from, p_to)` – `SECURITY DEFINER`, `search_path=''`, täysin kvalifioidut nimet, vain `authenticated`:
* lukee vain `public.work_shifts`, `public.shift_assignments`, `public.staff`, `public.calendar_sources`; suodatin `work_shifts.status = 'active'`;
* palauttaa vain: `shift_id, starts_at, ends_at, role_type, calendar_name, staffing_status, staff_name` (**ei** puhelinta, sähköpostia, muistiinpanoja eikä kalenteri-id:tä); yksi rivi per nimetty työntekijä;
* enintään 62 päivän aikaväli (muuten virhe `range_too_long`; +1 h liikkumavara kesäaikasiirtymälle), käänteinen/tyhjä väli → `invalid_range`;
* `shifts.view_all` (admin, manager) näkee kaikki; `shifts.view` (staff) vain omat vuoronsa linkin `booking.staff.public_staff_id` kautta (ei linkkiä → tyhjä lista; omalta vuorolta ei näy kollegojen nimiä); ei kumpaakaan oikeutta → virhe `forbidden`.
* **Näyttö suomeksi (v10, vain frontend, ei SQL-muutosta):** hallinnan kalenteri (`admin/views/calendar.js`) kartoittaa `role_type`-koodit kiinteästi suomeksi: `heater` → Lämmitykset, `reception` → Vastaanotto, `therapist` → Saunottaja. Tuntemattomalle koodille näytetään `calendar_name` (sana "Hoitaja" → "Saunottaja") tai koodi sellaisenaan. `staffing_status`: `assigned`/`full` → Miehitetty, `unassigned`/`open` → Avoin, `partial` → Osittain (avoin korostetaan keltaisella), muut arvot näytetään sellaisenaan. Koodia ei näytetä käyttäjälle.

`public`-taulujen lukuoikeus annetaan vain funktion omistajalle (SECURITY DEFINER): `authenticated`/`anon` eivät saa suoria oikeuksia `public`-tauluihin (testikanta todistaa tämän: mockiin ei anneta GRANTteja).

### OLETETUT `public`-sarakkeet (varmistettava ennen migraatioiden ajoa!)

Tätä koodia kirjoitettaessa ei ollut yhteyttä oikeaan `public`-skeemaan, joten sarakenimet ovat **oletuksia**. Bottiavustuksen pitää tarkistaa ne `list_tables`-työkalulla (vain luku) ennen migraatioiden ajoa ja ilmoittaa poikkeamat; funktiot (`_check_public_staff`, `admin_list_public_staff`, `admin_upcoming_shifts`) ovat plpgsql-kielellä, joten väärä sarakenimi ei kaada migraatiota vaan vasta kutsun ajonaikana (siksi tarkistus ensin).

| Taulu | Oletetut sarakkeet | Käyttö |
|---|---|---|
| `public.work_shifts` | `id uuid`, `calendar_source_id uuid` (→ `calendar_sources.id`), `starts_at timestamptz`, `ends_at timestamptz`, `role_type text`, `status text` (arvo `'active'` = voimassa), `staffing_status text` | vuoron aika, rooli, tila |
| `public.shift_assignments` | `shift_id uuid` (→ `work_shifts.id`), `staff_id uuid` (→ `staff.id`) | kuka on vuorossa |
| `public.staff` | `id uuid`, `name text`, `email text`, `active boolean` | työntekijän nimi; linkitys ja listaus (vain id, name, email, active palautetaan) |
| `public.calendar_sources` | `id uuid`, `calendar_name text` | kalenterin nimi |

Jos jokin nimi poikkeaa (esim. `full_name`, `start_time`, `is_active`), korjataan vain funktioiden `SELECT`-osat migraatiossa 06 (`_check_public_staff`, `admin_list_public_staff`, `admin_upcoming_shifts`) – muuta koodia ei tarvitse muuttaa. Testien mock: `supabase/tests/fixtures/public_mock.sql` (sisältää tahallaan myös `phone`- ja `notes`-sarakkeita todistamaan, ettei niitä vuoda).

## Ensimmäinen admin
`supabase/manual/02_first_admin.sql`: testivaiheessa vain **yksi** lohko – Joonas (admin, Joonas.vaarala@gmail.com); muut roolit ovat kommentoituina. Authin käyttäjä luodaan ensin Supabase Authissa (Dashboard → Add user). Muut käyttäjät kutsutaan jatkossa hallinnan Käyttäjät-näkymästä (vain admin; Edge Function `admin-users`).
