// booking_162: hiljaisten aikojen ale sivuston viikko-ohjelmassa (etusivu + saunavuorot). Progressiivinen lisä: <ol class="week" data-quiet-week>
// saa tekstit ja tuotenimet rakennusvaiheessa (src/quiet-week.mjs); tämä hakee public_quiet_offers (seuraavat 7 päivää) ja lisää alennetut
// vuorot oikean viikonpäivän alle. Pois päältä (palvelin palauttaa []), virhe tai puuttuva config → viikko-ohjelma ei muutu.
// Ei innerHTML:ää: kaikki solmut createElement + textContent. Pohja: GPT-paketin public/js/quiet-offers.js, sovitettu kaupan dist-rakenteeseen.
import { rpc } from './sb.js';
import { quietByWeekday, addDaysIso, fillText, pctText, validOffer } from './quiet-offers-logic.js';

const TZ = 'Europe/Helsinki';
export function decorateWeek(list, offers, { lang = 'fi', shopHref = '', today } = {}) {
  const d = list.dataset;
  let products = {};
  try { products = JSON.parse(d.quietProducts || '{}'); } catch { products = {}; }
  const money = (n) => new Intl.NumberFormat(lang === 'fi' ? 'fi-FI' : 'en-FI', { style: 'currency', currency: 'EUR', minimumFractionDigits: Number.isInteger(+n) ? 0 : 2 }).format(+n);
  const time = (iso) => new Intl.DateTimeFormat(lang === 'fi' ? 'fi-FI' : 'en-GB', { timeZone: TZ, hour: 'numeric', minute: '2-digit', hourCycle: 'h23' }).format(new Date(iso)).replace('.', ':').replace(/:00$/, '');
  const el = (tag, cls, text) => { const n = list.ownerDocument.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; };
  const byDay = quietByWeekday((offers || []).filter((o) => validOffer(o) && products[o.product_id]), today);
  let added = 0;
  for (const [wd, rows] of byDay) {
    const day = list.querySelector(`:scope > li[data-wd="${wd}"]`);
    if (!day) continue;
    let ul = day.querySelector(':scope > ul.sl');
    if (!ul) { ul = el('ul', 'sl'); day.querySelector(':scope > h3')?.after(ul); }
    for (const o of rows) {
      const p = products[o.product_id], vars = { pct: pctText(o.percent, lang), was: money(o.base_price), now: money(o.discounted_price) };
      const li = el('li', 'sess quiet');
      li.dataset.testid = 'site-quiet-session';
      const price = el('span', 'qp');
      price.setAttribute('aria-hidden', 'true');
      price.append(el('span', 'qb', fillText(d.quietBadge, vars)), ' ', el('del', '', vars.was), ' ', el('strong', '', vars.now));
      const a = el('a', 'bk');
      a.href = `${shopHref}#/tuote/${encodeURIComponent(p.s)}/${o.session_date}`;
      a.append(el('span', 'bk-l', d.quietReserve || ''), el('span', 'sr', ` – ${p.n}, ${fillText(d.quietSr, vars)}`));
      li.append(el('span', 't', `${time(o.starts_at)}–${time(o.ends_at)}`), el('span', 'n', p.n), price, a);
      // aikajärjestykseen olemassa olevien vuorojen (span.t "16–19" / "16:30–19") kanssa
      const startMin = (txt) => { const m = /^(\d{1,2})(?:[:.](\d\d))?/.exec(String(txt || '').trim()); return m ? +m[1] * 60 + +(m[2] || 0) : null; };
      const mine = startMin(time(o.starts_at));
      const next = mine == null ? null : [...ul.children].find((x) => { const v = startMin(x.querySelector('.t')?.textContent); return v != null && v > mine; });
      if (next) ul.insertBefore(li, next); else ul.append(li);
      added++;
    }
    day.classList.remove('off');
  }
  if (added && d.quietNote && !list.nextElementSibling?.classList.contains('quiet-week-note')) list.after(el('p', 'quiet-week-note', d.quietNote));
  return added;
}

const cfg = globalThis.window?.BOOKING_QUIET;
if (cfg && globalThis.document && window.BOOKING_CONFIG?.url) {
  const lists = [...document.querySelectorAll('ol.week[data-quiet-week]')];
  if (lists.length) {
    const today = new Date().toLocaleDateString('sv-SE', { timeZone: TZ });
    rpc('public_quiet_offers', { p_from: today, p_to: addDaysIso(today, 6), p_audience: 'consumer' })
      .then((rows) => { for (const l of lists) decorateWeek(l, Array.isArray(rows) ? rows : [], { lang: cfg.lang, shopHref: cfg.shopHref, today }); })
      .catch(() => { /* verkkovirhe tai vanha backend: viikko-ohjelma ennallaan */ });
  }
}
