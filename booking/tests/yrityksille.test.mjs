// Yrityksille: yritysvuorot pois kuluttajan kalenterista, sivu FI+EN, tarjouspyynnön validointi.
// Ei verkkoa eikä tietokantaa. RLS-testit ovat booking/supabase/tests/companies/ (Bottiavustus ajaa psql:llä).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';

const root = resolve(new URL('../..', import.meta.url).pathname);
const rd = (p) => readFileSync(join(root, p), 'utf8');
const J = (p) => JSON.parse(rd(p));
const imp = (p) => import(pathToFileURL(join(root, p)));

const { pickCatalog, productAudience } = await imp('booking/shop/src/catalog-audience.js');
const { validateQuote, OFFERINGS } = await imp('public/js/companies-form-logic.mjs');
const { companies } = await imp('src/render.mjs');
const { pageHref } = await imp('src/lib.mjs');
const { classForContent } = await imp('src/content-texts.mjs');
const { createAdminMock } = await imp('booking/admin/options-mock.js');

const okInput = (over = {}) => ({
  company_name: 'Sipoon Testi Oy', contact_name: 'Maija Meikäläinen', email: 'Maija@Example.Test', phone: '040 123 4567',
  preferred_when: 'ensi viikon perjantai', persons: '12', offerings: ['sauna', 'ritual'], message: 'toive', privacy: true, locale: 'fi', ...over,
});

test('kalenteri: audience voittaa kategorian; puuttuva audience + corporate → yritysvuoro', () => {
  const rows = [
    { slug: 'saunavuoro-yrityksille', category: 'corporate' },
    { slug: 'jalkiloylyt-yrityksille', audience: 'business', category: 'corporate' },
    { slug: 'oma-savusaunavuoro', audience: 'consumer', category: 'corporate' },
    { slug: 'yleinen', category: 'public_sauna' },
    { slug: 'yrityspaivat', category: 'corporate' },
  ];
  assert.equal(productAudience(rows[0]), 'business');
  assert.equal(productAudience(rows[2]), 'consumer');
  assert.deepEqual(pickCatalog(rows, 'consumer').map((r) => r.slug), ['oma-savusaunavuoro', 'yleinen']);
  assert.deepEqual(pickCatalog(rows, 'business').map((r) => r.slug), ['saunavuoro-yrityksille', 'jalkiloylyt-yrityksille', 'yrityspaivat']);
  assert.deepEqual(pickCatalog(rows, 'vip').map((r) => r.slug), pickCatalog(rows, 'consumer').map((r) => r.slug));
  assert.deepEqual(pickCatalog(null, 'business'), []);
});

test('kauppa pyytää public_catalog_for ja yrityskalenteri ei näytä hoitoja', () => {
  const s = rd('booking/shop/src/shop.js');
  assert.match(s, /public_catalog_for/);
  assert.match(s, /audience === 'business' \? \[\] : split\.treatments/);
  assert.match(rd('booking/shop/src/shop-mock.js'), /public_catalog_for/);
});

test('migraatio 74 tunnistaa Johku 17 ja 41 sekä slugit, eikä poista rivejä', () => {
  const s = rd('booking/supabase/migrations/20261018210000_booking_74_company_audience.sql');
  assert.match(s, /external_id in \('17', '41'\)/);
  assert.match(s, /saunavuoro-yrityksille/);
  assert.match(s, /jalkiloylyt-yrityksille/);
  assert.match(s, /public_catalog_for/);
  assert.doesNotMatch(s, /delete from/i);
  assert.match(rd('booking/supabase/rollbacks/20261018210000_booking_74_ROLLBACK.sql'), /drop column if exists audience/i);
});

test('navigaatio: Yrityksille on viimeinen, lahjakortti pysyy alatunnisteen indeksissä 3', () => {
  const site = J('content/site.json');
  assert.equal(site.ui.fi.nav.at(-1)[0], 'companies');
  assert.equal(site.ui.fi.nav.at(-1)[1], 'Yrityksille');
  assert.equal(site.ui.en.nav.at(-1)[0], 'companies');
  assert.equal(site.ui.en.nav.at(-1)[1], 'For companies');
  assert.equal(site.ui.fi.nav[3][0], 'gift');
  assert.equal(site.ui.en.nav[3][0], 'gift');
});

