// Sama tiedosto neljässä paikassa (tavut täsmäävät, testi vertaa):
//   booking/shared/rich-text.js
//   booking/admin/rich-text.js
//   booking/shop/src/rich-text.js
//   booking/supabase/functions/_shared/rich-text.js
// Älä muokkaa kopioita erikseen.
//
// Kapea allowlist asiakkaalle näkyvälle tekstille (tuotekuvaus, tuoteviesti).
// Sallitut tagit: p, br, strong, b, em, i, h2, h3, ul, ol, li, a.
// a href vain http(s), mailto tai tarkka paikkamerkki {tilaus_linkki} / {linkki}.
// Ei tyylejä, skriptejä, kuvia eikä muita attribuutteja.
//
// Selain: Trix 2 puhdistaa liimauksen omalla DOMPurifylla. Tämä funktio on toinen,
// kapeampi kierros tallennuksessa ja renderöinnissä, ja sama kierros sähköpostissa
// (send-emails/templates.ts ei voi ottaa DOM-kirjastoa).

const ALLOW = new Set(['p', 'br', 'strong', 'b', 'em', 'i', 'h2', 'h3', 'ul', 'ol', 'li', 'a']);
const DROP_CONTENT = new Set(['script', 'style', 'iframe', 'object', 'embed', 'noscript', 'textarea', 'title', 'svg', 'math', 'template', 'head', 'frameset', 'noframes', 'noembed']);
const VOID = new Set(['br', 'img', 'hr', 'input', 'meta', 'link', 'source', 'wbr', 'col', 'base', 'area', 'track']);
const MAP = { div: 'p', h1: 'h2', h4: 'h3', h5: 'h3', h6: 'h3', blockquote: 'p' };
const BLOCK = new Set(['p', 'h2', 'h3', 'ul', 'ol', 'li']);
const INLINE = new Set(['a', 'strong', 'b', 'em', 'i']);
const RICH_RE = /<\s*\/?\s*(p|div|blockquote|br|strong|b|em|i|h[1-6]|ul|ol|li|a)\b/i;
const PLACEHOLDER_HREF = new Set(['{tilaus_linkki}', '{linkki}']);

const NAMED = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: '\u00a0' };

export function isRichHtml(value) {
  return RICH_RE.test(String(value ?? ''));
}

function decodeEntities(s) {
  return String(s ?? '').replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (all, ent) => {
    const e = ent.toLowerCase();
    if (Object.prototype.hasOwnProperty.call(NAMED, e)) return NAMED[e];
    if (e[0] !== '#') return all;
    const cp = e[1] === 'x' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
    if (!Number.isFinite(cp) || cp < 0 || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) return '';
    try { return String.fromCodePoint(cp); } catch { return ''; }
  });
}

function esc(s) {
  return String(s ?? '').replace(/[&<>]/g, (c) => (c === '&' ? '&amp;' : c === '<' ? '&lt;' : '&gt;'));
}

