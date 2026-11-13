# Uutiskirjeen tilanne: lähtötiedot Claude Codelle (backlog 15)

Päivitetty 13.11.2026 (Koodari). Tämä on luovutusmuistio uutiskirjeen viimeistelyyn. Lue ensin repon juuren [CLAUDE.md](../../CLAUDE.md), koska sen säännöt ovat aina tämän dokumentin edellä.

Tiedot on tarkistettu 13.11.2026 aamupäivällä: `origin/main` (b0fc082), PROD-kanta (`sxbofnuisemspgquoxyv`) pelkillä SELECT-kyselyillä sekä boxin paikalliset haarat ja kansiot. Dokumentissa on vain rivimääriä, ei henkilötietoja.

## Tiivistelmä

1. Uutiskirjeen tietokantaosa (booking_259 + booking_262) on ajettu DEViin ja PRODiin 6.11.2026, ja se on mainissa PR #348:n kautta. Kaikki taulut ovat PRODissa tyhjiä.
2. Käyttöliittymää, lähettäjää (send-emails) ja peruutussivua **ei ole mainissa**. Ne ovat Koodari2:n haarassa, joka on GitHubissa nimellä `arkisto/newsletter-admin-259`. **Claude Code jatkaa siitä** (Joonas 13.11. klo 9.47): rebase tai merge uusimpaan mainiin ja muutokset siihen, ei mergeä mainiin.
3. Lähetykselle **ei ole omaa kytkintä (lippua)**. PRODissa Resend on `live`, ja `admin_newsletter_dispatch` on `authenticated`-roolin ajettavissa. Ainoa este on käyttöoikeus `messages.edit` ja se, ettei käyttöliittymää ole.
4. Peruutuksia on nyt kahdessa taulussa: `newsletter_suppressions` (259) ja `marketing_suppressions` (285). Lähetys tarkistaa vain ensimmäisen. Taulut pitää yhdistää ennen käyttöönottoa.
5. Sivutekstit puuttuvat PRODista kokonaan, eikä haaran tuontinumero 131 ole enää vapaa.

---

## 1. Valmiina mainissa ja PRODissa

### Migraatiot (ajettu, mainissa)
| Tiedosto | PROD-versio | DEV-versio | Sisältö |
|---|---|---|---|
| `booking/supabase/migrations/20261106223314_booking_259_newsletters.sql` | 20261106223314 | 20261106223149 | Taulut, funktiot, peruutusten kaappaus-triggeri ja takautuva täyttö |
| `booking/supabase/migrations/20261106223319_booking_262_newsletter_capture.sql` | 20261106223319 | 20261106223153 | Pelkkä tarkistus (ei muutoksia): 259:n pysyvät osat ovat olemassa ja oikean muotoisia |
| `booking/supabase/migrations/20261113064842_booking_285_customer_merge_anonymize.sql` | 20261113064842 | 20261113064744 | Yhdistäminen ja anonymisointi. Tuo taulun `marketing_suppressions` ja funktion `is_email_suppressed(text)` |

Mainin 259- ja 262-tiedostojen runko on sama kuin Koodari2:n haarassa (`20261106220300_…` ja `20261106221404_…`). Vain ensimmäinen kommenttirivi ja aikaleima eroavat. **Rollback-tiedostot 259:lle ja 262:lle puuttuvat mainista** (ks. kohta 2).

