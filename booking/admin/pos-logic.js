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

export function cartAdd(cart, product) {
  const next = cart.map((r) => ({ ...r }));
  const row = next.find((r) => r.product_id === product.product_id);
  if (row) row.quantity += 1;
  else next.push({ product_id: product.product_id, name: product.name, unit_price: Number(product.price), vat_rate: product.vat_rate, quantity: 1, age_restricted: !!product.age_restricted });
  return next;
}

export function cartSetQty(cart, productId, quantity) {
  const q = Math.max(0, Math.min(20, quantity));
  return cart.map((r) => ({ ...r })).map((r) => (r.product_id === productId ? { ...r, quantity: q } : r)).filter((r) => r.quantity > 0);
}

export function cartTotal(cart) {
  return Math.round(cart.reduce((s, r) => s + Number(r.unit_price) * r.quantity, 0) * 100) / 100;
}

export function checkoutItems(cart) {
  return cart.filter((r) => r.quantity > 0).map((r) => ({ product_id: r.product_id, quantity: r.quantity }));
}

export function tendersFor(list, channel) {
  return (list || [])
    .filter((t) => Array.isArray(t.channels) ? t.channels.includes(channel) : false)
    .filter((t) => t.active || t.handler === 'terminal' || t.code === 'card_terminal')
    .filter((t) => t.code !== 'cash' && t.handler !== 'cash')
    .sort((a, b) => (a.sort_order ?? 100) - (b.sort_order ?? 100));
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