test('Yrityksille-sivu FI ja EN: valinta, kalenteri, lomake, ei euroja uudessa kuvauksessa', () => {
  for (const [lang, sauna, day] of [['fi', 'Tulemme vain saunomaan', 'Haluamme järjestää työntekijäpäivän'], ['en', 'We only want to sauna', 'We want to arrange a staff day']]) {
    const html = companies(lang);
    assert.equal((html.match(/<h1[ >]/g) || []).length, 1, lang);
    assert.match(html, new RegExp(sauna));
    assert.match(html, new RegExp(day));
    assert.match(html, /id="yritysvuorot"/);
    assert.match(html, /id="tarjous"/);
    assert.match(html, /id="booking-app"/);
    assert.match(html, /id="company-quote"/);
    for (const name of ['company_name', 'contact_name', 'email', 'phone', 'preferred_when', 'persons', 'offering_other', 'message', 'privacy', 'company_website']) assert.match(html, new RegExp(`name="${name}"`));
    for (const v of ['ritual', 'forest_yoga', 'campfire_meal', 'sauna', 'vihta_workshop', 'other']) assert.match(html, new RegExp(`value="${v}"`));
    assert.match(html, /class="sr"/);
    assert.match(html, /tabindex="-1"/);
    assert.match(html, /data-code="privacy_required"/);
    assert.match(html, /data-code="ok"/);
    assert.ok(html.includes(`<a href="${pageHref('privacy', 'fi')}"`), `${lang}: tietosuojalinkki`);
    if (lang === 'en') assert.match(html, /hreflang="fi" lang="fi"/);
    assert.match(html, lang === 'fi' ? />Lue seloste</ : />Read the notice</);
    assert.match(html, lang === 'fi'
      ? /<label class="check"><input type="checkbox" name="privacy" value="1"> Olen lukenut tietosuojaselosteen ja hyväksyn, että yhteystietojani käytetään tämän pyynnön käsittelyyn\.<\/label>/
      : /<label class="check"><input type="checkbox" name="privacy" value="1"> I have read the privacy notice and accept that my contact details are used to handle this request\.<\/label>/);
    const desc = /<meta name="description" content="([^"]*)"/.exec(html)[1];
    assert.ok(desc.length > 20 && desc.length <= 175, `${lang} description ${desc.length}: ${desc}`);
    assert.doesNotMatch(desc, /€|\{?\{?price:/);
    assert.equal((html.match(/<h1[ >]/g) || []).length, 1);
  }
  const doc = J('content/pages/companies.json');
  const flow = JSON.stringify(doc.fi.flow) + JSON.stringify(doc.en.flow);
  assert.doesNotMatch(flow, /€|\bklo\b/);
});

test('tarjouspyyntö: validointi vastaa samoja rajoja kuin RPC', () => {
  const ok = validateQuote(okInput());
  assert.equal(ok.ok, true);
  assert.equal(ok.value.email, 'maija@example.test');
  assert.equal(ok.value.persons, 12);
  assert.equal(ok.value.offering_other, null);
  const other = validateQuote(okInput({ offerings: ['other'], offering_other: '  metsäretki  ' }));
  assert.equal(other.ok, true);
  assert.equal(other.value.offering_other, 'metsäretki');
  const cases = [
    [{ company_name: 'A' }, 'invalid_company'],
    [{ contact_name: 'A' }, 'invalid_contact'],
    [{ email: 'ei-osoite' }, 'invalid_email'],
    [{ phone: '12' }, 'invalid_phone'],
    [{ preferred_when: 'x' }, 'invalid_when'],
    [{ persons: '0' }, 'invalid_persons'],
    [{ persons: '301' }, 'invalid_persons'],
    [{ persons: 'kymmenen' }, 'invalid_persons'],
    [{ offerings: [] }, 'invalid_offerings'],
    [{ offerings: ['nope'] }, 'invalid_offerings'],
    [{ offerings: ['other'], offering_other: 'x' }, 'invalid_offering_other'],
    [{ message: 'x'.repeat(2001) }, 'invalid_message'],
    [{ privacy: false }, 'privacy_required'],
  ];
  for (const [over, code] of cases) assert.equal(validateQuote(okInput(over)).code, code, code);
  assert.deepEqual(OFFERINGS, ['ritual', 'forest_yoga', 'campfire_meal', 'sauna', 'vihta_workshop', 'other']);
});