### PROD-kannan objektit (skeema `booking`)
- **Taulut:** `newsletters`, `newsletter_logs`, `newsletter_optout_tokens`, `newsletter_suppressions` (259) ja `marketing_suppressions` (285). Vanhemmat ja käyttämättömät taulut: `marketing_segments`, `marketing_segment_members` sekä `marketing_consent_events` (suostumushistoria).
- **Sekvenssit:** `newsletter_campaign_id_seq` ja `newsletter_log_id_seq`. Ne ovat tarkoituksella OWNED BY NONE, eikä niitä saa nollata.
- **Funktiot:** `_newsletter_fingerprint`, `_newsletter_capture_general_optout`, `_newsletter_address_blocked`, `public_newsletter_unsubscribe(uuid)`, `_newsletter_validate`, `_newsletter_recipients(segment, language)`, `_newsletter_save`, `svc_newsletter_save` (service_role, bottien luonnokset), `admin_newsletter_save`, `admin_newsletters_list`, `admin_newsletter_dispatch(id, version, confirm, preview_token)` (vain authenticated + `messages.edit`) ja `email_newsletter_payload(outbox_id)` (service_role, lähettäjä). Lisäksi 285: `_email_hash`, `is_email_suppressed`. Vanha yhteinen `public_marketing_unsubscribe(uuid)` on booking_121:stä.
- **Triggeri:** `booking.customers.newsletter_capture_general_optout` (AFTER INSERT/UPDATE OF marketing_consent, marketing_unsubscribed_at), käytössä (`O`).
- **Outbox:** `email_outbox_kind_check` sallii lajin `newsletter`. Lisäksi on indeksit `newsletter_outbox_address_uq` ja `newsletter_outbox_log_idx`.
- Neljän pysyvän funktion runko vastaa 262:n SHA256-arvoja PRODissa (4/4).

### PROD-rivimäärät 13.11.2026
| Kohde | Rivejä |
|---|---|
| `newsletters` / `newsletter_logs` | 0 / 0 |
| `newsletter_optout_tokens` | 0 |
| `newsletter_suppressions` | 0 |
| `marketing_suppressions` | 0 |
| `email_outbox` where kind='newsletter' | 0 |
| asiakkaita, joilla markkinointilupa ja jotka eivät ole anonymisoituja | 1364 |
| asiakkaita, joilla `marketing_unsubscribed_at` on asetettu | 0 |
| `booking.site_texts`-avaimia, joissa on "newsletter" | 0 |
| `integration_config.resend.mode` | `live` (DEV: `off`) |
| `site_base_url`-asetus | asetettu |

DEVin rivimäärät ovat samat: kaikki uutiskirjetaulut ovat tyhjiä.

### Muu valmis koodi mainissa
- Markkinointiluvan kysyminen kaupassa: `booking/shop/src/i18n.js` (consentMarketing FI/EN) ja lahjakorttiostossa `booking/shop/src/gift-texts.js`.
- Yleinen markkinoinnin peruutus tilaussivulla: `booking/shop/src/order.js`, `unsubscribe()`, joka kutsuu RPC:tä `public_marketing_unsubscribe`.
- Asiakasnäkymä näyttää luvan ja peruutuksen: `booking/admin/views/customer-view.js` ja `order-view-texts.js` (`ui.admin.customer_view.consent_unsub`).
- Yhdistäminen ja anonymisointi kirjaavat peruutukset tauluun `marketing_suppressions`: `booking/admin/customer-admin-texts.js` (merge.consent.*, anonymize.suppression) ja testi `booking/tests/asiakas-yhdistaminen-285.test.mjs` sekä `booking/supabase/tests/t285_customer_merge_anonymize.sql`. Kytkimet `customer_merge_enabled` ja `customer_anonymize_enabled` ovat `booking.settings`-taulussa, ja niiden arvo on false.
- **Ei mainissa:** uutiskirjenäkymä, renderöijä, send-emails-käsittely lajille `newsletter`, peruutussivu `newsletter-unsubscribe.html`, sivutekstit ja testit (JS/SQL).

## 2. Keskeneräinen työ

