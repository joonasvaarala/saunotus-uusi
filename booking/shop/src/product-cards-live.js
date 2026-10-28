// Staattisten sivujen tuotekortit. Esirenderöity kuva on paikanvaraaja.
// public_product_images korvaa sen tuotteen omalla kuvalla; ilman kuvaa jää toimituksellinen varakuva.
// Versio (updated_at tai polku) on osoitteen v-parametri, jotta selain ei näytä välimuistin vanhaa tiedostoa.
import { rpc } from './sb.js';
import { productImageElement, CARD_WIDTHS, SIZES, liveImageUrl, imageVersionOf } from './product-image.js';

const h = (tag, props = {}, ...children) => {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (value == null || value === false) continue;
    if (key === 'class') el.className = value;
    else el.setAttribute(key, String(value));
  }
  for (const kid of children.flat()) if (kid) el.append(kid);
  return el;
};

const asRows = (raw) => {
  let v = raw;
  if (typeof v === 'string') { try { v = JSON.parse(v); } catch { return []; } }
  return Array.isArray(v) ? v : [];
};
const imageBase = () => {
  const url = String(globalThis.window?.BOOKING_CONFIG?.url || '').replace(/\/$/, '');
  return url ? `${url}/storage/v1/object/public/product-images` : '';
};
const widthsOf = (el) => {
  const raw = String(el?.dataset?.widths || '').split(',').map((n) => Number(n)).filter((n) => n > 0);
  return raw.length ? raw : CARD_WIDTHS;
};
const isBox = (el) => el.classList.contains('im') || el.classList.contains('bk-img');

function showFallback(box) {
  const tpl = box.querySelector(':scope > template.pi-fallback');
  const old = box.querySelector(':scope > picture, :scope > img');
  if (!tpl || !old) return;
  const src = old.querySelector?.('img')?.getAttribute('src') || old.getAttribute?.('src') || '';
  if (!/\/product-images\//.test(src)) return;
  const node = tpl.content.cloneNode(true).firstElementChild;
  if (!node) return;
  old.replaceWith(node);
  box.dataset.piVer = 'fallback';
}

function paint(host, row, base) {
  let box = isBox(host) ? host : host.querySelector(':scope > .im, :scope > .bk-img');
  const url = row ? liveImageUrl(base, row) : '';
  if (!url) { if (box) showFallback(box); return; }
  const ver = imageVersionOf(row) || row.path;
  if (!box) {
    box = host.ownerDocument.createElement('div');
    box.className = 'im';
    if (host.dataset.sizes) box.dataset.sizes = host.dataset.sizes;
    if (host.dataset.widths) box.dataset.widths = host.dataset.widths;
    if (host.dataset.alt) box.dataset.alt = host.dataset.alt;
    host.prepend(box);
    host.classList.remove('noimg');
  }
  if (box.dataset.piVer === ver) return;
  const img = box.querySelector('img');
  if (img && img.getAttribute('src') === url) { box.dataset.piVer = ver; return; }
  const alt = (row.alt && String(row.alt).trim()) || box.dataset.alt || host.dataset.alt || img?.alt || '';
  const w = Number(img?.getAttribute('width')) || 900;
  const hgt = Number(img?.getAttribute('height')) || 600;
  const sizes = box.dataset.sizes || host.dataset.sizes || SIZES.shop;
  const node = productImageElement(h, url, { widths: widthsOf(box.dataset.widths ? box : host), sizes, alt, width: w, height: hgt, lazy: img ? img.getAttribute('loading') !== 'eager' : true });
  const old = box.querySelector(':scope > picture, :scope > img');
  if (old) old.replaceWith(node); else box.prepend(node);
  const next = node.tagName === 'IMG' ? node : node.querySelector('img');
  if (next && old) next.addEventListener('error', () => { if (node.isConnected) node.replaceWith(old); }, { once: true });
  box.dataset.piVer = ver;
}

export function applyProductCardImages(root, rows, base) {
  const bySlug = new Map();
  for (const row of asRows(rows)) if (row?.slug) bySlug.set(row.slug, row);
  const hosts = [...(root.querySelectorAll?.('[data-product-image]') || [])];
  for (const host of hosts) {
    const slug = host.dataset.slug;
    if (!slug) continue;
    paint(host, bySlug.get(slug) || null, base);
  }
}

const boot = globalThis.window?.BOOKING_CONFIG?.url && globalThis.document?.querySelector?.('[data-product-image]');
if (boot) {
  let cache = null;
  let busy = false;
  const base = imageBase();
  const run = () => {
    if (busy || !cache || !base) return;
    busy = true;
    try { applyProductCardImages(document, cache, base); }
    finally { busy = false; }
  };
  rpc('public_product_images', {}).then((rows) => {
    cache = asRows(rows);
    run();
    new MutationObserver(run).observe(document.body, { childList: true, subtree: true });
  }).catch(() => { /* esirenderöity kuva jää */ });
}
