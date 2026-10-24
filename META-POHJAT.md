# WhatsApp-pohjat Metalle (booking_153)

Kaikki pohjat: kieli fi, kategoria UTILITY, alatunniste "Tapio". JSON-muoto: `docs/whatsapp-templates.json` (booking_153_templates).
Pohja otetaan käyttöön vasta, kun Meta on hyväksynyt sen: `booking.settings` `shift_offer.wa_templates` → kyseisen pohjan `approved = true`.
Pohjan nimen voi vaihtaa samasta asetuksesta. Ennen hyväksyntää:

- tarjous ja muistutus lähtevät nykyisellä hyväksytyllä pohjalla `vuorotarjous` (fallback)
- muut (kierroksen muistutus, "jo mennyt", päivän kooste, ilmoitukset) lähtevät vapaamuotoisena vain, jos henkilön 24 h ikkuna on auki; muuten sähköpostina (jos `shift_offer.email_enabled`), tai niitä yritetään uudelleen 6 h välein. Rikkinäistä pohjalähetystä ei tehdä.
- WhatsApp lähtee vain klo 08–21 (Europe/Helsinki). Vastausaika lasketaan todellisesta lähetyshetkestä.

## 1. tyovuoro_kysely (ensisijainen tarjouspohja)

Runko:
> Hei! Vapaa {{1}} olisi tarjolla ajalla {{2}}. Kerro, otatko vuoron, viimeistään {{3}} mennessä painikkeesta.

Muuttujat: {{1}} vuoron nimi (esim. lämmitysvuoro), {{2}} aika (la 24.10.2026 klo 16:00–20:00), {{3}} vastausaika (22.10.2026 klo 12:00).
Painike (URL): "Avaa vastaus" → `https://sxbofnuisemspgquoxyv.supabase.co/functions/v1/shift-offer-engine?token={{1}}`

## 2. tyovuoro_muistutus (kierroksen päättymisen muistutus)

Runko:
> Muistutus: {{1}} ajalla {{2}} odottaa vielä vastaustasi. Vastausaika päättyy {{3}}, joten vastaathan sitä ennen.

Muuttujat kuten yllä. Painike (URL): "Avaa vastaus" → sama osoite kuin yllä.

## 3. tyovuoro_jo_mennyt (myöhäinen hyväksyjä)

Runko:
> Kiitos vastauksestasi. Tarjottu {{1}} ajalla {{2}} on jo saanut tekijän, joten sinun ei tarvitse tehdä mitään.

Muuttujat: {{1}} vuoron nimi, {{2}} aika. Ei painiketta. Oletuksena pois (`shift_offer.already_taken_message` = false).

## 4. tyovuoro_paivan_kooste (saman päivän viestit yhdessä)

Runko:
> Hei! Sinulle on useampi vuoroasia päivälle {{1}}: {{2}}. Näet ne kaikki ja voit vastata omalla sivullasi.

Muuttujat: {{1}} päivä (27.11.2026), {{2}} lista (lämmitysvuoro klo 10:00–14:00 (vastaa 28.10. klo 12:00); lämmitysvuoro klo 16:00–20:00 (vastaa 28.10. klo 12:00)).
Painike (URL): "Avaa oma sivu" → `https://joonasvaarala.github.io/saunotus-uusi/vuoro/oma/?token={{1}}`

## Tervetuloviesti (ei pohja)

Vapaamuotoinen viesti 24 h ikkunassa henkilön ensimmäiseen WhatsApp-viestiin. Teksti: `shift_offer.whatsapp.welcome` (site_texts), asetus `shift_offer.welcome_enabled` oletus pois.
