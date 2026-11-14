// Talous: välilehdet Tilaukset, Maksut, Raportit, Kävijät. Lahjakortit ja lunastuspyynnöt ovat valikossa Lahjakortit (giftcards.manage).
// Datakerros: ../talous-api.js (mock kun ?mock=1 tai RPC puuttuu). Kieli FI/EN (../talous-i18n.js).
import { rpc, select as dbSelect, functionUrl, fnBlob, fn } from '../sb.js';
import { h, tabs as tabList } from '../ui.js';
import { createTalousApi } from '../talous-api.js';
import { createGiftApi } from '../giftcards-api.js';
import { t, getLang, setLang, LANGS } from '../talous-i18n.js';
import { navText } from '../nav-texts.js';
import { createOrdersTab } from './talous-orders.js';
import { createPaymentsTab } from './talous-payments.js';
import { createReportsTab } from './talous-reports.js';
import { createAnalyticsTab } from './talous-analytics.js';
import { createSalesChart } from './talous-sales-chart.js';
import { loadOrderTexts } from '../orders-texts.js';
import { loadReportTexts } from '../reports-texts.js';
import { loadRcTexts } from '../refund-cancel-texts.js';
import { loadAcTexts } from '../annual-card-texts.js';

const ALL_TABS = [['orders', 'tab.orders'], ['payments', 'tab.payments'], ['reports', 'tab.reports'], ['analytics', 'tab.analytics']];

export async function render({ ctx, reload, query }) {
  const api = createTalousApi({ rpc, io: { select: dbSelect, functionUrl, fnBlob, fn } });
  // Tekstit jaetusta site_texts-välimuistista rinnakkain (yksi haku istunnossa).
  await Promise.all([loadOrderTexts(rpc), loadReportTexts(rpc), loadRcTexts(rpc), loadAcTexts(rpc)]);
  // Raportit (sopimus §11): välilehti ja päiväraportti = reports.daily TAI reports.view; kuukausi + CSV = vain reports.view (muuten selkeä ilmoitus). Oikeudet luetaan aina oikealta käyttäjältä (myös ?mock=1).
  const canFull = !!ctx.can('reports.view'), canDaily = canFull || !!ctx.can('reports.daily');
  // Tilaukset/Maksut: payments.manage. Pelkkä giftcards.manage ei näe näitä (lahjakortit ovat omassa valikossa).
  const gift = createGiftApi({ rpc, io: { functionUrl } }), canGift = !!ctx.can('giftcards.manage'), canPay = !!ctx.can('payments.manage');
  const TABS = ALL_TABS.filter(([k]) => (k === 'reports' || k === 'analytics' ? canDaily : canPay || !canGift));
  if (!TABS.length) {
    return h('div', { class: 'tl', 'data-testid': 'talous' },
      h('h1', { text: t('title') }),
      h('p', {}, h('a', { href: '#/lahjakortit', text: navText('ui.admin.nav.giftcards') })));
  }
  const hashQ = () => new URLSearchParams(location.hash.split('?')[1] || '');
  let tab = TABS.some(([k]) => k === query.get('tab')) ? query.get('tab') : TABS[0][0];
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
  api.onChanged(() => { for (const k of ['payments', 'reports', 'analytics']) if (tabs[k]) dirty.add(k); });
  const factories = {
    orders: () => createOrdersTab({ api, ctx, gift, rpc }),   // booking_173: rpc kumppanilahjakortin laatikolle
    payments: () => createPaymentsTab({ api, ctx, onOpenOrder: (no) => { select('orders'); tabs.orders.setSearch(String(no)); } }),
    reports: () => createReportsTab({ api, canFull, ctx }),
    analytics: () => createAnalyticsTab(),   // Paketti 11: Kävijät (reports.daily/reports.view), admin_analytics_summary
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
  const list = tabList({ label: t('tabs'), idPrefix: 'tl-tab', selected: tab, onSelect: (k, focus) => select(k, focus),
    items: TABS.map(([k, label]) => ({ id: k, text: t(label), controls: `tl-pnl-${k}`, testid: `tab-${k}-btn` })) });
  for (const [k] of TABS) tabBtns[k] = list.button(k);
  for (const [k] of TABS) panels[k] = h('div', { role: 'tabpanel', id: `tl-pnl-${k}`, 'aria-labelledby': `tl-tab-${k}`, hidden: true, class: 'tl-panel-wrap' });
  const langs = h('div', { class: 'tl-langs tl-noprint', role: 'group', 'aria-label': t('lang.label') }, LANGS.map((l) => h('button', { type: 'button', class: 'tl-lang', 'aria-pressed': String(getLang() === l), 'data-testid': `lang-${l}`, lang: l,
    onclick: () => { if (getLang() === l) return; setLang(l); reload(); } }, l.toUpperCase())));
  // Myyntikäyrä ennen välilehtiä. Vain reports.view (kuukausiraportin oikeus). Johku on mukana vain tässä käyrässä.
  const chart = canFull ? createSalesChart({ api, rpc }) : null;
  if (chart) chart.load();
  const root = h('div', { class: 'tl', lang: getLang(), 'data-testid': 'talous' },
    h('div', { class: 'row between wrap tl-top tl-noprint' }, h('h1', { text: t('title') }), langs), banner, vatBox, chart?.node, list, ...TABS.map(([k]) => panels[k]));
  select(tab);
  const deepOrder = (query.get('order') || '').trim();   // #/talous?tab=orders&order=<tilausnumero> (esim. Uusi varaus → Avaa tilaus ja maksut): haku + tilaus auki
  if (deepOrder && tab === 'orders') tabs.orders.setSearch(deepOrder, { open: true });
  return root;
}
