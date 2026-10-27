// Markdown-osajoukko (sopimus §16.2). Renderöi TÄSMÄLLEEN nämä; kaikki muu tulostetaan tekstinä escapattuna (ei HTML-ohitusta).
//   ## ja ### (H2/H3; yksittäinen # → H2, koska H1 tulee artikkelin otsikosta), kappaleet (rivinvaihto → <br>), **lihavointi**, *kursivointi*,
//   > lainaus, - luettelo, 1. luettelo, --- vaakaviiva, [teksti](osoite), ![alt](img:ID) omalla rivillään, :::cta ... ::: ja :::author ... ::: -lohkot.
//   H2 "Usein kysyttyä" + sen jälkeiset H3-kysymykset palautetaan myös faqs-taulukkona (FAQPage-JSON-LD).
// Sallitut linkit: https://, http://, mailto:, /suhteellinen (ei //), #ankkuri. Muut (javascript:, data:, …) tulostuvat tekstinä.
import { e } from '../lib.mjs';

const SAFE_HREF = /^(https?:\/\/[^\s]+|mailto:[^\s]+|\/(?!\/)[^\s]*|#[^\s]*)$/i;
const LINK_RE = /(!?)\[([^\]]*)\]\(\s*([^)\s]*)\s*\)/g;
const BLOCK_START = /^(#{1,3}\s|---+\s*$|>\s?|[-]\s+|\d+\.\s+|:::cta\s*$|:::author\s*$|!\[[^\]]*\]\(img:\d+\)\s*$)/;

export const slugifyHeading = (s) => String(s).toLowerCase().normalize('NFKD').replace(/[\u0300-\u036f]/g, '').replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'osio';

function emphasis(raw) {
  return e(raw)
    .replace(/\*\*(?=\S)([^*]+?)(?<=\S)\*\*/g, '<strong>$1</strong>')
    .replace(/(?<![*\w])\*(?=\S)([^*]+?)(?<=\S)\*(?![*\w])/g, '<em>$1</em>');
}
export const isSafeHref = (u) => SAFE_HREF.test(u);

// opts.resolveHref(url) muuntaa suhteellisen polun sivuston osoitteeksi (BASE-etuliite)
export function inline(text, opts = {}) {
  const resolve = opts.resolveHref || ((u) => u);
  let out = '', last = 0, m;
  LINK_RE.lastIndex = 0;
  while ((m = LINK_RE.exec(text))) {
    out += emphasis(text.slice(last, m.index));
    last = m.index + m[0].length;
    const [raw, bang, label, url] = m;
    if (bang || !isSafeHref(url)) { out += e(raw); continue; }   // kuva rivin keskellä tai kielletty osoite → tekstinä
    const ext = /^https?:/i.test(url);
    out += `<a href="${e(ext || url.startsWith('#') || /^mailto:/i.test(url) ? url : resolve(url))}"${ext ? ' rel="noopener"' : ''}>${emphasis(label) || e(url)}</a>`;
  }
  return out + emphasis(text.slice(last));
}

function ctaBlock(lines, opts) {
  let title = '', btn = null; const text = [];
  for (const l of lines.map((x) => x.trim()).filter(Boolean)) {
    const b = /^\*\*(.+)\*\*$/.exec(l), k = /^\[([^\]]+)\]\(\s*([^)\s]+)\s*\)$/.exec(l);
    if (b && !title) title = b[1];
    else if (k && !btn && isSafeHref(k[2])) btn = k;
    else text.push(l);
  }
  const href = btn && (/^\//.test(btn[2]) ? (opts.resolveHref || ((u) => u))(btn[2]) : btn[2]);
  return `<aside class="article-cta">${title ? `<p class="cta-title">${emphasis(title)}</p>` : ''}${text.length ? `<p>${text.map((x) => inline(x, opts)).join('<br>')}</p>` : ''}${btn ? `<p><a class="btn gold" href="${e(href)}"${/^https?:/i.test(btn[2]) ? ' rel="noopener"' : ''}>${emphasis(btn[1])}</a></p>` : ''}</aside>`;
}

function authorBlock(lines, opts, used) {
  let name = ''; const text = [];
  for (const l of lines.map((x) => x.trim()).filter(Boolean)) {
    const b = /^\*\*(.+)\*\*$/.exec(l);
    if (b && !name) name = b[1];
    else text.push(l);
  }
  let id = slugifyHeading(name || 'kirjoittaja'), n = 2; const base = id;
  while (used?.has(id)) id = `${base}-${n++}`;
  used?.add(id);
  return `<aside class="article-author">${name ? `<h2 id="${id}">${emphasis(name)}</h2>` : ''}${text.map((x) => `<p>${inline(x, opts)}</p>`).join('')}</aside>`;
}

