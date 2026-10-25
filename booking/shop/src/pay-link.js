// Maksulinkkisivu /maksa/?p=<link_token> (EN /en/pay/?p=…). Sähköpostin maksulinkit (settings.payment_link_path), hallinnan ja pikakassan linkit.
// Painike kutsuu vismapay-start {link_token} (sama edge kuin tilaussivun Visma-painike) ja ohjaa Visma Payn sivulle. Maksua ei avata ilman painallusta
// (sähköpostin linkkiesikatselu ei luo maksua). Virheet (vanhentunut, maksettu, virheellinen) FI/EN.
// booking_177b: latauksessa VAIN LUKU -kutsu rpc public_payment_link_info(p_token) → yhteenveto ennen painiketta (summa, tilausnumero, rivit pvm/klo,
// voimassaolo) tai selkeä tila (maksettu / vanhentunut / korvattu / ei löydy), jolloin painike poistetaan. Jos RPC puuttuu (404/PGRST202), verkko
// pettää tai nopeusraja täyttyy → sivu toimii kuten booking_177:ssä (yleinen kortti + painike; vismapay-start tarkistaa tilan painettaessa).
import { functionUrl, rpc } from './sb.js';
import { h } from './gift-ui.js';
import { createVismapayApi } from './vismapay-api.js';
import { safeVismaRedirect } from './vismapay-logic.js';
import { PLT, plt } from './pay-link-texts.js';
import { linkTokenFrom, classifyLinkError, switchHref, normLinkInfo, linkInfoView, fmtDate } from './pay-link-logic.js';
import { applyShopTexts } from './site-texts.js';

