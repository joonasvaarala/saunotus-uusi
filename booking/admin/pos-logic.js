// Pikakassan puhdas logiikka (ei DOM:ia). Hinta tulee katalogista; kassalle lähtee vain tuotetunnus ja määrä.
export const TENDER_HANDLERS = {
  payment_link: { kind: 'link' },
  mobilepay: { kind: 'mobilepay', flows: ['QR', 'PUSH_MESSAGE'] },
  visma_pay: { kind: 'visma' },
  terminal: { kind: 'terminal', later: true },
};

const ALCOHOL = /(^|[^\p{L}])(olut|oluet|viini|viinit|siideri|lonkero|alkoholi|viina|beer|beers|wine|wines|cider|ciders|whiskey|whisky|vodka|gin|rum|champagne|prosecco|spirits)([^\p{L}]|$)/iu;

export function looksLikeAlcohol(text) {
  return ALCOHOL.test(String(text ?? ''));
}

export function cartLineKey(row) {
  if (!row) return null;
  if (row.kind === 'custom') return row.line_key;
  return row.product_id;
}

export function cartAdd(cart, product) {
  const next = cart.map((r) => ({ ...r }));
  const row = next.find((r) => r.kind !== 'custom' && r.product_id === product.product_id);
  if (row) row.quantity += 1;
  else next.push({ product_id: product.product_id, name: product.name, unit_price: Number(product.price), vat_rate: product.vat_rate, quantity: 1, age_restricted: !!product.age_restricted });
  return next;
}

