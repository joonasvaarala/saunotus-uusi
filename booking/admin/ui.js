// Pienet UI-apurit: DOM-rakentaja, muotoilut, ilmoitukset, dialogit. Ei riippuvuuksia.
import { icon } from './icons.js';
export const h = (tag, attrs, ...kids) => {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v; else if (k === 'text') el.textContent = v; else if (k === 'value') el.value = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v); else if (v === true) el.setAttribute(k, ''); else el.setAttribute(k, v);
  }
  for (const c of kids.flat(Infinity)) if (c != null && c !== false) el.append(c.nodeType ? c : document.createTextNode(c));
  return el;
};
const TZ = 'Europe/Helsinki';
const dtf = (o) => new Intl.DateTimeFormat('fi-FI', { timeZone: TZ, ...o });
export const fmtDate = (iso) => dtf({ weekday: 'short', day: 'numeric', month: 'numeric', year: 'numeric' }).format(new Date(iso));
export const fmtDay = (iso) => dtf({ weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' }).format(new Date(iso));
export const fmtTime = (iso) => dtf({ hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(new Date(iso)).replace('.', ':');
export const fmtDT = (iso) => (iso ? `${dtf({ day: 'numeric', month: 'numeric', year: 'numeric' }).format(new Date(iso))} ${fmtTime(iso)}` : '–');
export const money = (n) => (n == null ? '–' : new Intl.NumberFormat('fi-FI', { style: 'currency', currency: 'EUR' }).format(+n));
export const todayHel = () => new Date().toLocaleDateString('sv-SE', { timeZone: TZ });
export const addDays = (ds, n) => { const d = new Date(ds + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
// 'YYYY-MM-DDTHH:MM' (Helsingin aika) → UTC ISO-aikaleima
export function helsinkiIso(local) {
  const [d, t] = local.split('T');
  const base = new Date(`${d}T${t || '00:00'}:00Z`).getTime();
  const off = new Date(new Date(base).toLocaleString('en-US', { timeZone: TZ })) - new Date(new Date(base).toLocaleString('en-US', { timeZone: 'UTC' }));
  return new Date(base - off).toISOString();
}
export const dayStartIso = (ds) => helsinkiIso(`${ds}T00:00`);

export const STATUS = { confirmed: 'Vahvistettu', pending: 'Odottaa', cancelled: 'Peruttu', expired: 'Vanhentunut', completed: 'Toteutunut', no_show: 'Ei saapunut', draft: 'Luonnos' };
export const PAY = { unpaid: 'Maksamatta', pending: 'Maksu kesken', paid: 'Maksettu', partially_paid: 'Osittain maksettu', refunded: 'Palautettu', partially_refunded: 'Osittain palautettu', failed: 'Epäonnistui' };
export const badge = (kind, text) => h('span', { class: `badge ${kind}`, text });
export const statusBadge = (s) => badge(`st-${s}`, STATUS[s] || s);
export const payBadge = (s) => badge(`pay-${s}`, PAY[s] || s);
// Johku-tunniste: vain lähteelle 'johku' (admin_list_reservations / admin_day_view: source). Puuttuva tai 'native' → ei tunnistetta (defensiivinen: vanha kanta ei palauta kenttää).
export const isJohku = (r) => r?.source === 'johku';
export const sourceBadge = (r) => (isJohku(r) ? h('span', { class: 'badge src-johku', title: 'Tuotu Johku-varausjärjestelmästä', text: 'Johku' }) : null);

let toastTimer;
export function toast(msg, kind = 'ok') {
  let el = document.getElementById('toast');
  if (!el) { el = h('div', { id: 'toast', role: 'status', 'aria-live': 'polite' }); document.body.append(el); }
  el.className = `toast ${kind} show`; el.textContent = msg;
  clearTimeout(toastTimer); toastTimer = setTimeout(() => el.classList.remove('show'), kind === 'err' ? 6000 : 2800);
}
export const errMsg = (e) => e?.message || String(e);
// Kääri asynkroninen toiminto: nappi pois käytöstä, virhe näytetään ilmoituksena
export async function run(btn, fn) {
  if (btn) btn.disabled = true;
  try { return await fn(); } catch (e) { toast(errMsg(e), 'err'); } finally { if (btn) btn.disabled = false; }
}
export function dialog(title, content, { wide = false } = {}) {
  const d = h('dialog', { class: `dlg${wide ? ' wide' : ''}`, 'aria-labelledby': 'dlg-title' },
    h('div', { class: 'dlg-head' }, h('h2', { id: 'dlg-title', text: title }), h('button', { type: 'button', class: 'icon-btn', 'aria-label': 'Sulje', onclick: () => d.close() }, icon('close', 22))),
    h('div', { class: 'dlg-body' }, content));
  d.addEventListener('close', () => d.remove());
  document.body.append(d); d.showModal();
  return d;
}
export const field = (label, input, hint) => h('label', { class: 'fld' }, h('span', { text: label }), input, hint ? h('small', { text: hint }) : null);
export const empty = (text) => h('p', { class: 'empty', text });