export function payLinkView({ L, token, api, loadInfo = null, phone = '', phoneTel = '', navigate = (u) => location.assign(u), money = (n) => String(n) }) {
  const tx = (k, v) => plt(L, k, v);
  const msg = h('div', { class: 'ord-msg', 'aria-live': 'polite', 'data-testid': 'pl-msg' });
  const contact = h('p', { class: 'bk-note', 'data-testid': 'pl-contact' }, `${tx('contact')} `, phone ? h('a', { href: `tel:${phoneTel || phone.replace(/\s+/g, '')}`, text: phone }) : null);
  const showError = (code) => {
    const c = classifyLinkError(code);
    msg.replaceChildren(h('p', { class: 'bk-error', role: 'alert', 'data-testid': 'pl-error', 'data-code': String(code || 'generic'), text: tx(c.key) }));
    return c;
  };
  let busy = false;
  const btn = h('button', { type: 'button', class: 'btn ord-btn', 'data-testid': 'pl-button', text: tx('btn'), onclick: async () => {
    if (busy) return;
    busy = true; btn.disabled = true; btn.textContent = tx('busy'); msg.replaceChildren();
    let r = null;
    try { r = await api.start(); } catch { r = { ok: false, code: 'network' }; }
    const url = r?.ok ? safeVismaRedirect(r.redirect_url) : null;
    if (url) {
      msg.replaceChildren(h('p', { class: 'bk-note', role: 'status', 'data-testid': 'pl-redirect', text: tx('redirecting') }),
        r.amount != null ? h('p', { class: 'mp-amount', 'data-testid': 'pl-amount', text: tx('amount', { amount: money(r.amount) }) }) : null);
      navigate(url);
      return;
    }
    if (r?.ok && (r.dry_run || r.mode === 'dry_run')) {
      msg.replaceChildren(h('p', { class: 'bk-note', role: 'status', 'data-testid': 'pl-dryrun', text: tx('dryRun') }));
      busy = false; btn.disabled = false; btn.textContent = tx('btn');
      return;
    }
    const c = showError(r?.ok ? 'generic' : r?.code);
    if (c.final) btn.remove();   // lopullinen tila: uusi yritys ei auta (.btn-tyyli ohittaisi hidden-attribuutin)
    busy = false; btn.disabled = false; btn.textContent = tx('btn');
  } });
  const lead = h('p', { 'data-testid': 'pl-lead', text: tx('lead') });
  const card = h('section', { class: 'ord-card pl-card', 'data-testid': 'pay-link-page', 'aria-labelledby': 'pl-title' },
    h('h3', { id: 'pl-title', text: tx('title') }), lead, btn, msg, contact);
  if (!token) { showError('invalid_param'); btn.remove(); card.ready = Promise.resolve(null); return card; }
  if (!loadInfo) { card.ready = Promise.resolve(null); return card; }
  // yhteenveto: painike odottaa vastausta (ei kaksoistilaa), mutta ei koskaan aloita maksua itse
  btn.disabled = true; lead.textContent = tx('loading'); card.setAttribute('aria-busy', 'true');
  card.ready = (async () => {
    let info = null;
    try { info = normLinkInfo(await loadInfo()); } catch { info = null; }
    renderInfo(info);
    return info;
  })();
  function renderInfo(info) {
    const v = linkInfoView(info);
    card.setAttribute('aria-busy', 'false');
    if (!busy) btn.disabled = false;
    if (!info) { lead.textContent = tx('lead'); return; }   // RPC puuttuu / verkko / nopeusraja → kuten ennen
    card.setAttribute('data-status', info.status);
    const sum = v.showSummary ? summary(info, v) : null;
    if (v.pay) {
      lead.textContent = tx('leadOpen');
      if (sum) lead.before(sum);
      return;
    }
    btn.remove(); lead.remove();
    const state = h('p', { class: 'pl-state', role: 'status', 'data-testid': 'pl-state', 'data-status': info.status, 'data-code': info.reason, text: tx(v.msgKey) });
    msg.replaceChildren(state);
    if (sum) contact.before(sum);   // tila ensin, sitten mitä linkki koski
  }
  function summary(info, v) {
    const name = (i) => (L === 'en' && i.name_en ? i.name_en : i.name);
    const when = (i) => {
      if (!i.date || !i.start) return i.date ? fmtDate(L, i.date) : '';
      const end = i.end ? (i.end_date && i.end_date !== i.date ? `${fmtDate(L, i.end_date)} ${i.end}` : i.end) : '';
      return tx('sum.when', { date: fmtDate(L, i.date), start: i.start, end }).replace(/–$/, '');
    };
    const items = info.items.map((i) => h('li', { class: 'pl-item', 'data-testid': 'pl-item' },
      h('span', { class: 'pl-item-name', text: name(i) + (i.quantity > 1 ? ` · ${tx('sum.qty', { n: i.quantity })}` : '') }),
      when(i) ? h('span', { class: 'pl-item-when', 'data-testid': 'pl-item-when', text: when(i) }) : null));
    const exp = v.validKey ? h('p', { class: 'pl-valid', 'data-testid': 'pl-valid', text: tx(v.validKey, { date: fmtDate(L, info.expires_date), time: info.expires_time || '' }) }) : null;
    return h('div', { class: 'pl-sum', 'data-testid': 'pl-summary' },
      h('p', { class: 'pl-sum-label', text: tx(v.amountKey) }),
      h('p', { class: 'pl-sum-amount', 'data-testid': 'pl-sum-amount', text: money(info.amount) }),
      info.order_no != null ? h('p', { class: 'pl-sum-order', 'data-testid': 'pl-order' }, `${tx('sum.order')} `, h('strong', { text: String(info.order_no) })) : null,
      items.length ? h('p', { class: 'pl-sum-label', text: tx(v.pay ? 'sum.items' : 'sum.itemsOf') }) : null,
      items.length ? h('ul', { class: 'pl-items' }, ...items) : null,
      exp);
  }
  return card;
}

async function main() {
  const S = window.BOOKING_SHOP || {};
  const L = PLT[S.lang] ? S.lang : 'fi';
  const root = document.getElementById('pay-link-app');
  if (!root) return;
  try { await applyShopTexts(S); } catch { /* repon oletustekstit */ }
  const token = linkTokenFrom(location.search);
  // kielivalinta säilyttää ?p= (FI /maksa/ ↔ EN /en/pay/)
  if (S.otherHref) for (const a of document.querySelectorAll('.lang a[hreflang]')) a.setAttribute('href', switchHref(S.otherHref, location.search));
  const cfg = window.BOOKING_CONFIG || {};
  const api = createVismapayApi({ linkToken: token, functionUrl, anonKey: cfg.anonKey });
  const money = (n) => new Intl.NumberFormat(L === 'fi' ? 'fi-FI' : 'en-GB', { style: 'currency', currency: 'EUR' }).format(+n || 0);
  // vain luku; puuttuva RPC (404/PGRST202) tai verkkovirhe heittää → null → yleinen kortti + painike
  const loadInfo = token ? () => rpc('public_payment_link_info', { p_token: token }) : null;
  root.replaceChildren(payLinkView({ L, token, api, loadInfo, phone: S.phone, phoneTel: S.phoneTel, money }));
  root.setAttribute('aria-busy', 'false');
}

if (typeof window !== 'undefined' && typeof document !== 'undefined' && window.BOOKING_SHOP?.page === 'paylink') main();