/** Vapaa rivi: oma line_key, ei yhdistetä muihin. */
export function cartAddCustom(cart, { description, unit_price, vat_rate, quantity = 1 } = {}) {
  const name = String(description ?? '').trim();
  const q = Math.max(1, Math.min(20, Number(quantity) || 1));
  const key = `c-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
  return [...(cart || []).map((r) => ({ ...r })), {
    kind: 'custom',
    line_key: key,
    name,
    unit_price: Number(unit_price),
    vat_rate: Number(vat_rate),
    quantity: q,
  }];
}

export function cartSetQty(cart, key, quantity) {
  const q = Math.max(0, Math.min(20, quantity));
  return (cart || []).map((r) => ({ ...r })).map((r) => (cartLineKey(r) === key ? { ...r, quantity: q } : r)).filter((r) => r.quantity > 0);
}

export function cartTotal(cart) {
  return Math.round((cart || []).reduce((s, r) => s + Number(r.unit_price) * r.quantity, 0) * 100) / 100;
}

/** ALV-erittely ostoskorista (brutto → netto/vero per kanta). */
export function cartVatBreakdown(cart) {
  const map = new Map();
  for (const r of cart || []) {
    if (!r || !(r.quantity > 0)) continue;
    const rate = Number(r.vat_rate);
    const gross = Math.round(Number(r.unit_price) * r.quantity * 100) / 100;
    const cur = map.get(rate) || { vat_rate: rate, gross: 0, net: 0, vat: 0 };
    cur.gross = Math.round((cur.gross + gross) * 100) / 100;
    map.set(rate, cur);
  }
  const rows = [...map.values()].sort((a, b) => a.vat_rate - b.vat_rate);
  for (const row of rows) {
    const vat = Math.round((row.gross * row.vat_rate / (100 + row.vat_rate)) * 100) / 100;
    row.vat = vat;
    row.net = Math.round((row.gross - vat) * 100) / 100;
  }
  return rows;
}

/** Euro-syöte: pilkku tai piste, max 2 desimaalia. Palauttaa numeron tai null. */
export function parseEuroInput(raw) {
  const t = String(raw ?? '').trim().replace(/\s/g, '').replace(',', '.');
  if (!t) return null;
  if (!/^\d+(\.\d{1,2})?$/.test(t)) return null;
  const n = Number(t);
  if (!Number.isFinite(n) || n < 0 || n > 100000) return null;
  return Math.round(n * 100) / 100;
}

/** Vapaan rivin kenttien tarkistus (sama henki kuin palvelin). allowedRates = active vat rates. */
export function validateCustomLine({ description, quantity, unit_price, vat_rate } = {}, allowedRates = []) {
  const name = String(description ?? '').trim();
  if (!name) return { ok: false, error: 'description_required' };
  if (name.length > 200) return { ok: false, error: 'description_long' };
  if (name.includes('<')) return { ok: false, error: 'description_invalid' };
  const q = Number(quantity);
  if (!Number.isInteger(q) || q < 1 || q > 20) return { ok: false, error: 'quantity_invalid' };
  const price = typeof unit_price === 'number' ? unit_price : parseEuroInput(unit_price);
  if (price == null || price < 0 || price !== Math.round(price * 100) / 100) return { ok: false, error: 'price_invalid' };
  const rate = Number(vat_rate);
  const allowed = (allowedRates || []).map(Number);
  if (!Number.isFinite(rate) || (allowed.length && !allowed.includes(rate))) return { ok: false, error: 'vat_invalid' };
  return { ok: true, description: name, quantity: q, unit_price: price, vat_rate: rate };
}

export function checkoutItems(cart) {
  return (cart || []).filter((r) => r.quantity > 0).map((r) => {
    if (r.kind === 'custom') {
      return {
        kind: 'custom',
        description: r.name,
        quantity: r.quantity,
        unit_price: Number(r.unit_price),
        vat_rate: Number(r.vat_rate),
      };
    }
    return { product_id: r.product_id, quantity: r.quantity };
  });
}

export function tendersFor(list, channel) {
  return (list || [])
    .filter((t) => Array.isArray(t.channels) ? t.channels.includes(channel) : false)
    .filter((t) => t.active || t.handler === 'terminal' || t.code === 'card_terminal')
    .filter((t) => t.code !== 'cash' && t.handler !== 'cash')
    .sort((a, b) => (a.sort_order ?? 100) - (b.sort_order ?? 100));
}

const DIRECT_ONLINE = new Set(['mobilepay', 'visma_pay']);

/** Pikakassan maksuikkuna: ei suoraa MobilePayta eikä Visma Payta. Maksulinkki ja korttipääte jäävät. */
export function posSheetTenders(list) {
  return tendersFor(list, 'pos').filter((t) => !DIRECT_ONLINE.has(t.code) && !DIRECT_ONLINE.has(t.handler));
}

/** Asiakasrekisterin osumat maksukenttään. Tilauksilta poimitut yritykset (source orders) ja osoitteettomat jätetään pois. */
export function posCustomerHits(rows, limit = 8) {
  const cap = Math.min(Math.max(Number(limit) || 8, 1), 8);
  const out = [];
  const seen = new Set();
  for (const row of rows || []) {
    if (!row || row.source === 'orders') continue;
    const email = String(row.email || '').trim();
    if (!validEmail(email)) continue;
    const key = email.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    const name = String(row.name || '').trim() || String(row.company || '').trim();
    const id = row.customer_id ?? row.id ?? null;
    out.push({ id: id == null || id === '' ? null : id, name, email });
    if (out.length >= cap) break;
  }
  return out;
}

export function tenderAvailable(tender, modes) {
  if (!tender) return false;
  if (tender.handler === 'terminal' || tender.code === 'card_terminal') return false;
  if (!tender.active) return false;
  if (tender.handler === 'mobilepay' || tender.code === 'mobilepay') return false;
  if (tender.handler === 'visma_pay' || tender.code === 'visma_pay') return false;
  if (tender.handler === 'payment_link' || tender.code === 'payment_link') {
    if (modes && Object.prototype.hasOwnProperty.call(modes, 'montonio_mode')) return !!(modes.montonio_mode && modes.montonio_mode !== 'off');
    return !!(modes?.vismapay_mode && modes.vismapay_mode !== 'off');
  }
  return true;
}

/** Sama sääntö kuin booking._valid_email: pituus ja yksi @ sekä piste domainissa. */
export function validEmail(s) {
  const t = String(s ?? '').trim();
  return t.length > 0 && t.length <= 254 && /^[^@\s]+@[^@\s]+\.[^@\s]{2,}$/.test(t);
}

export function joinUrl(base, path) {
  const b = String(base || '').replace(/\/$/, '');
  const p = String(path || '');
  if (/^https?:\/\//i.test(p)) return p;
  return b ? b + (p.startsWith('/') ? p : `/${p}`) : p;
}

const NOT_TILL = new Set(['gift_card', 'season_card']);

/** Tuotteet, jotka voi lisätä pikakassaan. Verkkokaupan näkyvyys ei rajaa. Lahjakortti ja kausikortti eivät kelpaa. */
export function posCandidates(products) {
  return (products || []).filter((p) => p && p.active && p.config && p.price != null && !NOT_TILL.has(p.category));
}

export function filterProducts(products, query) {
  const q = String(query || '').trim().toLocaleLowerCase('fi');
  if (!q) return products || [];
  return (products || []).filter((p) => `${p.name || ''} ${p.name_en || ''}`.toLocaleLowerCase('fi').includes(q));
}

/** Muokkaus aukeaa vain pyydettäessä. Tyhjä kassakin pysyy kiinni, jotta pikapainikkeet ovat ensimmäisenä. */
export function tillEditorOpen(_catalogLength, requested) {
  return !!requested;
}

export function moveSort(rows, productId, dir) {
  const list = [...(rows || [])].sort((a, b) => (a.pos_sort ?? 100) - (b.pos_sort ?? 100) || String(a.name).localeCompare(String(b.name), 'fi'));
  const i = list.findIndex((r) => r.product_id === productId);
  const j = i + dir;
  if (i < 0 || j < 0 || j >= list.length) return list;
  const next = list.slice();
  const [row] = next.splice(i, 1);
  next.splice(j, 0, row);
  return next.map((r, idx) => ({ ...r, pos_sort: (idx + 1) * 10 }));
}

export function productBlob(product) {
  return [product?.name, product?.name_en, product?.description, product?.description_en].filter(Boolean).join(' ');
}

/** QR-linkillä myytävä: ei ikärajaa, ei alkoholin näköinen nimi, ei lahja- tai kausikortti. shop_visible saa olla false. */
export function qrEligible(product) {
  if (!product || !product.active || product.price == null || !product.config) return false;
  if (NOT_TILL.has(product.category)) return false;
  if (product.config.age_restricted) return false;
  if (looksLikeAlcohol(productBlob(product))) return false;
  return true;
}