function escAttr(s) {
  return esc(s).replace(/"/g, '&quot;');
}

function attr(raw, name) {
  const re = new RegExp(`(?:^|\\s)${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s"'=<>\`]+))`, 'i');
  const m = re.exec(String(raw ?? ''));
  if (!m) return null;
  return m[1] ?? m[2] ?? m[3] ?? '';
}

function validHref(raw) {
  if (raw == null) return '';
  let h = decodeEntities(raw).replace(/[\u0000-\u0020\u007f]/g, '');
  if (PLACEHOLDER_HREF.has(h)) return h;
  const low = h.toLowerCase();
  if (low.startsWith('https://') || low.startsWith('http://')) {
    return /^https?:\/\/[^\s<>"']+$/i.test(h) ? h : '';
  }
  if (low.startsWith('mailto:')) {
    const addr = h.slice(7);
    return /^[^@\s<>"']+@[^@\s<>"']+\.[^@\s<>"']+$/.test(addr) ? `mailto:${addr}` : '';
  }
  return '';
}

function closeWhile(stack, out, pred) {
  while (stack.length && pred(stack[stack.length - 1])) out.push(`</${stack.pop()}>`);
}

/** Allowlist. Tyhjä editori (`<p><br></p>`) ja pelkkä vaarallinen merkintä palautuvat tyhjänä, jos näkyvää tekstiä ei jää. */
export function sanitizeRich(input) {
  const s = String(input ?? '');
  const out = [];
  const stack = [];
  let i = 0;
  let skip = 0;

  const pushText = (t) => { if (!skip && t) out.push(esc(decodeEntities(t))); };

  while (i < s.length) {
    if (s[i] !== '<') {
      const j = s.indexOf('<', i);
      const end = j < 0 ? s.length : j;
      pushText(s.slice(i, end));
      i = end;
      continue;
    }
    if (s.startsWith('<!--', i)) {
      const end = s.indexOf('-->', i + 4);
      i = end < 0 ? s.length : end + 3;
      continue;
    }
    if (s.startsWith('<!', i) || s.startsWith('<?', i)) {
      const end = s.indexOf('>', i + 2);
      i = end < 0 ? s.length : end + 1;
      continue;
    }
    const close = s[i + 1] === '/';
    const start = i + (close ? 2 : 1);
    const m = /^([a-zA-Z][a-zA-Z0-9]*)/.exec(s.slice(start));
    if (!m) {
      pushText('<');
      i += 1;
      continue;
    }
    const rawName = m[1].toLowerCase();
    let k = start + m[1].length;
    let quote = '';
    while (k < s.length) {
      const c = s[k];
      if (quote) { if (c === quote) quote = ''; k += 1; continue; }
      if (c === '"' || c === "'") { quote = c; k += 1; continue; }
      if (c === '>') break;
      k += 1;
    }
    const rawAttrs = s.slice(start + m[1].length, k);
    const self = /\/\s*$/.test(rawAttrs) || VOID.has(rawName);
    i = k < s.length ? k + 1 : s.length;

    if (skip) {
      if (!close && DROP_CONTENT.has(rawName) && !self) skip += 1;
      else if (close && DROP_CONTENT.has(rawName)) skip -= 1;
      continue;
    }
    if (!close && DROP_CONTENT.has(rawName)) {
      if (!self) skip += 1;
      continue;
    }
    if (close && DROP_CONTENT.has(rawName)) continue;

    const name = MAP[rawName] || rawName;
    if (close) {
      const idx = stack.lastIndexOf(name);
      if (idx < 0) continue;
      while (stack.length > idx) out.push(`</${stack.pop()}>`);
      continue;
    }
    if (!ALLOW.has(name)) continue;

    if (name === 'br') { out.push('<br>'); continue; }

    closeWhile(stack, out, (t) => INLINE.has(t) && (BLOCK.has(name) || t === 'a' && name === 'a'));
    if (name === 'li') {
      closeWhile(stack, out, (t) => t === 'li' || INLINE.has(t));
    } else if (name === 'ul' || name === 'ol') {
      closeWhile(stack, out, (t) => t === 'p' || t === 'h2' || t === 'h3');
    } else if (name === 'p' || name === 'h2' || name === 'h3') {
      closeWhile(stack, out, (t) => t === 'p' || t === 'h2' || t === 'h3');
    }

    if (name === 'a') {
      const href = validHref(attr(rawAttrs, 'href'));
      if (!href) continue;
      out.push(`<a href="${escAttr(href)}">`);
      if (!self) stack.push('a');
      continue;
    }
    out.push(`<${name}>`);
    if (!self) stack.push(name);
  }
  while (stack.length) out.push(`</${stack.pop()}>`);
  let html = out.join('').replace(/<(p|h2|h3|li|strong|b|em|i|a)><\/\1>/g, '');
  const visible = decodeEntities(html.replace(/<br>/g, '').replace(/<[^>]+>/g, '')).replace(/\u00a0/g, ' ').trim();
  if (!visible) return '';
  return html;
}

/** Tallennukseen: rikas HTML puhdistetaan, vanha pelkkä teksti säilyy tavulleen (paitsi trim). */
export function normalizeStored(input) {
  const t = String(input ?? '').trim();
  if (!t) return '';
  if (!isRichHtml(t)) return t;
  return sanitizeRich(t);
}

/** Vanha rivinvaihdollinen teksti editoriin. Rikas HTML puhdistetaan sellaisenaan. */
export function plainToEditorHtml(input) {
  const t = String(input ?? '');
  if (!t.trim()) return '';
  if (isRichHtml(t)) return sanitizeRich(t);
  return t.replace(/\r\n/g, '\n').split(/\n{2,}/).map((p) => `<p>${esc(p).replace(/\n/g, '<br>')}</p>`).join('');
}

/** Näkyvä teksti korteille ja tiivistelmiin. Pelkkä teksti palautuu muuttamatta. */
export function toPlainText(input) {
  const t = String(input ?? '');
  if (!isRichHtml(t)) return t;
  const clean = sanitizeRich(t);
  return decodeEntities(clean.replace(/<br>/g, '\n').replace(/<\/(p|h2|h3|li|ul|ol)>/g, '\n').replace(/<[^>]+>/g, ''))
    .replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
}

function tokens(html) {
  const out = [];
  const re = /<(\/?)([a-z0-9]+)([^>]*)>|([^<]+)/g;
  let m;
  while ((m = re.exec(html))) {
    if (m[4] != null) out.push({ kind: 'text', v: decodeEntities(m[4]) });
    else out.push({ kind: m[1] ? 'end' : 'start', n: m[2], a: m[3] || '' });
  }
  return out;
}

/** Sähköpostin tekstiversio: otsikot, luettelot ja linkit luettavina. Pelkkä teksti säilyy. */
export function richToText(input) {
  const raw = String(input ?? '');
  if (!isRichHtml(raw)) return raw;
  const blocks = [];
  let line = '';
  let list = null;
  const kinds = [];
  const counts = [];
  let link = null;
  let linkText = '';
  const pushLine = (prefix = '') => {
    const s = (prefix + line).replace(/[ \t]{2,}/g, ' ').trim();
    line = '';
    if (!s) return;
    if (list) list.push(s);
    else blocks.push(s);
  };
  const closeList = () => {
    if (list && list.length) blocks.push(list.join('\n'));
    list = null;
  };
  for (const tok of tokens(sanitizeRich(raw))) {
    if (tok.kind === 'text') {
      const v = tok.v.replace(/\s+/g, ' ');
      if (link) linkText += v;
      else line += v;
      continue;
    }
    if (tok.kind === 'start') {
      if (tok.n === 'a') {
        const hm = /href="([^"]*)"/.exec(tok.a);
        link = hm ? decodeEntities(hm[1]) : '';
        linkText = '';
      } else if (tok.n === 'br') {
        if (link) linkText += ' ';
        else pushLine();
      } else if (tok.n === 'ul' || tok.n === 'ol') {
        pushLine();
        if (!list) list = [];
        kinds.push(tok.n);
        if (tok.n === 'ol') counts.push(0);
      } else if (tok.n === 'p' || tok.n === 'h2' || tok.n === 'h3' || tok.n === 'li') {
        pushLine();
      }
      continue;
    }
    if (tok.n === 'a') {
      const label = linkText.replace(/\s+/g, ' ').trim();
      const href = link || '';
      const shown = href && href !== label ? `${label} (${href})` : label;
      line += shown;
      link = null;
      linkText = '';
    } else if (tok.n === 'li') {
      let prefix = '• ';
      if (kinds[kinds.length - 1] === 'ol') {
        counts[counts.length - 1] += 1;
        prefix = `${counts[counts.length - 1]}. `;
      }
      pushLine(prefix);
    } else if (tok.n === 'p' || tok.n === 'h2' || tok.n === 'h3') {
      pushLine();
    } else if (tok.n === 'ul') {
      kinds.pop();
      if (!kinds.length) closeList();
    } else if (tok.n === 'ol') {
      kinds.pop();
      counts.pop();
      if (!kinds.length) closeList();
    }
  }
  pushLine();
  closeList();
  return blocks.join('\n\n').replace(/\n{3,}/g, '\n\n').trim();
}

/** Sähköpostin HTML: allowlist + inline-tyylit. Pelkälle tekstille null (kutsuja escapoi kuten ennen). */
export function emailHtml(input, styles = {}) {
  const raw = String(input ?? '');
  if (!isRichHtml(raw)) return null;
  const html = sanitizeRich(raw);
  const styleOf = (tag) => {
    const v = styles[tag];
    if (!v) return '';
    return ` style="${String(v).replace(/"/g, '')}"`;
  };
  return html.replace(/<([a-z0-9]+)(\s[^>]*)?>/g, (full, tag, attrs = '') => {
    if (tag === 'br') return '<br>';
    if (tag === 'a') return `<a${styleOf('a')}${attrs}>`;
    return `<${tag}${styleOf(tag)}>`;
  });
}
