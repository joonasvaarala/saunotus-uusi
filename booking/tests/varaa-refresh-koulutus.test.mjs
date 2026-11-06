// Kassalinkin refresh koulutukselle (P0 6.11.2026): #/varaa/<rule_id>/<pvm>/<tuote_id> avautui tuotesivulta, mutta refreshillä
// "No available sessions for the selected day". Syy: linkkikoulutus (channels ['link']) ei ole public_catalogissa; tuotesivu lisää sen
// muistiin public_product_by_slug-haulla, refresh tyhjentää muistin. Korjaus: kassalinkkiin ?tuote=<slug>, jolla tuote haetaan uudelleen.
// Fixturet vastaavat tuotannon tuotetta 121 / sääntöä 158 (5.–9.3.2027). Tuote 158 on keksitty törmäystestiä varten.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const R = await import(pathToFileURL(join(root, 'shop/src/checkout-route.js')).href);
const src = readFileSync(join(root, 'shop/src/shop.js'), 'utf8');

const SLUG = 'matka-suomalaiseen-saunakulttuuriin';
const TRAINING = { id: 121, slug: SLUG, name: 'Matka suomalaiseen saunakulttuuriin', category: 'training', price: 570 };
const SESSION = { rule_id: 158, label: '5.–9.3.2027', label_en: '5–9 Mar 2027', mode: 'shared', session_date: '2027-03-05',
  starts_at: '2027-03-05T10:30:00+00:00', ends_at: '2027-03-09T14:00:00+00:00', status: 'available', remaining: 8,
  min_persons: 1, max_persons: 8, price_mode: 'per_person', unit_price: 570 };
// public_catalog ilman linkkikoulutusta. Tuote 158 = keksitty saunavuoro, jolla sama numero kuin koulutuksen säännöllä.
const PUBLIC = () => [
  { id: 1, slug: 'yleinen-saunavuoro', category: 'public_sauna' },
  { id: 158, slug: 'tormays-tuote', category: 'public_sauna' },
];
const AVAIL = {
  121: { '2027-03-05': [SESSION] },
  1: { '2027-03-05': [{ rule_id: 7, session_date: '2027-03-05', status: 'available' }] },
  158: { '2027-03-05': [{ rule_id: 9, session_date: '2027-03-05', status: 'available' }] },
};
const loadMonth = async (pid, y, m) => {
  assert.equal(y, 2027); assert.equal(m, 2);
  return AVAIL[pid] || {};
};
const bySlug = async (slug) => (slug === SLUG ? { ...TRAINING } : null);
// Reitittimen jäsennys (sama kuin shop.js route()).
const parse = (hash) => {
  const [path, qs] = hash.slice(1).split('?');
  const parts = path.split('/').filter(Boolean);
  const q = new URLSearchParams(qs || '');
  return { parts, slug: q.get('tuote'), via: q.get('via') };
};

test('kurssin kassalinkki kantaa slugin; tavalliset tuotteet ennallaan', () => {
  assert.equal(R.checkoutPath(158, '2027-03-05', TRAINING), `/varaa/158/2027-03-05/121?tuote=${SLUG}`);
  assert.equal(R.checkoutPath(7, '2027-03-05', { id: 1, slug: 'yleinen-saunavuoro', category: 'public_sauna' }), '/varaa/7/2027-03-05/1');
  // tapahtuma (joulusauna, category event) on public_catalogissa → ei muutosta
  assert.equal(R.checkoutPath(71, '2026-12-19', { id: 32, slug: 'naisten-joulusauna', category: 'event', kind: 'event' }), '/varaa/71/2026-12-19/32');
});

