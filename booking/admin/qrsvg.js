// QR-matriisi paikallisesti (Kazuhiko Arase, qrcode-generator, MIT). Ei verkkokutsua.
// typeNumber 0 valitsee version automaattisesti; virheenkorjaus M. Piirto on SVG-rectejä, ei innerHTML:ää.
import { qrcode } from './qrcode-generator.js';

export function qrMatrix(text) {
  const qr = qrcode(0, 'M');
  qr.addData(String(text));
  qr.make();
  const n = qr.getModuleCount();
  const rows = [];
  for (let r = 0; r < n; r++) {
    let row = '';
    for (let c = 0; c < n; c++) row += qr.isDark(r, c) ? '1' : '0';
    rows.push(row);
  }
  return rows;
}

const NS = 'http://www.w3.org/2000/svg';

export function qrSvgElement(text, { size = 280, label = '' } = {}) {
  const rows = qrMatrix(text);
  const n = rows.length;
  const quiet = 4;
  const dim = n + quiet * 2;
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('viewBox', `0 0 ${dim} ${dim}`);
  svg.setAttribute('width', String(size));
  svg.setAttribute('height', String(size));
  svg.setAttribute('role', 'img');
  if (label) svg.setAttribute('aria-label', label);
  const bg = document.createElementNS(NS, 'rect');
  bg.setAttribute('x', '0');
  bg.setAttribute('y', '0');
  bg.setAttribute('width', String(dim));
  bg.setAttribute('height', String(dim));
  bg.setAttribute('fill', '#ffffff');
  svg.append(bg);
  for (let r = 0; r < n; r++) {
    for (let c = 0; c < n; c++) {
      if (rows[r][c] !== '1') continue;
      const rect = document.createElementNS(NS, 'rect');
      rect.setAttribute('x', String(c + quiet));
      rect.setAttribute('y', String(r + quiet));
      rect.setAttribute('width', '1');
      rect.setAttribute('height', '1');
      rect.setAttribute('fill', '#111111');
      svg.append(rect);
    }
  }
  return svg;
}
