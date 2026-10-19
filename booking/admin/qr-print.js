// QR-tulosteen puhdas malli. Osoite on lukittu polku /juomat/?laite=<koodi>. Ei uutta selainikkunaa eikä ulkoista palvelua.
import { qrMatrix, qrSvgMarkup } from './qrsvg.js';

export function drinksQrUrl(base, code) {
  const path = `/juomat/?laite=${code}`;
  const b = String(base || '').replace(/\/$/, '');
  if (/^https?:\/\//i.test(String(code || ''))) return String(code);
  return b ? b + path : path;
}

function esc(s) {
  return String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

/** Sijainti tarrassa. null, undefined, false ja pelkkä tyhjä tila eivät tuota riviä. */
export function stickerPlace(value) {
  if (value == null || value === false) return '';
  return String(value).trim();
}

/**
 * Tulostusarkin HTML. items: { name, priceText, url, label }.
 * Jokainen kortti sisältää SVG-QR:n, nimen, hinnan ja ohjeen. Tyhjä lista ei ole tyhjä sivu: ohje jää näkyviin.
 */
export function printSheetHtml(items, { scan = 'Skannaa ja osta', empty = '' } = {}) {
  const cards = (items || []).map((it) => {
    const url = String(it.url || '');
    const svg = url ? qrSvgMarkup(url, { size: 280, label: it.name || '' }) : '';
    const place = stickerPlace(it.label);
    const where = place ? `<p class="qr-where">${esc(place)}</p>` : '';
    return `<article class="qr-card" data-url="${esc(url)}"><h2>${esc(it.name || '')}</h2><p class="qr-price">${esc(it.priceText || '')}</p>${where}${svg}<p class="qr-scan">${esc(scan)}</p></article>`;
  });
  const body = cards.length ? cards.join('') : `<p class="qr-empty">${esc(empty)}</p>`;
  return `<section class="qr-sheet" data-testid="qr-sheet">${body}</section>`;
}

/** Yksi SVG-tiedosto usealle koodille. Kelpaa lataukseen (ei HTML-sivua). */
export function printSheetSvg(items, { scan = 'Skannaa ja osta' } = {}) {
  const list = items || [];
  const cardW = 400;
  const cardH = 520;
  const cols = list.length > 1 ? 2 : 1;
  const rows = Math.max(1, Math.ceil(list.length / cols) || 1);
  const width = cols * cardW;
  const height = rows * cardH;
  const parts = [`<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">`, `<rect width="${width}" height="${height}" fill="#ffffff"/>`];
  list.forEach((it, i) => {
    const x = (i % cols) * cardW;
    const y = Math.floor(i / cols) * cardH;
    const url = String(it.url || '');
    if (url) {
      const inner = qrSvgMarkup(url, { size: 280, label: it.name || '' }).replace('<svg ', `<svg x="${x + 60}" y="${y + 88}" `);
      parts.push(inner);
    }
    parts.push(`<text x="${x + 200}" y="${y + 36}" text-anchor="middle" font-size="22" font-family="sans-serif">${esc(it.name || '')}</text>`);
    parts.push(`<text x="${x + 200}" y="${y + 64}" text-anchor="middle" font-size="18" font-family="sans-serif">${esc(it.priceText || '')}</text>`);
    const place = stickerPlace(it.label);
    if (place) parts.push(`<text x="${x + 200}" y="${y + 84}" text-anchor="middle" font-size="14" font-family="sans-serif">${esc(place)}</text>`);
    parts.push(`<text x="${x + 200}" y="${y + 400}" text-anchor="middle" font-size="16" font-family="sans-serif">${esc(scan)}</text>`);
  });
  parts.push('</svg>');
  return parts.join('');
}

export function sheetHasQr(html, url) {
  const raw = String(html || '');
  if (!raw.includes('<svg') || !raw.includes('<rect')) return false;
  if (url && !raw.includes(url)) return false;
  const dark = url ? qrMatrix(url).join('').split('').filter((c) => c === '1').length : 0;
  const rects = (raw.match(/<rect /g) || []).length;
  return dark > 0 && rects >= dark + 1;
}
