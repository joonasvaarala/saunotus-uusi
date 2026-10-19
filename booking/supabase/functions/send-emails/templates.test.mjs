// node --test booking/supabase/functions/send-emails/templates.test.mjs
// templates.ts on pelkkää TypeScript-tyyppisyntaksia (ei riippuvuuksia) → ladataan suoraan Node 22.18+ :n tyyppien poistolla.
// Vanhemmalla Nodella (20) testit ohitetaan (CI ajaa ne Node 22:lla, ks. .github/workflows/pages.yml).
import test from 'node:test';
import assert from 'node:assert/strict';

let T = null;
try { T = await import('./templates.ts'); } catch (e) { if (!/ERR_UNKNOWN_FILE_EXTENSION|Unknown file extension/.test(String(e?.code || e))) throw e; }
const R = (...a) => { const m = T.render(...a); return Object.fromEntries(Object.entries(m).map(([k, v]) => [k, v.replaceAll('\u00a0', ' ')])); };   // NBSP → väli vertailua varten
const skip = T ? false : 'Node ei tue .ts-tuontia (tarvitaan Node >= 22.18)';

const SITE = 'https://uusi.saunotus.com';
const ORDER_URL = `${SITE}/tilaus/?t=3f2b8c1e-7a4d-4e9b-9c55-1d2e3f4a5b6c`;
const PAY_URL = `${SITE}/maksa/?p=9d8c7b6a-1111-4222-8333-444455556666`;
const base = (locale) => ({
  id: 1, locale, to: 'asiakas@example.com', to_name: 'Matti Meikäläinen',
  order: {
    order_no: 15321, order_url: ORDER_URL, total: 134, status: 'confirmed',
    items: [{ name: 'Yleinen vuoro', quantity: 2, line_total: 36, vat_rate: 25.5, kind: 'product' }, { name: 'Pyyhe', quantity: 2, line_total: 6, vat_rate: 25.5, kind: 'addon' }, { name: 'Hieronta 60 min', quantity: 1, line_total: 92, vat_rate: 25.5, kind: 'product' }],
    reservations: [{ product_name: 'Yleinen vuoro', starts_at: '2026-11-07T15:00:00Z', ends_at: '2026-11-07T17:00:00Z', persons: 2, status: 'confirmed' }, { product_name: 'Peruttu', starts_at: '2026-11-08T15:00:00Z', ends_at: '2026-11-08T17:00:00Z', persons: 1, status: 'cancelled' }],
  },
  receipt: { id: 5, receipt_no: '2026-000123', kind: 'receipt', text_body: 'KUITTI 2026-000123\nYleinen vuoro 2 × 18,00 €\nYhteensä 134,00 €', public_token: 'abc', total: 134, issued_at: '2026-11-07T09:30:00Z' },
  payment: { id: 9, amount: 98.5, link_url: PAY_URL, link_expires_at: '2026-11-14T20:00:00Z' },
});
const KINDS = ['order_confirmation', 'payment_link', 'receipt', 'refund_receipt', 'cancel_request_ack', 'order_change'];
const refundData = (locale) => { const d = base(locale); d.receipt = { ...d.receipt, kind: 'refund_receipt', receipt_no: '2026-000124', total: -10, text_body: 'HYVITYSKUITTI 2026-000124\nHyvitys -10,00 €' }; return d; };
const data = (kind, locale) => (kind === 'refund_receipt' ? refundData(locale) : base(locale));
const hrefs = (html) => [...html.matchAll(/href="([^"]*)"/g)].map((m) => m[1]);
const hexes = (html) => [...new Set([...html.matchAll(/#([0-9a-f]{6})\b/gi)].map((m) => m[1].toLowerCase()))];

for (const locale of ['fi', 'en']) for (const kind of KINDS) {
  test(`${kind} ${locale}: aihe, teksti ja HTML täytetty, ei tyhjiä kenttiä`, { skip }, () => {
    const m = R(kind, data(kind, locale), locale);
    for (const f of ['subject', 'text', 'html']) assert.ok(m[f] && m[f].trim().length > 20, `${f} tyhjä`);
    for (const f of ['subject', 'text', 'html']) assert.ok(!/undefined|\bnull\b|NaN|\[object/.test(m[f]), `${f} sisältää tyhjän arvon: ${m[f].match(/.{20}(undefined|null|NaN|\[object).{10}/)?.[0]}`);
    assert.ok(!/[<>]/.test(m.subject) && !/\n/.test(m.subject));
    assert.ok(/15321|2026-00012[34]/.test(m.subject), 'aihe sisältää tilaus-/kuittinumeron');
    assert.ok(!/<[a-z!]/i.test(m.text), 'tekstiversiossa ei HTML:ää');
    assert.ok(m.text.includes('Matti') && m.html.includes('Matti') && !m.text.includes('Meikäläinen'), 'etunimi tervehdyksessä');
    assert.ok(m.text.endsWith('\n'));
  });
  test(`${kind} ${locale}: kieli, linkit, logo ja tyyli`, { skip }, () => {
    const m = R(kind, data(kind, locale), locale), en = locale === 'en';
    assert.ok(m.html.startsWith('<!doctype html><html lang="' + locale + '">'));
    assert.ok(en ? /Hello Matti,/.test(m.text) && /Kind regards,/.test(m.text) : /Hei Matti,/.test(m.text) && /Ystävällisin terveisin,/.test(m.text), 'tervehdys/allekirjoitus kielellä');
    assert.ok(en ? !/Ystävällisin|Kiitos|Tilaus\b/.test(m.text) : !/Kind regards|Thank you|\bOrder\b/.test(m.text), 'ei sekakieltä');
    if (kind === 'payment_link') {
      assert.ok(m.text.includes('Tapio') && m.text.includes('Sipoonjoen Perinnesauna') && !m.text.includes('Havuhattu Oy'), 'maksulinkki allekirjoitetaan Tapiolla');
      assert.ok(m.html.includes('Tapio') && m.html.includes('Havuhattu Oy') && m.html.includes('Sipoonjoen Perinnesauna') && m.html.includes('Hindsbyntie 124'));
    } else {
      assert.ok(!m.text.includes('Tapio'), `${kind}: Tapio vain maksulinkissä`);
      assert.ok(m.text.includes('Havuhattu Oy') && m.html.includes('Havuhattu Oy') && m.html.includes('Sipoonjoen Perinnesauna') && m.html.includes('Hindsbyntie 124'));
    }
    // linkit
    const links = hrefs(m.html);
    assert.ok(links.every((h) => /^(https:\/\/[^\s"]+|mailto:[^\s"]+|tel:\+?\d+)$/.test(h)), `virheellinen linkki: ${links}`);
    assert.ok(links.includes('mailto:savusauna@saunotus.fi'));
    const main = kind === 'payment_link' ? PAY_URL : ORDER_URL;
    assert.ok(links.includes(main), `pääpainike ${main}`); assert.ok(m.text.includes(main), 'linkki myös tekstiversiossa');
    // logo johdetaan tilauslinkin sivustosta
    assert.ok(m.html.includes(`<img src="${SITE}/img/logo-kuitti.png"`), 'logo sivuston osoitteesta');
    assert.ok(/<img [^>]*alt="Havuhattu Oy"/.test(m.html));
    // taulukkopohjainen, ei sinistä
    assert.ok(/<table role="presentation"/.test(m.html) && !/<(div|ul|p|h1)\b/.test(m.html.replace(/<div style="display:none[^>]*>[^<]*<\/div>/, '')), 'taulukkopohja (ei div/ul/p/h1-asettelua)');
    for (const h of hexes(m.html)) { const [r, g, b] = [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16)); assert.ok(!(b > r + 24 && b > g + 24), `sinertävä väri #${h}`); }
    assert.ok(m.html.includes('#1f3d2b') && m.html.includes('#efe7d6'), 'tumma vihreä + hiekka');
  });
}

test('tilausvahvistus: varaukset, rivit ja summa; peruttu varaus pois', { skip }, () => {
  const fi = R('order_confirmation', base('fi'));
  assert.equal(fi.subject, 'Tilausvahvistus 15321 – Sipoonjoen Perinnesauna');
  assert.ok(fi.text.includes('Yleinen vuoro: ') && fi.text.includes('2 hlö') && !fi.text.includes('Peruttu'));
  assert.ok(fi.text.includes('2 × Yleinen vuoro 36,00 €') && fi.text.includes('Yhteensä: 134,00 €'));
  assert.ok(fi.html.includes('134,00') && !fi.html.includes('Peruttu'));
  const en = R('order_confirmation', base('en'));
  assert.equal(en.subject, 'Order confirmation 15321 – Sipoonjoen Perinnesauna');
  assert.ok(en.text.includes('Total: 134.00 €') && en.text.includes('2 guests') && en.text.includes('Booking') );
  // aika Helsingin ajassa (15:00Z = 17:00 EET marraskuussa)
  assert.ok(fi.text.includes('17.00–19.00') || fi.text.includes('17:00–19:00'), fi.text);
});

test('maksulinkki: summa, linkki ja voimassaolo', { skip }, () => {
  const fi = R('payment_link', base('fi'));
  assert.equal(fi.subject, 'Maksulinkki tilaukseen 15321 – Sipoonjoen Perinnesauna');
  assert.ok(fi.text.includes('98,50 €') && fi.text.includes(PAY_URL) && /voimassa 14\.11\.2026 asti/.test(fi.text));
  assert.ok(fi.text.includes('Tapio') && fi.text.includes('Sipoonjoen Perinnesauna') && !fi.text.includes('Havuhattu Oy'));
  assert.ok(!R('order_confirmation', base('fi')).text.includes('Tapio'));
  const en = R('payment_link', base('en'));
  assert.ok(en.text.includes('98.50 €') && /valid until 14\/11\/2026/.test(en.text) && en.html.includes('Pay now'));
  const d = base('fi'); d.payment.link_url = null; const nolink = R('payment_link', d);
  assert.ok(nolink.text.includes(ORDER_URL), 'varalinkki tilaussivulle');
});

test('kuitti ja hyvityskuitti: PDF-maininta, kuittirunko, hyvitetty summa positiivisena', { skip }, () => {
  const r = R('receipt', base('fi'));
  assert.equal(r.subject, 'Kuitti 2026-000123 – Sipoonjoen Perinnesauna');
  assert.ok(r.text.includes('liitteenä PDF') && r.text.includes('KUITTI 2026-000123') && r.text.includes('Maksettu: 134,00 €') && r.text.includes('Kuittinumero: 2026-000123'));
  assert.ok(r.html.includes('white-space:pre-wrap') && r.html.includes('KUITTI 2026-000123'));
  const h = R('refund_receipt', refundData('fi'));
  assert.equal(h.subject, 'Hyvityskuitti 2026-000124 – Sipoonjoen Perinnesauna');
  assert.ok(h.text.includes('hyvitys (10,00 €)') && h.text.includes('Hyvitetty: 10,00 €'));
  const he = R('refund_receipt', refundData('en'));
  assert.equal(he.subject, 'Refund receipt 2026-000124 – Sipoonjoen Perinnesauna');
  assert.ok(he.text.includes('A refund of 10.00 €') && he.text.includes('Refunded: 10.00 €'));
});

test('HTML-escape ja vaaralliset linkit', { skip }, () => {
  const d = base('fi'); d.to_name = '<script>alert(1)</script> X'; d.order.items[0].name = 'A & B "<b>"'; d.order.order_url = 'javascript:alert(1)'; d.payment.link_url = 'https://x.example/"onmouseover="a';
  for (const k of KINDS) { const m = R(k, d); assert.ok(!/<script/i.test(m.html) && !/javascript:/i.test(m.html) && !/onmouseover=/.test(m.html), k); }
  const m = R('order_confirmation', d); assert.ok(m.html.includes('A &amp; B &quot;&lt;b&gt;&quot;'));
});

test('puuttuvat tiedot eivät kaada eikä jätä tyhjää: ei tilausta, ei nimeä, ei tilauslinkkiä', { skip }, () => {
  for (const k of KINDS) for (const loc of ['fi', 'en']) {
    const m = R(k, { locale: loc }, loc);
    assert.ok(m.subject && m.text && m.html, k);
    assert.ok(m.html.includes(`${loc === 'en' ? 'Hello,' : 'Hei,'}`));
    assert.ok(m.html.includes(`src="${T.LOGO_FALLBACK}"`), 'oletuslogo');
  }
  assert.equal(T.LOGO_FALLBACK, 'https://joonasvaarala.github.io/saunotus-uusi/img/logo-kuitti.png');
});

test('siteBase / logoUrl: alipolku ja tuotanto', { skip }, () => {
  assert.equal(T.siteBase({ order: { order_url: 'https://joonasvaarala.github.io/saunotus-uusi/tilaus/?t=x' } }), 'https://joonasvaarala.github.io/saunotus-uusi');
  assert.equal(T.logoUrl({ payment: { link_url: 'https://uusi.saunotus.com/maksa/?p=1' } }), 'https://uusi.saunotus.com/img/logo-kuitti.png');
  assert.equal(T.logoUrl({}), T.LOGO_FALLBACK);
});

test('locale-valinta: parametri voittaa datan, oletus fi', { skip }, () => {
  assert.ok(R('order_change', { ...base('fi'), locale: 'fi' }, 'en').subject.startsWith('Your order has changed'));
  assert.ok(R('order_change', base('en')).subject.startsWith('Your order has changed'));
  assert.ok(R('order_change', { ...base('fi'), locale: undefined }).subject.startsWith('Tilauksesi on muuttunut'));
});

// ---------- lahjakortit (booking_45, sopimus §13.9): gift_card_buyer / gift_card_recipient ----------
const GTOK = '0654361d-a2b1-43f4-a25c-8c7223907dd0';
const gcard = (o = {}) => ({ public_token: GTOK, package_code: 'sauna_treatment_2', package_name: 'Savusaunaelämys ja saunahoito kahdelle', package_name_en: 'Smoke sauna experience and sauna treatment for two', kind: 'product', amount: 192, valid_to: '2027-04-01', recipient_name: 'Mikko Mallikas', greeting: 'Hyvää syntymäpäivää!\nNauti <3 & rentoudu', cover_message: 'Hei <3 & tervetuloa\nToinen rivi', buyer_name: 'Olli Ostaja', persons: 2, locale: 'fi', status: 'active', ...o });
const gbase = { functions_url: 'https://x.supabase.co/functions/v1', redeem_online: false, to_name: 'Olli Ostaja' };
for (const locale of ['fi', 'en']) for (const kind of ['gift_card_buyer', 'gift_card_recipient']) {
  test(`${kind} ${locale}: PDF-linkki lang-parametrilla, ei koodia, ei tyhjiä arvoja, HTML escapattu`, { skip }, () => {
    const m = R(kind, { ...gbase, gift_cards: [gcard({ locale }), gcard({ package_code: 'open', kind: 'value', amount: 50.5, locale })] }, locale);
    for (const f of ['subject', 'text', 'html']) assert.ok(m[f] && m[f].trim().length > 20, `${f} tyhjä`);
    for (const f of ['subject', 'text', 'html']) assert.ok(!/undefined|\bnull\b|NaN|\[object/.test(m[f]), `${f} sisältää tyhjän arvon`);
    assert.ok(!/\n/.test(m.subject) && !/<[a-z!]/i.test(m.text));
    const pdfs = hrefs(m.html).filter((u) => u.includes('/gift-card-pdf?'));
    assert.ok(pdfs.length >= 2 && pdfs.every((u) => u === `https://x.supabase.co/functions/v1/gift-card-pdf?t=${GTOK}&amp;lang=${locale}` || u === `https://x.supabase.co/functions/v1/gift-card-pdf?t=${GTOK}&lang=${locale}`), `PDF-linkit: ${pdfs}`);
    assert.ok(m.text.includes(`gift-card-pdf?t=${GTOK}&lang=${locale}`));
    assert.ok(!/HH[0-9A-Z]{2}-/.test(m.text + m.html), 'viesti ei sisällä kortin koodia');
    if (kind === 'gift_card_recipient') assert.ok(!m.html.includes('<3') && m.html.includes('&lt;3') && m.html.includes('&amp;') && m.html.includes('Toinen rivi') && !m.html.includes('Hyvää syntymäpäivää'), 'saateteksti escapataan; kortin tervehdys ei ole sähköpostissa');
    assert.ok(m.text.endsWith('\n'));
  });
}
test('gift_card_buyer: EN-viestissä englanninkielinen paketin nimi, FI:ssä suomenkielinen', { skip }, () => {
  assert.ok(R('gift_card_buyer', { ...gbase, gift_cards: [gcard({ locale: 'en' })] }, 'en').text.includes('Smoke sauna experience'));
  assert.ok(R('gift_card_buyer', { ...gbase, gift_cards: [gcard()] }, 'fi').text.includes('Savusaunaelämys'));
});
test('gift_card_*: redeem_online ohjaa käyttöohjeen tekstin', { skip }, () => {
  const off = R('gift_card_recipient', { ...gbase, gift_cards: [gcard()] }, 'fi').text;
  const on = R('gift_card_recipient', { ...gbase, redeem_online: true, gift_cards: [gcard()] }, 'fi').text;
  assert.notEqual(on, off);
  assert.ok(/verkossa|verkkosivu|saunotus\.fi/i.test(on));
});

// ---------- toimitusvalinta (booking_46, sopimus §13.11) ----------
const rcard = (o = {}) => gcard({ delivery_to: 'recipient', recipient_email: 'saaja@example.com', recipient_name: 'Sanna Saaja', ...o });
for (const locale of ['fi', 'en']) {
  test(`gift_card_buyer ${locale}: delivery_to=recipient → ei PDF-linkkiä ostajan viestissä, kerrotaan saajalle lähetyksestä`, { skip }, () => {
    const m = R('gift_card_buyer', { ...gbase, gift_cards: [rcard({ locale })] }, locale);
    assert.ok(!m.text.includes('gift-card-pdf') && !hrefs(m.html).some((u) => u.includes('gift-card-pdf')), 'ei PDF-linkkiä');
    assert.ok(m.text.includes('saaja@example.com') && m.text.includes('Sanna Saaja'));
    assert.ok(!/undefined|\bnull\b|NaN/.test(m.text + m.html));
  });
  test(`gift_card_buyer ${locale}: ajastettu toimitus näyttää päivän ja kellonajan`, { skip }, () => {
    const m = R('gift_card_buyer', { ...gbase, gift_cards: [rcard({ locale, deliver_on: '2026-12-24', deliver_time: '18:30', deliver_at: '2026-12-24T16:30:00Z' })] }, locale);
    assert.ok(m.text.includes(locale === 'fi' ? '24.12.2026' : '24 Dec 2026') && /18[.:]30/.test(m.text), m.text);
    assert.ok(!m.text.includes('gift-card-pdf'));
  });
  test(`gift_card_buyer ${locale}: sekatilaus (buyer + recipient) → PDF vain ostajalle toimitettavalle`, { skip }, () => {
    const m = R('gift_card_buyer', { ...gbase, gift_cards: [gcard({ locale }), rcard({ locale, public_token: '11111111-2222-4333-8444-555555555555' })] }, locale);
    assert.ok(m.text.includes(GTOK) && !m.text.includes('11111111-2222-4333-8444-555555555555'));
  });
}
test('gift_card_recipient: saateteksti näkyy, kortin tervehdys ei; ostajan nimi mukana; PDF-linkki', { skip }, () => {
  const m = R('gift_card_recipient', { ...gbase, to_name: 'Sanna Saaja', gift_cards: [rcard()] }, 'fi');
  assert.ok(m.text.includes('Toinen rivi') && !m.text.includes('Hyvää syntymäpäivää') && m.text.includes('Olli Ostaja') && m.text.includes(`gift-card-pdf?t=${GTOK}`));
});

// ---------- kumppanilahjakorttien lunastuspyynnöt (voucher_claim_received / voucher_claim_problem) ----------
const vcData = (locale, vc = {}) => ({ ...base(locale), voucher_claim: { claim_id: 7, status: 'received', source: 'elamyslahjat', code_masked: '…1234', problem_code: 'invalid_code', customer_name: 'Matti Meikäläinen', ...vc } });
for (const locale of ['fi', 'en']) {
  test(`voucher_claim_received ${locale}: koodi maskattuna, tilauslinkki, ei puhelinnumeroa eikä aikarajaa`, { skip }, () => {
    const m = R('voucher_claim_received', vcData(locale), locale);
    assert.ok(m.subject.includes('Sipoonjoen Perinnesauna') && !/undefined|\bnull\b|NaN/.test(m.subject + m.text + m.html));
    assert.ok(m.text.includes('Elämyslahjat') && m.text.includes('…1234') && m.text.includes(ORDER_URL) && hrefs(m.html).includes(ORDER_URL));
    assert.ok(!/tel:/.test(m.html) && !m.html.includes('+358') && hrefs(m.html).includes('mailto:savusauna@saunotus.fi'), 'ei puhelinnumeroa');
    assert.ok(!/\basti\b|\buntil\b|\bhold\b|pidetty/i.test(m.text), 'ei aikarajaa');
    assert.ok(m.text.includes('Tapio') && m.text.endsWith('\n'));
  });
  for (const pc of ['invalid_code', 'expired_code', 'already_used', 'other']) test(`voucher_claim_problem ${locale} ${pc}: oma aihe ja teksti, ei puhelinnumeroa`, { skip }, () => {
    const m = R('voucher_claim_problem', vcData(locale, { status: 'problem', problem_code: pc }), locale);
    assert.ok(m.text.includes('…1234') && m.text.includes(ORDER_URL) && !/undefined|\bnull\b|NaN/.test(m.subject + m.text + m.html));
    assert.ok(!/tel:/.test(m.html) && !/[<>\n]/.test(m.subject) && !/<[a-z!]/i.test(m.text));
    assert.ok(!m.text.includes(locale === 'fi' ? 'Kind regards' : 'Ystävällisin'), 'ei sekakieltä');
  });
}
test('voucher_claim_problem: eri ongelmakoodeilla eri aiheet; tuntematon kumppani/koodi ei kaada', { skip }, () => {
  const subj = ['invalid_code', 'expired_code', 'already_used', 'other'].map((pc) => R('voucher_claim_problem', vcData('fi', { problem_code: pc }), 'fi').subject);
  assert.equal(new Set(subj).size, 4);
  const m = R('voucher_claim_received', vcData('fi', { source: 'tuntematon', code_masked: '' }), 'fi');
  assert.ok(m.text.includes('kumppani') && !/koodi\s*[,)]/.test(m.text) && !/undefined|\bnull\b/.test(m.text));
});
test('muiden pohjien alatunniste sisältää edelleen puhelinnumeron (noPhone vain voucher_claim-viesteissä)', { skip }, () => {
  assert.ok(hrefs(R('order_confirmation', base('fi'), 'fi').html).some((h) => h.startsWith('tel:')));
});
test('puhelin: näkyvä muoto kielen mukaan (fi 010 299 2866, en +358 10 299 2866), linkki tel:+358102992866 (sama vakio kuin sivusto/kauppa, booking/shop/src/phone.js)', { skip }, async () => {
  const P = await import('../../../shop/src/phone.js');
  assert.equal(T.PHONE_FI, P.PHONE_DISPLAY_FI); assert.equal(T.PHONE_EN, P.PHONE_DISPLAY_EN); assert.equal(T.PHONE_TEL, P.PHONE_TEL);
  assert.equal(T.phoneFor(false), P.phoneDisplay('fi')); assert.equal(T.phoneFor(true), P.phoneDisplay('en'));
  assert.equal(P.PHONE_DISPLAY_FI, '010 299 2866'); assert.equal(P.PHONE_DISPLAY_EN, '+358 10 299 2866'); assert.equal(P.PHONE_TEL, '+358102992866'); assert.equal(P.phoneHref(), 'tel:+358102992866');
  for (const [locale, shown, other] of [['fi', '010 299 2866', '+358 10 299 2866'], ['en', '+358 10 299 2866', '010 299 2866']]) {
    const m = R('order_confirmation', base(locale), locale);
    assert.ok(hrefs(m.html).includes('tel:+358102992866') && !m.html.includes('tel:0102992866'), `${locale}: tel-linkki`);
    assert.ok(m.html.includes(`>${shown}</a>`), `${locale}: alatunnisteen näkyvä muoto`);
    assert.ok(m.text.includes(shown), `${locale}: tekstiversio ({{var:phone}}) "${shown}"`);
    assert.ok(!(m.html + m.text).includes(other), `${locale}: ei toisen kielen muotoa "${other}"`);
  }
});

// booking_50: varauksen tuotevalinta näkyy tilauslohkossa ("Saunahoito – Hunajahoito" / EN "Saunahoito – Honey treatment"); ilman valintaa viesti on ennallaan
for (const locale of ['fi', 'en']) {
  test(`order_confirmation ${locale}: varauksen tuotevalinta näkyy tekstissä ja HTML:ssä`, { skip }, () => {
    const d = base(locale);
    d.order.reservations = [{ product_name: 'Saunahoito', starts_at: '2026-11-07T15:00:00Z', ends_at: '2026-11-07T16:00:00Z', persons: 1, status: 'confirmed', option: { code: 'hunajahoito', name: 'Hunajahoito', name_en: 'Honey treatment' } }];
    const m = R('order_confirmation', d, locale);
    const want = locale === 'en' ? 'Saunahoito – Honey treatment' : 'Saunahoito – Hunajahoito';
    assert.ok(m.text.includes(want), `teksti: ${want}`);
    assert.ok(m.html.includes(want), `html: ${want}`);
    const plain = base(locale); plain.order.reservations = [{ ...d.order.reservations[0], option: null }];
    const m2 = R('order_confirmation', plain, locale);
    assert.ok(!m2.text.includes('Saunahoito –') && !m2.html.includes('Saunahoito –'), 'ilman valintaa ei ylimääräistä viivaa');
  });
}

for (const locale of ['fi', 'en']) {
  test(`business_quote_ack ${locale}: Tapio, ei hintaa eikä vahvistettua ajankohtaa`, { skip }, () => {
    const m = R('business_quote_ack', { to_name: 'Maija Meikäläinen', locale }, locale);
    const en = locale === 'en';
    assert.equal(m.subject, en ? 'Quote request received – Sipoonjoen Perinnesauna' : 'Tarjouspyyntö vastaanotettu – Sipoonjoen Perinnesauna');
    assert.ok(m.text.includes('Tapio') && m.text.includes('Sipoonjoen Perinnesauna') && m.html.includes('Tapio'));
    assert.ok(m.text.includes(en ? 'This message does not confirm a time or a price.' : 'Tämä viesti ei vahvista ajankohtaa eikä hintaa.'));
    assert.ok(!/€/.test(m.subject + m.text + m.html));
    assert.ok(m.text.includes('Maija') && !m.text.includes('Meikäläinen'));
    assert.ok(en ? /Kind regards,/.test(m.text) && !/Ystävällisin|Kiitos tarjouspyynnöstä/.test(m.text) : /Ystävällisin terveisin,/.test(m.text) && !/Kind regards|Thank you/.test(m.text));
    assert.ok(m.html.includes(en ? '+358 10 299 2866' : '010 299 2866') && hrefs(m.html).includes('tel:+358102992866'));
    assert.ok(!m.html.includes(en ? '010 299 2866' : '+358 10 299 2866'));
  });
  test(`business_quote_notify ${locale}: kaikki lomakkeen kentät, aina suomeksi`, { skip }, () => {
    const quote = {
      id: 42, company_name: 'Sipoon Testi Oy', contact_name: 'Maija Meikäläinen', email: 'maija@example.test',
      phone: '040 123 4567', persons: 12, offerings: ['vihta_workshop', 'ritual', 'other', 'sauna', 'forest_yoga', 'campfire_meal'],
      offering_other: 'yrityssaunaretki', preferred_when: 'ensi viikon perjantai', message: 'toive metsäkävelystä',
      locale: 'en', created_at: '2026-10-18T19:14:00.000Z',
    };
    const m = R('business_quote_notify', { to_name: 'Joonas', locale, reply_to: quote.email, quote }, locale);
    const norm = (s) => s.replaceAll('\u00a0', ' ').replaceAll('\u202f', ' ');
    const text = norm(m.text), html = norm(m.html);
    const sent = norm(new Intl.DateTimeFormat('fi-FI', { timeZone: 'Europe/Helsinki', weekday: 'short', day: 'numeric', month: 'numeric', year: 'numeric', hour: '2-digit', minute: '2-digit' }).format(new Date(quote.created_at)));
    assert.equal(m.subject, 'Yritysten tarjouspyyntö: Sipoon Testi Oy, 12 hlö, ensi viikon perjantai');
    const lines = [
      'Yrityksen nimi: Sipoon Testi Oy',
      'Yhteyshenkilö: Maija Meikäläinen',
      'Sähköposti: maija@example.test',
      'Puhelin: 040 123 4567',
      'Henkilömäärä: 12 hlö',
      'Valitut palvelut: Saunarituaali, Metsäjooga, Nuotioruokailu, Saunotus, Vihtatyöpaja, Muu: yrityssaunaretki',
      'Toivottu ajankohta: ensi viikon perjantai',
      'Lisätiedot: toive metsäkävelystä',
      'Kieli: englanti',
      `Lähetysaika: ${sent}`,
      'Pyynnön tunnus: 42',
    ];
    for (const line of lines) {
      assert.ok(text.includes(line), `${locale} teksti: ${line}`);
      const cut = line.indexOf(': ');
      assert.ok(html.includes(line.slice(0, cut)) && html.includes(line.slice(cut + 2)), `${locale} html: ${line}`);
    }
    assert.ok(text.includes('Hei Joonas,') && text.includes('Tapio') && text.includes('Sipoonjoen Perinnesauna'));
    assert.ok(!/hallinnan Yritykset|Companies view|Company quote request|Selected services|Hello Joonas/.test(m.subject + text));
    assert.ok(!/€/.test(m.subject + text + html));
    assert.equal(T.outboundReplyTo('business_quote_notify', { reply_to: quote.email, quote }, 'savusauna@saunotus.fi'), 'maija@example.test');
  });
}
test('business_quote_notify: lisätietojen rivinvaihto säilyy HTML:ssä, aihe tiivistää tyhjän', { skip }, () => {
  const quote = {
    id: 7, company_name: 'Sipoon\nTesti   Oy', contact_name: 'Maija', email: 'maija@example.test', phone: '0401234567',
    persons: 12, offerings: ['sauna'], preferred_when: 'ensi viikon perjantai', message: 'rivi yksi\nrivi <kaksi> & "kolme"', locale: 'fi',
    created_at: '2026-10-18T19:14:00.000Z',
  };
  const m = R('business_quote_notify', { to_name: 'Joonas', quote }, 'fi');
  assert.equal(m.subject, 'Yritysten tarjouspyyntö: Sipoon Testi Oy, 12 hlö, ensi viikon perjantai');
  assert.ok(!/[\r\n]/.test(m.subject) && !/ {2}/.test(m.subject));
  assert.ok(m.text.includes('Lisätiedot: rivi yksi\nrivi <kaksi> & "kolme"') && !m.text.includes('<br>'));
  assert.ok(m.text.includes('Yrityksen nimi: Sipoon\nTesti   Oy'));
  assert.ok(m.html.includes('Sipoon<br>Testi   Oy'));
  assert.ok(m.html.includes('rivi yksi<br>rivi &lt;kaksi&gt; &amp; &quot;kolme&quot;'));
  assert.ok(!m.html.includes('<kaksi>') && !m.html.includes('rivi yksi\n'));
});
test('business_quote_notify: reply-to on asiakas, muut lajit pitävät yhteisen asetuksen', { skip }, () => {
  assert.equal(T.outboundReplyTo('business_quote_notify', { quote: { email: 'maija@example.test' } }, 'savusauna@saunotus.fi'), 'maija@example.test');
  assert.equal(T.outboundReplyTo('business_quote_notify', { reply_to: 'ei-osoite', quote: { email: 'maija@example.test' } }, 'savusauna@saunotus.fi'), 'maija@example.test');
  assert.equal(T.outboundReplyTo('business_quote_notify', { reply_to: 'ei-osoite' }, 'savusauna@saunotus.fi'), 'savusauna@saunotus.fi');
  assert.equal(T.outboundReplyTo('business_quote_ack', { reply_to: 'maija@example.test' }, 'savusauna@saunotus.fi'), 'savusauna@saunotus.fi');
  assert.equal(T.outboundReplyTo('order_confirmation', {}, 'savusauna@saunotus.fi'), 'savusauna@saunotus.fi');
  assert.equal(T.outboundReplyTo('order_confirmation', {}, ''), undefined);
});
