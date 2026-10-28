// Viikko-ohjelma (etusivu + saunavuorot). <ol class="week" data-quiet-week> saa tekstit ja tuotenimet
// rakennusvaiheessa (src/quiet-week.mjs). Selain hakee:
//   public_availability(26) — vapaat Savusaunan jälkilöylyt näkyville päiville (tänään + 6)
//   public_quiet_offers — hiljaisen ajan ale samalle vuorolle, jos palvelin sellaisen antaa
// Varattu, mennyt tai virheellinen vuoro ei näy. Jos kumpikaan haku ei onnistu, ohjelma jää ennalleen.
// Ei innerHTML:ää: kaikki solmut createElement + textContent.
import { rpc } from './sb.js';
import { quietByWeekday, addDaysIso, fillText, pctText, validOffer, bookablePrivateSlots, offerForSlot, weekdayIso, JALKIL_ID } from './quiet-offers-logic.js';

const TZ = 'Europe/Helsinki';
export function decorateWeek(list, offers, { lang = 'fi', shopHref = '', today, slots, now } = {}) {
  const d = list.dataset;
  let products = {};
  try { products = JSON.parse(d.quietProducts || '{}'); } catch { products = {}; }
  const money = (n) => new Intl.NumberFormat(lang === 'fi' ? 'fi-FI' : 'en-FI', { style: 'currency', currency: 'EUR', minimumFractionDigits: Number.isInteger(+n) ? 0 : 2 }).format(+n);
  const time = (iso) => new Intl.DateTimeFormat(lang === 'fi' ? 'fi-FI' : 'en-GB', { timeZone: TZ, hour: 'numeric', minute: '2-digit', hourCycle: 'h23' }).format(new Date(iso)).replace('.', ':').replace(/:00$/, '');
  const el = (tag, cls, text) => { const n = list.ownerDocument.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; };
  const startMin = (txt) => { const m = /^(\d{1,2})(?:[:.](\d\d))?/.exec(String(txt || '').trim()); return m ? +m[1] * 60 + +(m[2] || 0) : null; };
  const place = (ul, li, label) => {
    const mine = startMin(label);
    const next = mine == null ? null : [...ul.children].find((x) => { const v = startMin(x.querySelector('.t')?.textContent); return v != null && v > mine; });
    if (next) ul.insertBefore(li, next); else ul.append(li);
  };
  const dayList = (wd) => {
    const day = list.querySelector(`:scope > li[data-wd="${wd}"]`);
    if (!day) return null;
    let ul = day.querySelector(':scope > ul.sl');
    if (!ul) { ul = el('ul', 'sl'); day.querySelector(':scope > h3')?.after(ul); }
    return { day, ul };
  };
  let added = 0, discounted = 0;
  const useSlots = Array.isArray(slots);
  const byDay = quietByWeekday((offers || []).filter((o) => validOffer(o) && products[o.product_id] && !(useSlots && +o.product_id === JALKIL_ID)), today);
  for (const [wd, rows] of byDay) {
    const host = dayList(wd);
    if (!host) continue;
    for (const o of rows) {
      const key = `${o.product_id}|${o.rule_id}|${o.session_date}`;
      if (host.day.querySelector(`:scope li[data-slot-key="${key}"]`)) continue;
      const p = products[o.product_id], vars = { pct: pctText(o.percent, lang), was: money(o.base_price), now: money(o.discounted_price) };
      const li = el('li', 'sess quiet');
      li.dataset.testid = 'site-quiet-session';
      li.dataset.slotKey = key;
      const price = el('span', 'qp');
      price.setAttribute('aria-hidden', 'true');
      price.append(el('span', 'qb', fillText(d.quietBadge, vars)), ' ', el('del', '', vars.was), ' ', el('strong', '', vars.now));
      const a = el('a', 'bk');
      a.href = `${shopHref}#/tuote/${encodeURIComponent(p.s)}/${o.session_date}`;
      a.append(el('span', 'bk-l', d.quietReserve || ''), el('span', 'sr', ` – ${p.n}, ${fillText(d.quietSr, vars)}`));
      li.append(el('span', 't', `${time(o.starts_at)}–${time(o.ends_at)}`), el('span', 'n', p.n), price, a);
      place(host.ul, li, time(o.starts_at));
      added++; discounted++;
    }
    host.day.classList.remove('off');
  }
  if (useSlots) {
    for (const slot of bookablePrivateSlots(slots, { today, now: now ?? Date.now(), productId: JALKIL_ID })) {
      const p = products[slot.product_id];
      const wd = weekdayIso(slot.session_date);
      const host = p && wd ? dayList(wd) : null;
      if (!host) continue;
      const key = `${slot.product_id}|${slot.rule_id}|${slot.session_date}`;
      if (host.day.querySelector(`:scope li[data-slot-key="${key}"]`)) continue;
      const offer = offerForSlot(offers, slot);
      const was = money(offer ? offer.base_price : slot.base_price);
      const nowPrice = money(offer ? offer.discounted_price : slot.base_price);
      const vars = offer ? { pct: pctText(offer.percent, lang), was, now: nowPrice } : { now: nowPrice };
      const li = el('li', 'sess quiet');
      li.dataset.testid = offer ? 'site-quiet-session' : 'site-jalkiloyly';
      if (offer) li.dataset.quiet = '1';
      li.dataset.slotKey = key;
      const price = el('span', 'qp');
      price.setAttribute('aria-hidden', 'true');
      if (offer) price.append(el('span', 'qb', fillText(d.quietBadge, vars)), ' ', el('del', '', vars.was), ' ', el('strong', '', vars.now));
      else price.append(el('strong', '', nowPrice));
      const a = el('a', 'bk');
      a.href = `${shopHref}#/varaa/${encodeURIComponent(slot.rule_id)}/${slot.session_date}/${JALKIL_ID}`;
      const sr = offer ? fillText(d.quietSr, vars) : nowPrice;
      a.append(el('span', 'bk-l', d.quietReserve || ''), el('span', 'sr', ` – ${p.n}, ${sr}`));
      li.append(el('span', 't', `${time(slot.starts_at)}–${time(slot.ends_at)}`), el('span', 'n', p.n), price, a);
      place(host.ul, li, time(slot.starts_at));
      added++; if (offer) discounted++;
      host.day.classList.remove('off');
    }
  }
  if (discounted && d.quietNote && !list.nextElementSibling?.classList.contains('quiet-week-note')) list.after(el('p', 'quiet-week-note', d.quietNote));
  return added;
}

const cfg = globalThis.window?.BOOKING_QUIET;
if (cfg && globalThis.document && window.BOOKING_CONFIG?.url) {
  const lists = [...document.querySelectorAll('ol.week[data-quiet-week]')];
  if (lists.length) {
    const today = new Date().toLocaleDateString('sv-SE', { timeZone: TZ });
    const from = today, to = addDaysIso(today, 6);
    Promise.all([
      rpc('public_quiet_offers', { p_from: from, p_to: to, p_audience: 'consumer' }).then((rows) => (Array.isArray(rows) ? rows : [])).catch(() => null),
      rpc('public_availability', { p_product_id: JALKIL_ID, p_from: from, p_to: to }).then((rows) => (Array.isArray(rows) ? rows : [])).catch(() => null),
    ]).then(([offers, slots]) => {
      if (offers == null && slots == null) return;
      const opt = { lang: cfg.lang, shopHref: cfg.shopHref, today, now: Date.now() };
      if (slots != null) opt.slots = slots;
      for (const l of lists) decorateWeek(l, offers || [], opt);
    }).catch(() => { /* viikko-ohjelma ennallaan */ });
  }
}