### Koodari2:n haara, GitHubissa nimellä `arkisto/newsletter-admin-259`
- Sijainti: `/workspace/koodari2-newsletter` (oma klooni). Pohjana main `68bb8f9` (6.11.). Uusin commit on `997880e` (7.11. klo 00.28): "install capture atomically in booking259 and verify in262".
- **Joonas päätti 13.11.2026 klo 9.47: Claude Code jatkaa tästä haarasta.** Koodari pushasi sen GitHubiin nimellä `arkisto/newsletter-admin-259` (commit `997880e`, alkuperäinen paikallinen nimi `feat/newsletter-admin-259`). Tee omasta haarastasi `claude/uutiskirje` haaran `arkisto/newsletter-admin-259` pohjalta. Tuo uusin main mukaan rebasella tai mergellä ja tee kaikki muutokset siihen. Arkistohaaraa ei muuteta. Älä mergeä mainiin: avaa luonnos-PR, jonka Koodari katselmoi ja mergeää.
- Haarasta ei ole PR:ää. GitHub-haku `newsletter` ja `uutiskirje` löytää vain PR:t #317, #318, #348 ja #349, eikä mikään niistä ole uutiskirjeen käyttöliittymä.
- Haaran tila: 108/108 JS-yksikkötestiä läpi (`/workspace/koodari2-newsletter-unit-results.txt`). SQL-testit on ajettu paikallisessa embedded-Postgresissa (`/workspace/koodari2-newsletter-pg/run.mjs`).
- Muutokset mainin pohjaan nähden (37 tiedostoa, noin 3500 riviä):
  - Käyttöliittymä: `booking/admin/newsletters.html` (erillinen sivu `/hallinta/newsletters.html`, ei muutoksia navigaatioon tai hallinnan runkoon), `newsletter-page.js`, `views/newsletters.js`, `newsletter-logic.js`, `newsletter-texts.js` ja `newsletter.css`.
  - Peruutussivu: `booking/admin/newsletter-unsubscribe.html` ja `.js` (julkinen, kutsuu RPC:tä `public_newsletter_unsubscribe`, token URL-fragmentissa).
  - Renderöijä: `booking/supabase/functions/_shared/newsletter-render.js`, jota sekä esikatselu että lähettäjä käyttävät.
  - Lähettäjä: `booking/supabase/functions/send-emails/index.ts` (+19 riviä). Rivi `kind='newsletter'` hakee RPC:llä `email_newsletter_payload` tuoreen suostumustarkistuksen ennen allowlistiä ja renderöintiä. Virheilmoituksissa ei ole henkilötietoja.
  - Build: `scripts/build-pages.mjs` kopioi renderöijän ja lisää versiotunnukset kahdelle uudelle HTML-sivulle.
  - SQL: haaran oma kopio 259:stä ja 262:sta (sama sisältö kuin mainissa), rollbackit `booking/supabase/rollbacks/20261106220300_booking_259_ROLLBACK.sql` ja `20261106221404_booking_262_ROLLBACK.sql`, testit `booking/supabase/tests/t259_newsletters*.sql` (4 kpl) ja `booking/supabase/tests/newsletters/*.sql` (11 kpl).
  - JS-testit: `booking/tests/newsletters.test.mjs` ja `newsletters.browser.mjs`.
  - Tekstit: `content/site-texts.pending-import-131.json` (avaimet `admin.newsletter.*`, 54 avainta FI+EN). **Numero 131 on jo mainissa käytössä muuhun** (booking_277-tekstit), joten tuonti pitää numeroida uudelleen.
  - Dokumentit: `booking/docs/newsletters-259.md` (laaja suunnitelma ja testijärjestys), `newsletter-resubscribe-proposal.md` (uudelleentilaus, EI toteutettu), `newsletter-reenable-proposal.sql` (numeroimaton ehdotus feature-rollbackin jälkeiseen uudelleenkäyttöönottoon) ja `newsletter-review-sha256.txt`.
