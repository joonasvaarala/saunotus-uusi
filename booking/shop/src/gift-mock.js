// Lahjakorttien MOCK-PALVELIN (kauppa): keksityt kortit muistissa; vain kun osoitteessa on ?mock=1 (sekä testit). Ei kosketa palvelinta.
// Vastaa KOODARI_talous_A_D_fi.md §13.2: nimet, p_-parametrit, vastausrakenteet, virheet {ok:false, code, message}.
// public_gift_card_packages-vastauksen sisältö (testiprojekti = tuotannon siemendata, 17.10.2026): nimet, hinnat, kuvaukset ja items-rakenne ({label, label_en, persons, kb_product_id} | {label, label_en, persons, addon_code}; label_en lisätty migraatiossa booking_45)
import { resolveDelivery, guessSource, isMismatch, claimMethod, CLAIM_SOURCES, SOURCE_LABELS } from './gift-logic.js';
export const MOCK_PACKAGES = [
  {
    code: 'open',
    name: 'Avoin lahjakortti',
    name_en: 'Open gift card',
    description: 'Vapaa summa; käy kaikkiin palveluihin. Voimassa 6 kuukautta.',
    description_en: 'Any amount; valid for all services. Valid for 6 months.',
    kind: 'value',
    is_open: true,
    price: null,
    min_amount: 29,
    max_amount: 500,
    persons: null,
    vat_rate: 25.5,
    valid_months: 6,
    items: []
  },
  {
    code: 'entry_2',
    name: 'Savusaunavuoro kahdelle',
    name_en: 'Smoke sauna session for two',
    description: 'Savusaunavuoro kahdelle hengelle (2 × 29 €).',
    description_en: 'Smoke sauna session for two (2 × €29).',
    kind: 'product',
    is_open: false,
    price: 58,
    min_amount: null,
    max_amount: null,
    persons: 2,
    vat_rate: 25.5,
    valid_months: 6,
    items: [
      {
        label: 'Yleinen vuoro',
        label_en: 'General session',
        persons: 2,
        kb_product_id: 1
      }
    ]
  },
  {
    code: 'peat_mask_2',
    name: 'Savusaunaelämys turvenaamiolla ja jalkakylvyllä kahdelle',
    name_en: 'Smoke sauna experience with peat mask and foot bath for two',
    description: 'Sisäänpääsy kahdelle + omatoiminen turvenaamio ja jalkakylpy (2 × 15 €).',
    description_en: 'Admission for two + self-guided peat mask and foot bath.',
    kind: 'product',
    is_open: false,
    price: 88,
    min_amount: null,
    max_amount: null,
    persons: 2,
    vat_rate: 25.5,
    valid_months: 6,
    items: [
      {
        label: 'Yleinen vuoro',
        label_en: 'General session',
        persons: 2,
        kb_product_id: 1
      },
      {
        label: 'Turvenaamio ja jalkakylpy',
        label_en: 'Peat mask and foot bath',
        persons: 2,
        addon_code: 'turvenaamio_jalkakylpy'
      }
    ]
  },
  {
    code: 'sauna_treatment_2',
    name: 'Savusaunaelämys ja saunahoito kahdelle',
    name_en: 'Smoke sauna experience and sauna treatment for two',
    description: 'Sisäänpääsy kahdelle + saunahoito kahdelle (60 min).',
    description_en: 'Admission for two + sauna treatment for two (60 min).',
    kind: 'product',
    is_open: false,
    price: 192,
    min_amount: null,
    max_amount: null,
    persons: 2,
    vat_rate: 25.5,
    valid_months: 6,
    items: [
      {
        label: 'Yleinen vuoro',
        label_en: 'General session',
        persons: 2,
        kb_product_id: 1
      },
      {
        label: 'Saunahoito',
        label_en: 'Sauna treatment',
        persons: 2,
        kb_product_id: 10
      }
    ]
  },
  {
    code: 'saunotus_2',
    name: 'Savusaunaelämys ja saunotus kahdelle',
    name_en: 'Smoke sauna experience and ritual sauna bathing for two',
    description: 'Sisäänpääsy kahdelle + saunotus kahdelle (2 h).',
    description_en: 'Admission for two + ritual sauna bathing for two (2 h).',
    kind: 'product',
    is_open: false,
    price: 328,
    min_amount: null,
    max_amount: null,
    persons: 2,
    vat_rate: 25.5,
    valid_months: 6,
    items: [
      {
        label: 'Yleinen vuoro',
        label_en: 'General session',
        persons: 2,
        kb_product_id: 1
      },
      {
        label: 'Saunotus',
        label_en: 'Ritual sauna bathing',
        persons: 2,
        kb_product_id: 11
      }
    ]
  }
];
export const MOCK_TOKEN = '3f2b8c1e-5a7d-4e9f-8b6a-1c2d3e4f5a6b';
const fmtCode = (n) => `${n.slice(0, 4)}-${n.slice(4, 8)}-${n.slice(8)}`;
const norm = (s) => String(s ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '');
const r2 = (n) => Math.round(n * 100) / 100;
const uuid = (i) => `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`;
export function createGiftMock({ delay = 0, settings = {}, today = new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' }), order = null } = {}) {
  const cfg = { sale_enabled: true, redeem_enabled: true, max_cards: 10, claims_enabled: true, ...settings };
  const day = (n) => { const d = new Date(`${today}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
  const wait = () => (delay ? new Promise((ok) => setTimeout(ok, delay)) : Promise.resolve());
  const bad = (code, message) => ({ ok: false, code, message });
  // Keksityt kortit (koodit eivät ole oikeita)
  const cards = [
    { code: 'HH3A7CEFHJKL', pkg: 'open', initial: 150, balance: 100, status: 'active', valid_to: day(120), source: 'native' },
    { code: 'HH7MRTUVWXY3', pkg: 'entry_2', initial: 58, balance: 58, status: 'active', valid_to: day(30), source: 'native' },
    { code: 'HHAAAAAAAAAA', pkg: 'open', initial: 50, balance: 50, status: 'expired', valid_to: day(-10), source: 'native' },
    { code: 'HHCCCCCCCCCC', pkg: 'open', initial: 40, balance: 0, status: 'used', valid_to: day(60), source: 'native' },
    { code: 'JK1234567890', pkg: null, initial: 60, balance: 40, status: 'active', valid_to: day(90), source: 'johku' },
    { code: 'HHPPPPPPPPPP', pkg: 'open', initial: 30, balance: 30, status: 'pending_payment', valid_to: null, source: 'native', hidden: true },
  ];
  const fails = [];   // yksinkertainen rate limit: 10 epäonnistunutta → rate_limited
  const limited = () => fails.length >= 10;
  const find = (c) => cards.find((x) => x.code === norm(c) && !x.hidden && x.status !== 'cancelled' && x.status !== 'pending_payment');
  const pkgName = (c) => MOCK_PACKAGES.find((p) => p.code === c.pkg)?.name ?? null;
  const notRedeemable = (c) => (!cfg.redeem_enabled ? 'redeem_disabled' : c.source === 'johku' && !cfg.johku ? 'johku_cards_closed' : c.status === 'expired' ? 'expired' : c.balance <= 0 ? 'empty' : null);
  // ---- Kumppanilahjakortit (§13.12, booking_47/48): lunastuspyynnöt muistissa. Mock peilaa palvelimen virhejärjestystä ja vastausmuotoja. ----
  const claims = (cfg.claims_seed || []).map((c, i) => ({ claim_no: 100 + i, source: 'elamyslahjat', status: 'open', problem_code: null, amount: null, code: `SEED${i}ABCDEF`, created_at: `${today}T08:00:00Z`, ...c }));
  let claimSeq = 200;
  const mask = (c) => `…${String(c).slice(-4)}`;
  const publicClaim = (c, orderOpen) => ({ claim_no: c.claim_no, source: c.source, source_label: SOURCE_LABELS[c.source] || SOURCE_LABELS.partner_other, code_masked: mask(c.code), status: c.status,
    public_status: c.status === 'open' || c.status === 'processing' ? 'received' : c.status, problem_code: c.status === 'problem' ? c.problem_code : null, hold_until: null,
    can_update_code: (c.status === 'open' || c.status === 'problem') && orderOpen, amount: c.status === 'redeemed' ? c.amount : null, created_at: c.created_at });
  const orderOpen = () => !order?.status || ['pending', 'confirmed'].includes(order.status());
  const sourcesJson = () => CLAIM_SOURCES.map((code) => ({ code, label: SOURCE_LABELS[code], label_en: SOURCE_LABELS[code] }));
  const myCards = [];      // ostetut kortit (mock-osto)
  let orderNo = 15400;
  const handlers = {
    public_gift_card_packages: () => ({ ok: true, sale_enabled: cfg.sale_enabled, redeem_enabled: cfg.redeem_enabled, max_cards_per_order: cfg.max_cards, currency: 'EUR', packages: JSON.parse(JSON.stringify(MOCK_PACKAGES)) }),
    public_check_gift_card: ({ p_code }) => {
      if (limited()) return bad('rate_limited', 'Liian monta yritystä');
      const c = find(p_code); if (!c) { fails.push(1); return bad('invalid_code', 'Koodia ei löytynyt'); }
      const st = c.status === 'active' && c.valid_to < today ? 'expired' : c.status;
      return { ok: true, code: fmtCode(c.code), type: 'value', package_code: c.pkg, package_name: pkgName(c), status: st, initial_amount: c.initial, balance: c.balance, currency: 'EUR', valid_to: c.valid_to, redeemable: notRedeemable({ ...c, status: st }) === null, not_redeemable_reason: notRedeemable({ ...c, status: st }), balance_verified: true };
    },
    public_apply_gift_card: ({ p_token, p_code, p_amount }) => {
      if (limited()) return bad('rate_limited', 'Liian monta yritystä');
      if (!order) return bad('not_found', 'Tilausta ei löytynyt');
      if (!p_token) return bad('not_found', 'Tilausta ei löytynyt');
      const c = find(p_code); if (!c) { fails.push(1); return bad('invalid_code', 'Koodia ei löytynyt'); }
      if (!cfg.redeem_enabled) return bad('redeem_disabled', 'Lahjakortin käyttö ei ole vielä käytössä');
      if (c.source === 'johku' && !cfg.johku) return bad('johku_cards_closed', 'Johku-kortit eivät ole vielä lunastettavissa');
      if (order.hasGiftCards()) return bad('gift_card_not_allowed', 'Lahjakortilla ei voi ostaa lahjakorttia');
      if (c.status === 'expired' || c.valid_to < today) return bad('gift_card_expired', 'Kortti on vanhentunut');
      if (c.balance <= 0) return bad('gift_card_empty', 'Kortin saldo on käytetty');
      if (c.status !== 'active') return bad('gift_card_inactive', 'Kortti ei ole käytössä');
      const unpaid = order.unpaid(); if (unpaid <= 0) return bad('nothing_to_pay', 'Ei maksettavaa');
      let amt = p_amount == null ? Math.min(c.balance, unpaid) : r2(+p_amount);
      if (!(amt > 0)) return bad('invalid_amount', 'Virheellinen summa');
      if (amt > c.balance) return bad('insufficient_balance', 'Saldo ei riitä');
      if (amt > unpaid) return bad('amount_exceeds_unpaid', 'Summa ylittää maksamattoman osan');
      c.balance = r2(c.balance - amt); if (c.balance === 0) c.status = 'used';
      const bal = order.pay(amt, c);
      return { ok: true, mock: true, amount: amt, balance: bal, gift_card: { code_last4: c.code.slice(-4), balance: c.balance, status: c.status, valid_to: c.valid_to }, payment_id: 9000 + Math.floor(Math.random() * 100) };
    },
    public_resolve_gift_code: ({ p_code }) => {
      if (limited()) return bad('rate_limited', 'Liian monta yritystä');
      const n = norm(p_code); if (n.length < 6 || n.length > 24) return bad('invalid_code', 'Tarkista koodi');
      const own = handlers.public_check_gift_card({ p_code });
      if (own.ok) return { ...own, kind: 'own' };
      if (own.code === 'rate_limited') return own;
      const g = guessSource(n);
      return { ok: true, kind: 'unknown', partner_claims_enabled: cfg.claims_enabled !== false, suggested_source: g.source, suggestion_confidence: g.confidence, sources: sourcesJson() };
    },
    public_submit_voucher_claim: ({ p_token, p_code, p_source, p_order_item_id }) => {
      void p_order_item_id;
      if (limited()) return bad('rate_limited', 'Liian monta yritystä');
      if (cfg.claims_enabled === false) return bad('voucher_claims_disabled', 'Kumppanilahjakorttien lunastus verkossa ei ole vielä käytössä');
      if (!order || !p_token) return bad('not_found', 'Tilausta ei löydy');
      const src = String(p_source ?? '').trim().toLowerCase(), n = norm(p_code);
      if (!CLAIM_SOURCES.includes(src)) return bad('invalid_source', 'Valitse lahjakortin myyjä');
      if (!/^[A-Z0-9]{6,24}$/.test(n)) { fails.push(1); return bad('invalid_code', 'Tarkista koodi'); }
      if (!orderOpen()) return bad('order_not_editable', 'Tilaukselle ei voi kirjata maksua');
      if (order.hasGiftCards()) return bad('gift_card_not_allowed', 'Lahjakortilla ei voi ostaa lahjakorttia');
      if (cards.some((c) => c.code === n && c.status !== 'cancelled' && c.status !== 'pending_payment')) return bad('use_own_card', 'Koodi on oma lahjakortti: käytä lahjakortin lunastusta');
      if (order.unpaid() <= 0) return bad('nothing_to_pay', 'Tilauksella ei ole maksettavaa');
      const ex = claims.find((c) => c.code === n && ['open', 'processing', 'redeemed'].includes(c.status));
      if (ex) { if (ex.status !== 'redeemed') return { ok: true, already: true, claim_no: ex.claim_no, status: 'open', source: ex.source, source_label: SOURCE_LABELS[ex.source], code_masked: mask(ex.code), hold_until: null }; return bad('code_already_claimed', 'Tämä koodi on jo käytössä toisella varauksella'); }
      if (claims.filter((c) => ['open', 'processing', 'problem'].includes(c.status)).length >= 10) return bad('too_many_claims', 'Liian monta lahjakoodia tilauksella');
      claims.filter((c) => c.status === 'problem').forEach((c) => { c.status = 'cancelled'; c.by = 'customer'; });
      const c = { claim_no: ++claimSeq, source: src, status: 'open', problem_code: null, amount: null, code: n, created_at: new Date().toISOString(), suggested: guessSource(n).source }; claims.push(c);
      return { ok: true, claim_no: c.claim_no, status: 'open', source: c.source, source_label: SOURCE_LABELS[c.source], code_masked: mask(c.code), hold_until: null, source_mismatch: isMismatch(c.code, c.source),
        payment_method: claimMethod(c.source), payment_method_label: `Lahjakortti – ${SOURCE_LABELS[c.source]}` };
    },
    public_get_order_voucher_claims: ({ p_token }) => {
      if (!p_token) return bad('not_found', 'not_found');
      return { ok: true, claims: claims.filter((c) => !(c.status === 'cancelled' && c.by === 'customer')).map((c) => publicClaim(c, orderOpen())) };
    },
    public_update_voucher_claim_code: ({ p_token, p_claim_id, p_code, p_source }) => {
      if (limited()) return bad('rate_limited', 'Liian monta yritystä');
      if (cfg.claims_enabled === false) return bad('voucher_claims_disabled', 'Kumppanilahjakorttien lunastus verkossa ei ole vielä käytössä');
      if (!order || !p_token) return bad('not_found', 'Tilausta ei löydy');
      if (!orderOpen()) return bad('order_not_editable', 'Tilaukselle ei voi kirjata maksua');
      const c = claims.find((x) => x.claim_no === +p_claim_id); if (!c) return bad('not_found', 'Lunastuspyyntöä ei löydy');
      if (c.status === 'processing') return bad('busy', 'Botti käsittelee juuri');
      if (!['open', 'problem'].includes(c.status)) return bad('claim_not_editable', 'Pyyntöä ei voi enää muuttaa');
      const src = p_source == null || String(p_source).trim() === '' ? c.source : String(p_source).trim().toLowerCase(), n = norm(p_code) || c.code;   // tyhjä koodi = vain myyjän vaihto (booking_173)
      if (!CLAIM_SOURCES.includes(src) && src !== c.source) return bad('invalid_source', 'Valitse lahjakortin myyjä');
      if (!/^[A-Z0-9]{6,24}$/.test(n)) { fails.push(1); return bad('invalid_code', 'Tarkista koodi'); }
      if (n === c.code && src === c.source) return bad('unchanged', 'Koodi ja myyjä ovat samat');
      if (cards.some((x) => x.code === n && x.status !== 'cancelled' && x.status !== 'pending_payment')) return bad('use_own_card', 'Koodi on oma lahjakortti');
      if (claims.some((x) => x !== c && x.code === n && ['open', 'processing', 'redeemed'].includes(x.status))) return bad('code_already_claimed', 'Koodi on jo käytössä');
      Object.assign(c, { code: n, source: src, status: 'open', problem_code: null, suggested: guessSource(n).source });
      return { ok: true, claim_no: c.claim_no, status: 'open', public_status: 'received', source: c.source, source_label: SOURCE_LABELS[c.source], code_masked: mask(c.code), source_mismatch: isMismatch(c.code, c.source),
        payment_method: claimMethod(c.source), payment_method_label: `Lahjakortti – ${SOURCE_LABELS[c.source]}` };
    },
    public_buy_gift_card: (a) => {
      const err = validateBuy(a, cfg); if (err) return err;
      const items = a.p_items, cs = [];
      let total = 0;
      items.forEach((it) => {
        const p = MOCK_PACKAGES.find((x) => x.code === it.package), q = it.quantity ?? 1, amt = p.is_open ? +it.amount : p.price;
        const dl = deliveryOf(it, a, p).value;
        for (let i = 0; i < q; i++) { total += amt; cs.push({ public_token: uuid(myCards.length + cs.length + 1), package_code: p.code, package_name: p.name, amount: amt, status: 'pending_payment', vat_treatment: 'at_sale', recipient_name: it.recipient_name ?? a.p_recipient_name ?? null, delivery_to: dl.delivery_to, deliver_on: dl.deliver_on, deliver_time: dl.deliver_time }); }
      });
      myCards.push(...cs);
      return { ok: true, mock: true, order_no: ++orderNo, token: MOCK_TOKEN, status: 'confirmed', total: r2(total), payment_mode: 'pay_later', payment_url: null, cards: cs, note: 'Kortit aktivoituvat, kun tilaus on maksettu.' };
    },
    public_get_order_gift_cards: ({ p_token }) => {
      if (!p_token) return bad('not_found', 'Tilausta ei löytynyt');
      if (order?.giftCardList) return { ok: true, order_no: order.orderNo, payment_status: order.paymentStatus(), cards: order.giftCardList() };
      return { ok: true, order_no: orderNo, payment_status: 'unpaid', cards: myCards.map((c) => ({ token: c.public_token, package_code: c.package_code, package_name: c.package_name, amount: c.amount, status: c.status, valid_to: null, recipient_name: c.recipient_name, delivery_to: c.delivery_to ?? 'buyer', deliver_on: c.deliver_on ?? null, deliver_time: c.deliver_time ?? null, delivered_at: null, ready: false })) };
    },
    public_get_gift_card: ({ p_public_token }) => {
      const c = order?.cardByToken?.(p_public_token) ?? myCards.find((x) => x.public_token === p_public_token);
      if (!c) return bad('not_found', 'Korttia ei löytynyt');
      if (c.status === 'pending_payment') return bad('not_ready', 'Kortti ei ole vielä valmis');
      return { ok: true, code: fmtCode(c.code), status: c.status, kind: 'value', package_code: c.package_code, package: { name: c.package_name, name_en: c.package_name, description: '', description_en: '', persons: null, items: [] }, initial_amount: c.amount, balance: c.balance ?? c.amount, currency: 'EUR', valid_from: day(0), valid_to: c.valid_to, recipient_name: c.recipient_name ?? null, greeting: c.greeting ?? 'Hyvää syntymäpäivää! Nauti saunasta.', buyer_name: 'Esimerkki Ostaja', locale: 'fi', issued_at: `${day(0)}T10:00:00Z`, source: 'native', seller: { name: 'Sipoonjoen Perinnesauna' } };
    },
  };
  async function rpc(name, args = {}) {
    await wait();
    const h = handlers[name]; if (!h) throw Object.assign(new Error(`Could not find the function booking.${name} in the schema cache`), { status: 404, code: 'PGRST202' });
    if (name === 'public_buy_gift_card' && !cfg.sale_enabled) return bad('sale_disabled', 'Verkkomyynti ei ole käytössä');
    return h(args);
  }
  return { rpc, cards, cfg, handlers, myCards, claims };
}
// Toimitusvalinta (§13.11): sama kuin palvelimen _gc_delivery_resolve; rivin arvo voittaa p_-oletuksen
const DELIVERY_MSG = { invalid_delivery_to: 'Toimitustapa: buyer tai recipient', recipient_email_required: 'Anna saajan sähköpostiosoite kun lahjakortti lähetetään suoraan saajalle', invalid_cover_message: 'Saateteksti on liian pitkä (max 1000 merkkiä)', invalid_deliver_on: 'Anna ajankohta muodossa VVVV-KK-PP', invalid_deliver_time: 'Kellonaika muodossa HH:MM', deliver_on_past: 'Toimituspäivä ei voi olla menneisyydessä', deliver_on_too_far: 'Toimituspäivä on liian kaukana' };
export function deliveryOf(it, a, p) {
  const re = String(it.recipient_email ?? a.p_recipient_email ?? '').trim().toLowerCase() || null;
  return resolveDelivery({ to: it.delivery_to ?? a.p_delivery_to, recipientEmail: re, cover: it.cover_message ?? a.p_cover_message, on: it.deliver_on ?? a.p_deliver_on, time: it.deliver_time ?? a.p_deliver_time, months: p.valid_months ?? 6 });
}
// Palvelimen tarkistukset (§13.2): järjestys kuten tietokannassa suunnilleen; riittää testaamaan UI:n virhepolut
export function validateBuy(a, cfg = { max_cards: 10 }) {
  const bad = (code, message) => ({ ok: false, code, message });
  if (String(a.p_name ?? '').trim().length < 2) return bad('invalid_name', 'Virheellinen nimi');
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(String(a.p_email ?? '').trim())) return bad('invalid_email', 'Virheellinen sähköposti');
  if (String(a.p_phone ?? '').replace(/\D/g, '').length < 6) return bad('invalid_phone', 'Virheellinen puhelin');
  const items = a.p_items;
  if (!Array.isArray(items) || !items.length || items.length > 10) return bad('invalid_items', 'Virheelliset rivit');
  let n = 0;
  for (const it of items) {
    const p = MOCK_PACKAGES.find((x) => x.code === it.package); if (!p) return bad('invalid_package', 'Tuntematon paketti');
    const q = it.quantity ?? 1; if (!Number.isInteger(q) || q < 1) return bad('invalid_quantity', 'Virheellinen määrä');
    n += q;
    if (p.is_open) { const am = Number(it.amount); if (!(am >= p.min_amount && am <= p.max_amount) || Math.round(am * 100) !== am * 100) return bad('invalid_amount', 'Virheellinen summa'); }
    const g = it.greeting ?? a.p_greeting; if (g && [...String(g)].length > 300) return bad('invalid_greeting', 'Tervehdys on liian pitkä');
    for (const e of [it.recipient_email ?? a.p_recipient_email]) if (e && !/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(e)) return bad('invalid_email', 'Virheellinen saajan sähköposti');
    const dl = deliveryOf(it, a, p); if (!dl.ok) return bad(dl.code, DELIVERY_MSG[dl.code] || dl.code);
  }
  if (n > (cfg.max_cards ?? 10)) return bad('too_many_cards', 'Liikaa kortteja');
  return null;
}
