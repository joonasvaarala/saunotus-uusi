// Kylmälaite-sivun puhdas logiikka. Palvelimelle lähtee vain product_id ja quantity.
export function checkoutItems(cart) {
  return cart.filter((r) => r.quantity > 0).map((r) => ({ product_id: r.product_id, quantity: r.quantity }));
}

export function cartTotal(cart) {
  return Math.round(cart.reduce((s, r) => s + Number(r.unit_price) * r.quantity, 0) * 100) / 100;
}

const ALCOHOL = /(^|[^\p{L}])(olut|oluet|viini|viinit|siideri|lonkero|alkoholi|viina|beer|beers|wine|wines|cider|ciders|whiskey|whisky|vodka|gin|rum|champagne|prosecco|spirits)([^\p{L}]|$)/iu;
export function looksLikeAlcohol(text) {
  return ALCOHOL.test(String(text ?? ''));
}

export function drinksCartAdd(cart, product) {
  const next = cart.map((r) => ({ ...r }));
  const row = next.find((r) => r.product_id === product.product_id);
  if (row) row.quantity = Math.min(20, row.quantity + 1);
  else next.push({ product_id: product.product_id, name: product.name, unit_price: Number(product.price), vat_rate: product.vat_rate, quantity: 1 });
  return next;
}

export function drinksCartSet(cart, productId, quantity) {
  const q = Math.max(0, Math.min(20, quantity));
  return cart.map((r) => (r.product_id === productId ? { ...r, quantity: q } : { ...r })).filter((r) => r.quantity > 0);
}

export function productLabel(product, lang) {
  if (lang === 'en' && product.name_en) return product.name_en;
  return product.name;
}

export function deviceFromSearch(search) {
  const q = new URLSearchParams(String(search || '').replace(/^\?/, ''));
  return q.get('laite') || q.get('device') || '';
}
