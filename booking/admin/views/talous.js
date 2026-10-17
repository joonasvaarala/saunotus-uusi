// Talous: välilehdet Tilaukset, Maksut, Raportit. Datakerros: ../talous-api.js (mock kun ?mock=1 tai RPC puuttuu). Kieli FI/EN (../talous-i18n.js).
import { rpc } from '../sb.js';
import { h } from '../ui.js';
import { createTalousApi } from '../talous-api.js';
import { t, getLang, setLang, LANGS } from '../talous-i18n.js';
import { createOrdersTab } from './talous-orders.js';
import { createPaymentsTab } from './talous-payments.js';
import { createReportsTab } from './talous-reports.js';

const ALL_TABS = [['orders', 'tab.orders'], ['payments', 'tab.payments'], ['reports', 'tab.reports']];

export async function render({ ctx, reload, query }) {
  const api = createTalousApi({ rpc });
  // Raportit (sopimus §11): välilehti ja päiväraportti = reports.daily TAI reports.view; kuukausi + CSV = vain reports.view (muuten selkeä ilmoitus). Oikeudet luetaan aina oikealta käyttäjältä (myös ?mock=1).
  const canFull = !!ctx.can('reports.view'), canDaily = canFull || !!ctx.can('reports.daily');
  const TABS = ALL_TABS.filter(([k]) => k !== 'reports' || canDaily);
  const hashQ = () => new URLSearchParams(location.hash.split('?')[1] || '');
  let tab = TABS.some(([k]) => k === query.get('tab')) ? query.get('tab') : 'orders';
  const tabs = {}, panels = {}, tabBtns = {};
  const banner = h('div', { class: 'tl-banner', role: 'status', 'data-testid': 'mock-banner', hidden: true });
  const showBanner = () => {
    const m = !!api.reason;
    banner.hidden = !m; banner.dataset.reason = api.reason || '';
    banner.replaceChildren(...(m ? [h('strong', { text: t(api.reason === 'missing' ? 'banner.missing.title' : 'banner.mock.title') }), ' ', h('span', { text: t(api.reason === 'missing' ? 'banner.missing' : 'banner.mock', { rpc: api.missingRpc || '' }) })] : []));
  };
  api.onMode(showBanner); showBanner();
  // ALV-huomautus: tuotteet ilman ALV-kantaa (admin_list_vat_rates().missing) – lisäys tilaukseen on niiltä estetty (vat_missing)
  const vatBox = h('div', { class: 'tl-banner tl-vat', role: 'status', 'data-testid': 'vat-missing', hidden: true });
  api.listVatRates().then((r) => {
    if (!r || !(r.missing.length || r.quote_only.length)) return;
    const shown = r.missing.slice(0, 5), more = r.missing.length - shown.length;
    vatBox.replaceChildren(...(r.missing.length ? [h('strong', { text: t('vat.title') }), ' ', h('span', { text: t('vat.body') }), ' ',
      h('span', { 'data-testid': 'vat-missing-list', text: shown.map((x) => x.name).join('; ') + (more > 0 ? ` ${t('vat.more', { n: more })}` : '') })] : []),
      ...(r.quote_only.length ? [h('p', { class: 'muted', 'data-testid': 'vat-quote-only', text: t('vat.quote', { n: r.quote_only.length }) })] : []));
    vatBox.hidden = false; vatBox.dataset.count = String(r.missing.length);
  }).catch(() => {});
  const dirty = new Set();
  api.onChanged(() => { for (const k of ['payments', 'reports']) if (tabs[k]) dirty.add(k); });
  const factories = {
    orders: () => createOrdersTab({ api, ctx }),
    payments: () => createPaymentsTab({ api, onOpenOrder: (no) => { select('orders'); tabs.orders.setSearch(String(no)); } }),
    reports: () => createReportsTab({ api, canFull }),
  };
  function ensure(k) {
    if (tabs[k]) return;
    tabs[k] = factories[k](); panels[k].append(tabs[k].node); tabs[k].load();
  }
  function select(k, focus = false) {
    tab = k;
    for (const [key] of TABS) { const on = key === k; tabBtns[key].setAttribute('aria-selected', String(on)); tabBtns[key].tabIndex = on ? 0 : -1; panels[key].hidden = !on; }
    ensure(k);
    if (dirty.delete(k)) tabs[k].load();
    const q = hashQ(); q.set('tab', k);
    history.replaceState(null, '', `#/talous?${q.toString()}`);   // hashchange-tapahtumaa ei synny → sivua ei piirretä uudelleen
    if (focus) tabBtns[k].focus();
  }
  const list = h('div', { class: 'tl-tabs', role: 'tablist', 'aria-label': t('tabs') },
    ...TABS.map(([k, label]) => { const b = h('button', { type: 'button', role: 'tab', id: `tl-tab-${k}`, class: 'tl-tabbtn', 'aria-controls': `tl-pnl-${k}`, 'data-testid': `tab-${k}-btn`, onclick: () => select(k),
      onkeydown: (e) => { const i = TABS.findIndex(([x]) => x === k); const nx = { ArrowRight: i + 1, ArrowLeft: i - 1, Home: 0, End: TABS.length - 1 }[e.key]; if (nx != null) { e.preventDefault(); select(TABS[(nx + TABS.length) % TABS.length][0], true); } } }, t(label)); tabBtns[k] = b; return b; }));
  for (const [k] of TABS) panels[k] = h('div', { role: 'tabpanel', id: `tl-pnl-${k}`, 'aria-labelledby': `tl-tab-${k}`, hidden: true, class: 'tl-panel-wrap' });
  const langs = h('div', { class: 'tl-langs tl-noprint', role: 'group', 'aria-label': t('lang.label') }, LANGS.map((l) => h('button', { type: 'button', class: 'tl-lang', 'aria-pressed': String(getLang() === l), 'data-testid': `lang-${l}`, lang: l,
    onclick: () => { if (getLang() === l) return; setLang(l); reload(); } }, l.toUpperCase())));
  const root = h('div', { class: 'tl', lang: getLang(), 'data-testid': 'talous' },
    h('div', { class: 'row between wrap tl-top tl-noprint' }, h('h1', { text: t('title') }), langs), banner, vatBox, list, ...TABS.map(([k]) => panels[k]));
  select(tab);
  return root;
}