test('tuontiluonnos: uudet avaimet, tietosuoja protected, ei päällekkäisyyttä eikä hintoja', () => {
  const extra = J('content/site-texts.imported-pr75.json');
  const pending9 = J('content/site-texts.pending-import-9.json');
  const have = new Set(['content/site-texts.imported-pr61.json', 'content/site-texts.imported-pr64.json', 'content/site-texts.imported-pr66.json', 'content/site-texts.imported.json'].flatMap((p) => J(p).map((r) => `${r.key}|${r.lang}`)));
  const seen = new Set();
  for (const r of extra) {
    assert.ok(!have.has(`${r.key}|${r.lang}`), r.key);
    assert.ok(!seen.has(`${r.key}|${r.lang}`)); seen.add(`${r.key}|${r.lang}`);
    assert.doesNotMatch(r.text, /€|\{\{price:/);
    assert.ok(['fi', 'en'].includes(r.lang));
  }
  for (const k of new Set(extra.map((r) => r.key))) assert.ok(seen.has(`${k}|fi`) && seen.has(`${k}|en`), k);
  const cls = (k) => extra.find((r) => r.key === k && r.lang === 'fi').class;
  assert.equal(cls('page.companies.flow.privacy'), 'protected');
  assert.equal(cls('page.companies.flow.error_privacy_required'), 'protected');
  assert.equal(cls('page.companies.flow.notice_link'), 'normal');
  assert.equal(classForContent('page.companies.flow.privacy', extra.find((r) => r.key === 'page.companies.flow.privacy' && r.lang === 'fi').text), 'protected');
  assert.equal(classForContent('page.companies.flow.notice_link', extra.find((r) => r.key === 'page.companies.flow.notice_link' && r.lang === 'fi').text), 'normal');
  assert.deepEqual(pending9, extra.filter((r) => r.key === 'page.companies.flow.notice_link'));
  assert.equal(pending9.length, 2);
  assert.ok(pending9.every((r) => r.class === 'normal'));
  assert.equal(extra.find((r) => r.key === 'page.companies.flow.privacy' && r.lang === 'fi').text, 'Olen lukenut tietosuojaselosteen ja hyväksyn, että yhteystietojani käytetään tämän pyynnön käsittelyyn.');
  assert.equal(extra.find((r) => r.key === 'page.companies.flow.privacy' && r.lang === 'en').text, 'I have read the privacy notice and accept that my contact details are used to handle this request.');
  assert.equal(extra.find((r) => r.key === 'page.companies.flow.error_privacy_required' && r.lang === 'fi').text, 'Hyväksy tietosuoja, jotta pyyntö voidaan lähettää.');
  assert.equal(extra.find((r) => r.key === 'page.companies.flow.error_privacy_required' && r.lang === 'en').text, 'Accept the privacy notice so the request can be sent.');
  assert.ok(extra.some((r) => r.key === 'nav.main.companies' && r.lang === 'fi' && r.text === 'Yrityksille'));
  assert.ok(extra.some((r) => r.key === 'email.business_quote.sign_name' && r.text === 'Tapio'));
});

test('hallinnan mock: vain quotes.manage listaa ja vaihtaa tilan', async () => {
  const m = createAdminMock();
  const rows = await m.rpc('admin_list_business_quotes', { p_status: null });
  assert.equal(rows.length, 1);
  assert.equal(rows[0].status, 'new');
  await m.rpc('admin_set_business_quote_status', { p_id: 1, p_status: 'offered', p_note: 'luonnos' });
  const offered = await m.rpc('admin_list_business_quotes', { p_status: 'offered' });
  assert.equal(offered.length, 1);
  assert.equal(offered[0].admin_note, 'luonnos');
  await assert.rejects(() => createAdminMock({ perms: ['catalog.edit'] }).rpc('admin_list_business_quotes', {}), (e) => e.code === 'forbidden');
  assert.match(rd('booking/admin/views/products.js'), /'audience' in c/);
  assert.match(rd('booking/admin/admin.js'), /quotes\.manage/);
});