- Haara on mainista jäljessä noin 7 päivää ja yli 30 PR:ää. Erityisesti `send-emails/index.ts`, `scripts/build-pages.mjs` ja hallinnan tiedostot ovat muuttuneet (mm. #318 UX, #338 send-emails, #350 build-listat). Aloita haarasta `arkisto/newsletter-admin-259` ja tuo siihen uusin main rebasella tai mergellä (haara `claude/uutiskirje`).

### SQL259-paketin "HOLD" ja katselmointihuomiot
- Paketti oli HOLD-tilassa korjattua versiota odottamassa. Uusin versio on haaran commit `997880e` (atominen 259 + tarkistava 262). Juuri tämä versio on ajettu DEViin ja PRODiin, ja se on nyt mainissa. Sen jälkeen uutta pakettia ei ole tehty. Kopiot: `/workspace/yoajo-migr/missing/` ja `/workspace/pr4-asiakas-merge/src/`.
- Koodarin read-only-arvio peruutustriggeristä: **yhteensopiva** nykyisen send-emailsin ja `public_marketing_unsubscribe`-funktion kanssa. Arviossa nousi esiin kaksi huomiota:
  1. **Rollback-ristiriita:** mainin 259-tiedoston otsikko viittaa rollbackiin `../rollbacks/20261106220300_booking_259_ROLLBACK.sql`, jota ei ole mainissa, ja aikaleima on eri kuin ajetulla versiolla. Haaran 259-rollback on vain "feature rollback": se poistaa `newsletters`- ja `newsletter_logs`-taulut sekä luonnos- ja lähetysfunktiot mutta säilyttää kaappauksen, suppressiot ja tokenit. 262:n rollback on tarkoituksella pelkkä `raise exception`. Tämä poikkeaa talon käytännöstä, jonka mukaan jokaisella migraatiolla on oikea rollback, ja dokumentit (newsletters-259.md ja reenable-proposal) kuvaavat elinkaaren monimutkaisemmin kuin itse tiedostot. Rollbackit pitää tuoda mainiin uusilla nimillä (PROD-versioiden mukaan) ja yhdenmukaistaa.
  2. **Pysyvä peruutus ("sticky"):** kun lupa on kerran peruttu (myös Johku-synkan true→false), osoitteen tiiviste jää tauluun `newsletter_suppressions`, eikä myöhempi `marketing_consent=true` palauta sitä listalle. Tämä on tarkoituksellista. Uudelleentilaukseen tarvitaan erikseen katselmoitu double opt-in -prosessi (`newsletter-resubscribe-proposal.md`), jota ei ole toteutettu.

### Muut kansiot boxilla
- `/workspace/koodari2-newsletter-pg/`: paikallinen SQL-testiajuri (embedded-postgres).
- `/workspace/rm259/` ja `/workspace/sd247/wt` (haara `rm259`) eivät liity uutiskirjeeseen (lyhyiden kuvausten tuontityökaluja).
- Etähaaroissa ei ole uutiskirjehaaroja (siivottu 13.11., lista `/workspace/deploy-278/haarasiivous-20261113.txt`; siinäkään ei ole uutiskirjehaaroja).

## 3. Mitä puuttuu valmiista ominaisuudesta

Backlog 15 (`kb.feature_backlog` id 15, "Asiakasryhmät ja uutiskirje", in_progress, needs_approval): bottien tekemät luonnokset näkyvät hallinnassa katsottavina. Tekstejä voi muokata, ja tyyli ja muotoilu tulevat botilta. Segmentit ovat koulutuksen käyneet, hoidoissa käyneet, tapahtumissa käyneet, pelkissä vuoroissa käyneet, muut relevantit ryhmät tai kaikki. Viesti lähtee vain markkinointiluvan antaneille, ja lähetys tehdään hallinnasta esikatselun jälkeen.

Puuttuu:
1. **Käyttöliittymä mainiin:** Koodari2:n näkymä siirretään uusimman mainin päälle ja sovitetaan nykyiseen hallintaan (#318 UX-uudistus, navigaatio). Päätä Joonaksen kanssa, onko näkymä erillinen sivu vai osa hallinnan valikkoa.
2. **Lähettäjä:** send-emails käsittelee lajin `newsletter` (haaran muutos + renderöijä). Main ei käsittele sitä nyt. Edge-deployn tekee Bottiavustus tai Koodari, ensin DEV.
3. **Oma kytkin:** esim. `booking.settings` key `newsletter_enabled` (oletus false). Sekä `admin_newsletter_dispatch` että `email_newsletter_payload` tarkistavat sen, samaan tapaan kuin `_customer_flag` 285:ssä. Ilman kytkintä lähetys on PRODissa teknisesti mahdollinen heti, kun joku kutsuu RPC:tä.
4. **Peruutuslistojen yhdistäminen:** `_newsletter_address_blocked` (ja siten `_newsletter_recipients` ja `email_newsletter_payload`) tarkistaa myös taulun `marketing_suppressions` (285), tai taulut yhdistetään yhdeksi. Molemmat tiivisteet ovat samaa muotoa, sha256(lower(btrim(email))) hex, joten yhdistäminen on suoraviivaista. Yhdistämisen tai anonymisoinnin suppressio ei saa ohittua uutiskirjeessä.
5. **Peruutuslinkki ja -sivu:** `newsletter-unsubscribe.html` julkaistaan. Lisäksi tarvitaan päätös, peruuttaako uutiskirjeen linkki vain uutiskirjeen vai kaiken markkinoinnin (nyt vain uutiskirjeen). Sähköpostiin lisätään List-Unsubscribe-otsake, jos Resend/Gmail sen sallii.
6. **Bottien luonnosreitti:** `svc_newsletter_save` on vain service_rolen käytössä. Bot-gatewayssa (`booking/supabase/functions/bot-gateway`) ei ole uutiskirjetoimintoa. Määrittele, miten bottien luonnokset tulevat järjestelmään.
7. **Sivutekstit** FI+EN uuteen tuontitiedostoon (ks. kohta 4) ja fallbackit `content/site-texts.fallback.json` -käytännön mukaan.
8. **Rollbackit mainiin** 259:lle ja 262:lle PROD-versioiden mukaisilla nimillä (`20261106223314_booking_259_ROLLBACK.sql`, `20261106223319_booking_262_ROLLBACK.sql`) ja uusille migraatioille.
9. **Testit mainiin** (JS + SQL) sekä tämän dokumentin kohdan 4 hyväksymistestit.
10. Tarkista, mitä `email_outbox_claim` palauttaa newsletter-riville (vastaanottaja `to` haetaan haaran mallissa vasta RPC:llä `email_newsletter_payload`). Tarkista myös, mitä mainin nykyinen send-emails tekee lajille `newsletter` (ei varmennettu).

## 4. Hyväksymiskriteerit

Jokainen kohta on testattava, ja testin tiedostopolku kirjataan PR:n kuvaukseen.

**Turvallisuus ja kytkimet**
- [ ] Uusi kytkin (esim. `newsletter_enabled`) on oletuksena false DEVissä ja PRODissa, eikä migraatio muuta sitä. Kun kytkin on false, `admin_newsletter_dispatch(confirm=true)` palauttaa virheen, eikä `email_outbox`-tauluun synny rivejä. SQL-testi todentaa tämän.
- [ ] Kun kytkin on false, `email_newsletter_payload` palauttaa `allowed:false`, jolloin jonossa jo olevatkaan rivit eivät lähde.
- [ ] Lähetys vaatii kirjautuneen henkilökunnan (`authenticated`) ja oikeuden `messages.edit`. Esikatselu (confirm=false) tehdään ennen lähetystä, ja esikatselun token vanhenee 30 minuutissa. Muokkaus, versionmuutos tai vastaanottajajoukon muutos mitätöi esikatselun. Nykyiset SQL-testit siirretään haarasta mainiin, ja niiden pitää mennä läpi.
- [ ] service_role tai botti ei voi lähettää (vain tallentaa luonnoksen).
- [ ] Vastaanottajia on enintään 5000 kampanjaa kohden. Sama osoite saa yhden viestin (dedupe), vaikka asiakkaalla olisi useita profiileja.

**GDPR ja opt-out**
- [ ] Vastaanottajiksi tulevat vain asiakkaat, joilla `marketing_consent=true`, `anonymized_at is null` ja kelvollinen sähköposti, ja jotka eivät ole kummassakaan suppressiotaulussa (`newsletter_suppressions` ja `marketing_suppressions`). SQL-testi: osoite vain taulussa `marketing_suppressions` → ei vastaanottaja eikä lähetystä.
- [ ] Suostumus tarkistetaan uudelleen juuri ennen jokaista lähetystä (`email_newsletter_payload`). Jos lupa perutaan jonotuksen ja lähetyksen välissä, viesti ohitetaan.
- [ ] Jokaisessa viestissä on toimiva peruutuslinkki. Peruutus ei vaadi kirjautumista, vastaa samalla tavalla tuntemattomaan tokeniin eikä paljasta osoitetta. Toistettu peruutus on idempotentti.
- [ ] Kun lupa perutaan (tilaussivun yleinen peruutus, asiakkaan muokkaus, Johku-synkka, yhdistäminen tai anonymisointi), osoite ei palaa listalle, vaikka profiili muuttuu tai poistuu. Testit kattavat jokaisen polun.
- [ ] Lokeihin (`newsletter_logs`, outbox-virheet, Edge-lokit) ei tallennu osoitteita eikä nimiä, vain tiivisteitä ja rivimääriä.
- [ ] Uudelleentilausta ei toteuteta tässä vaiheessa. Suppressioita ei poisteta millään toiminnolla.

**Ei asiakasviestejä testeissä**
- [ ] Kaikki testit ajetaan paikallisesti (node --test, paikallinen Postgres) synteettisellä datalla. DEVissä `resend.mode` on `off`. Mitään ei lähetetä oikeille osoitteille, eikä PRODin RPC:tä `admin_newsletter_dispatch` kutsuta.
- [ ] Ennen kuin kytkin avataan PRODissa: Joonas on antanut erillisen luvan, ja ensimmäinen lähetys tehdään vain testisegmentille tai allowlistille (`outboxAllowlistBlock`), jonka Joonas hyväksyy.

**Tekstit**
- [ ] Kaikki näkymän, peruutussivun ja sähköpostin tekstit ovat FI+EN uudessa tuontitiedostossa `content/site-texts.pending-import-<nro>.json`. Numerot 139–145 on käytetty (145 on #350:n haarassa), joten **seuraava vapaa on 146**. Tarkista vapaus mainista ja avoimista haaroista juuri ennen käyttöä. Haaran 131-tiedosto numeroidaan uudelleen eikä sitä käytetä sellaisenaan.
- [ ] Tekstien fallbackit ja tuontitiedosto täsmäävät (testi kuten haaran "pending-import FI/EN texts exactly match all fallbacks").
- [ ] Asiakkaalle näkyvä teksti on suomeksi ja englanniksi, ja asiakasviestit allekirjoitetaan "Tapio".

**Migraatiot**
- [ ] Jokainen tietokantamuutos on tiedostona `booking/supabase/migrations/<aikaleima>_booking_<nro>_<kuvaus>.sql`, ja sille on pari `booking/supabase/rollbacks/<sama aikaleima>_booking_<nro>_ROLLBACK.sql`. Numeron varaa Bottiavustus. Migraatioita ei ajeta itse, vaan Bottiavustus ajaa ne (DEV → PROD) ja Koodari nimeää tiedostot ajettujen versioiden mukaan.
- [ ] Migraatioissa on md5- tai SHA-ennakkotarkistus muutettaville funktioille (vrt. 262), eivätkä ne koske `public`-skeemaan.
- [ ] Rollback ei poista suppressio- tai token-dataa.

**Build ja julkaisu**
- [ ] `node --test booking/tests/*.test.mjs` menee läpi, ja `npm run build:prod` tuottaa uudet sivut versiotunnuksin (vrt. #350:n testi puuttuvista tiedostoista).
- [ ] CI on vihreä luonnos-PR:ssä. Koodari mergeää ja julkaisee.

## 5. Riskit ja avoimet kysymykset Joonakselle

**Riskit**
1. **Kytkimen puute PRODissa nyt:** Resend on `live`, ja `admin_newsletter_dispatch` on `authenticated`-roolin ajettavissa. Kuka tahansa, jolla on `messages.edit`, voisi teknisesti jonottaa jopa 5000 viestiä suoralla RPC-kutsulla. Mainin send-emails ei tunne lajia `newsletter`, joten todennäköisesti viestit epäonnistuvat eivätkä lähde, mutta tätä ei ole varmennettu. Kytkin pitäisi lisätä ensimmäisenä.
2. **Kaksi suppressiotaulua:** 285:n `marketing_suppressions` ei estä uutiskirjettä. Jos yhdistäminen tai anonymisointi otetaan käyttöön ennen yhdistämistä, peruttu osoite voi palata listalle. Triggeri kirjaa osan tapauksista myös tauluun `newsletter_suppressions` (lupa true→false), mutta ei kaikkia.
3. **Pysyvä peruutus voi estää oikean tilaajan** (Johku-synkan false→true-kierto). Tämä on tarkoituksellista, mutta siitä pitää kertoa.
4. **Vanha haara:** rebase-konfliktit tiedostoissa send-emails ja build-pages sekä hallinnan rakenteessa #318:n jälkeen.
5. **Rollbackien epäselvyys** (kohta 2). Feature rollback ei saa koskaan poistaa kaappausta.
6. Toimitettavuus: 1364 vastaanottajaa kerralla Resendin kautta. Lähetysnopeus, domainin maine ja List-Unsubscribe-otsake ovat selvittämättä.

**Avoimet kysymykset Joonakselle**
1. Peruuttaako uutiskirjeen linkki vain uutiskirjeen vai kaiken markkinoinnin? Entä yleinen peruutus: estääkö se uutiskirjeen (nyt estää)?
2. Onko uutiskirje oma sivu (`/hallinta/newsletters.html`) vai hallinnan valikon kohta?
3. Mitkä botit saavat tehdä luonnoksia, ja mitä reittiä (bot-gateway)?
4. Ovatko segmentit oikeat (all, training, treatment, event, session_only, gift_buyers, christmas_gift_buyers)? Tarvitaanko muita (esim. vuosikortti, kieli)?
5. Saako ensimmäisen lähetyksen tehdä testiryhmälle ennen koko listaa, ja keitä siihen kuuluu?
6. Tarvitaanko uudelleentilaus nyt, vai riittääkö se, että peruutus on pysyvä?

## 6. Työskentelysäännöt

- Noudata [CLAUDE.md](../../CLAUDE.md): olet tutkija. Tee työ omaan haaraan `claude/<aihe>` (esim. `claude/uutiskirje`) ja avaa korkeintaan luonnos-PR. Älä pushaa mainiin, älä mergeä äläkä julkaise.
- Ei kirjoituksia Supabaseen (ei DEV, ei PROD), ei migraatioiden ajoa, ei Edge-deployta eikä salaisuuksien muuttamista. Migraatiot ajaa Bottiavustus (DEV → PROD). Koodari mergeää, ajaa tekstituonnit ja julkaisee.
- Älä lähetä viestejä asiakkaille äläkä henkilökunnalle, äläkä kutsu lähetysfunktioita.
- Ei henkilötietoja eikä salaisuuksia raportteihin tai committeihin. Käytä synteettistä testidataa.
- Älä koske hyllytettyyn haaraan `feat/poista-maksamaton-264-main`.
- Raportoi tulokset tiedostoon `docs/claude/<päivämäärä>-uutiskirje.md` omassa haarassasi ja kerro Joonakselle suomeksi.