test('refresh #/varaa/158/2027-03-05/121?tuote=<slug> palauttaa koulutuksen 121 ja session 158 (ei "No available sessions")', async () => {
  const hash = `#${R.checkoutPath(158, '2027-03-05', TRAINING)}`;
  const { parts, slug } = parse(hash);
  assert.deepEqual(parts, ['varaa', '158', '2027-03-05', '121']);
  const catalog = PUBLIC();   // refresh: vain public_catalog
  const p0 = await R.ensureCheckoutProduct(catalog, parts[3], slug, bySlug);
  assert.equal(p0.id, 121); assert.equal(p0.listed, false); assert.equal(p0.deposit, true);
  const { s, p } = await R.findCheckoutSession(catalog, parts[1], parts[2], parts[3], loadMonth);
  assert.equal(p.id, 121); assert.equal(p.slug, SLUG);
  assert.equal(s.rule_id, 158); assert.equal(s.session_date, '2027-03-05'); assert.equal(s.status, 'available'); assert.equal(s.remaining, 8);
});

test('vanha käytös ilman slugia: koulutus ei löydy (juurisyyn toisto) eikä sääntö 158 sekoitu tuotteeseen 158', async () => {
  const catalog = PUBLIC();
  assert.equal(await R.ensureCheckoutProduct(catalog, '121', null, bySlug), null);
  const r = await R.findCheckoutSession(catalog, '158', '2027-03-05', '121', loadMonth);
  assert.deepEqual(r, { s: null, p: null });
  assert.equal(catalog.length, 2);
});

test('tavallinen tuote-hash ei rikkoudu eikä hae slugilla', async () => {
  const catalog = PUBLIC();
  let calls = 0;
  const spy = async (x) => { calls++; return bySlug(x); };
  const p0 = await R.ensureCheckoutProduct(catalog, '1', null, spy);
  assert.equal(p0.id, 1); assert.equal(calls, 0);
  const { s, p } = await R.findCheckoutSession(catalog, '7', '2027-03-05', '1', loadMonth);
  assert.equal(p.id, 1); assert.equal(s.rule_id, 7);
  // tuote 158 omalla säännöllään 9
  const t2 = await R.findCheckoutSession(catalog, '9', '2027-03-05', '158', loadMonth);
  assert.equal(t2.p.id, 158); assert.equal(t2.s.rule_id, 9);
});

test('slug ei voi vaihtaa tuotetta: väärä id, ei-koulutus tai virhe → ei lisätä', async () => {
  const catalog = PUBLIC();
  assert.equal(await R.ensureCheckoutProduct(catalog, '999', SLUG, bySlug), null);   // slug osoittaa tuotteeseen 121
  assert.equal(await R.ensureCheckoutProduct(catalog, '121', SLUG, async () => ({ ...TRAINING, category: 'event' })), null);
  assert.equal(await R.ensureCheckoutProduct(catalog, '121', SLUG, async () => { throw new Error('rpc'); }), null);
  assert.equal(await R.ensureCheckoutProduct(catalog, 'abc', SLUG, bySlug), null);
  assert.equal(catalog.length, 2);
  // jo luettelossa (tuotesivun kautta tultu) → ei uutta hakua eikä tuplaa
  const withTraining = [...PUBLIC(), { ...TRAINING, listed: false, deposit: true }];
  let calls = 0;
  await R.ensureCheckoutProduct(withTraining, '121', SLUG, async (x) => { calls++; return bySlug(x); });
  assert.equal(calls, 0); assert.equal(withTraining.length, 3);
});

test('shop.js: kurssin päivä-/aikalinkit käyttävät checkoutPathia ja reititin välittää ?tuote= kassalle (FI ja EN sama koodi)', () => {
  assert.match(src, /bk\(checkoutPath\(s\.r\.rule_id, s\.date, p\)\)/);
  assert.match(src, /training \? \(ok \? bk\(checkoutPath\(r\.rule_id, ds, p\)\) : null\)/);
  assert.match(src, /viewCheckout\(parts\[1\], parts\[2\], parts\[3\], q\.get\('via'\), q\.get\('tuote'\)\)/);
  assert.match(src, /ensureCheckoutProduct\(state\.catalog, productId, slug, \(x\) => rpc\('public_product_by_slug'/);
  assert.match(src, /findCheckoutSession\(state\.catalog, ruleId, ds, productId, loadMonth\)/);
});