/** Näkyvä teksti JSON-LD:hen: linkin nimi, ei osoitetta, ei merkintöjä. */
export const plainInline = (s) => String(s).replace(/\[([^\]]*)\]\([^)]*\)/g, '$1').replace(/[*_]+/g, '').replace(/\s+/g, ' ').trim();

function takeFenced(lines, i) {
  const body = []; let j = i + 1;
  while (j < lines.length && !/^:::\s*$/.test(lines[j])) body.push(lines[j++]);
  return j < lines.length ? { body, next: j + 1 } : null;
}

/** @returns {{html:string, ctaCount:number, headings:{level:number,id:string,text:string}[], faqs:{question:string,answer:string}[], warnings:string[]}} */
export function renderMarkdown(md, opts = {}) {
  const lines = String(md ?? '').replace(/\r\n?/g, '\n').split('\n');
  const out = [], warnings = [], headings = [], faqs = [], used = new Set();
  let ctaCount = 0, i = 0, inFaq = false, current = null;
  const images = opts.images || new Map();
  const closeQ = () => {
    if (current && current.answer.length) faqs.push({ question: current.question, answer: plainInline(current.answer.join(' ')) });
    current = null;
  };
  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) { i++; continue; }
    let m;
    if (/^:::(cta|author)\s*$/.test(line)) {
      const kind = line.trim() === ':::author' ? 'author' : 'cta';
      const fence = takeFenced(lines, i);
      if (fence) {
        closeQ(); inFaq = false;
        out.push(kind === 'author' ? authorBlock(fence.body, opts, used) : ctaBlock(fence.body, opts));
        if (kind === 'cta') ctaCount++;
        i = fence.next; continue;
      }
      // sulkeva ::: puuttuu → tavallista tekstiä
    }
    if ((m = /^(#{1,3})\s+(.*?)\s*#*\s*$/.exec(line)) && m[2]) {
      const level = m[1].length === 3 ? 3 : 2;
      let id = slugifyHeading(m[2]), n = 2; const base = id;
      while (used.has(id)) id = `${base}-${n++}`;
      used.add(id); headings.push({ level, id, text: m[2] });
      if (level === 2) {
        closeQ();
        inFaq = plainInline(m[2]).toLowerCase() === 'usein kysyttyä';
      } else if (inFaq) {
        closeQ();
        current = { question: plainInline(m[2]), answer: [] };
      }
      out.push(`<h${level} id="${id}">${inline(m[2], opts)}</h${level}>`); i++; continue;
    }
    if (/^---+\s*$/.test(line)) { out.push('<hr>'); i++; continue; }
    if ((m = /^!\[[^\]]*\]\(img:(\d+)\)\s*$/.exec(line))) {
      const img = images.get(Number(m[1]));
      if (img && opts.imageHtml) out.push(opts.imageHtml(img)); else warnings.push(`img:${m[1]} puuttuu artikkelin kuvista`);
      i++; continue;
    }
    if (/^>\s?/.test(line)) {
      const q = []; while (i < lines.length && /^>\s?/.test(lines[i])) q.push(lines[i++].replace(/^>\s?/, ''));
      const paras = q.join('\n').split(/\n\s*\n/).filter((x) => x.trim());
      out.push(`<blockquote>${paras.map((p) => `<p>${p.split('\n').map((x) => inline(x, opts)).join('<br>')}</p>`).join('')}</blockquote>`); continue;
    }
    if (/^-\s+/.test(line)) {
      const it = []; while (i < lines.length && /^-\s+/.test(lines[i])) it.push(lines[i++].replace(/^-\s+/, ''));
      out.push(`<ul>${it.map((x) => `<li>${inline(x, opts)}</li>`).join('')}</ul>`); continue;
    }
    if (/^\d+\.\s+/.test(line)) {
      const it = []; while (i < lines.length && /^\d+\.\s+/.test(lines[i])) it.push(lines[i++].replace(/^\d+\.\s+/, ''));
      out.push(`<ol>${it.map((x) => `<li>${inline(x, opts)}</li>`).join('')}</ol>`); continue;
    }
    const p = [line];
    i++;
    while (i < lines.length && lines[i].trim() && !BLOCK_START.test(lines[i])) p.push(lines[i++]);
    if (current) current.answer.push(p.join(' '));
    out.push(`<p>${p.map((x) => inline(x.trim(), opts)).join('<br>')}</p>`);
  }
  closeQ();
  return { html: out.join('\n'), ctaCount, headings, faqs, warnings };
}
