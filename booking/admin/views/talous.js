// Talous: välilehdet Tilaukset, Maksut, Raportit, Lahjakortit, Lahjakoodit (lunastuspyynnöt). Datakerros: ../talous-api.js (mock kun ?mock=1 tai RPC puuttuu). Kieli FI/EN (../talous-i18n.js).
import { rpc, select as dbSelect, functionUrl, fnBlob, fn } from '../sb.js';
import { h } from '../ui.js';
import { createTalousApi } from '../talous-api.js';
import { createGiftApi } from '../giftcards-api.js';
import { createVoucherApi } from '../vouchers-api.js';
import { t, getLang, setLang, LANGS } from '../talous-i18n.js';
import { createOrdersTab } from './talous-orders.js';
import { createPaymentsTab } from './talous-payments.js';
import { createReportsTab } from './talous-reports.js';
import { createGiftcardsTab } from './talous-giftcards.js';
import { createVouchersTab } from './talous-vouchers.js';
import { createSalesChart } from './talous-sales-chart.js';
import { loadOrderTexts } from '../orders-texts.js';

const ALL_TABS = [['orders', 'tab.orders'], ['payments', 'tab.payments'], ['reports', 'tab.reports'], ['giftcards', 'tab.giftcards'], ['vouchers', 'tab.vouchers']];

export async function render({ ctx, reload, query }) {
  const api = createTalousApi({ rpc, io: { select: dbSelect, functionUrl, fnBlob, fn } });
  await loadOrderTexts(rpc);
  // Raportit (sopimus §11): välilehti ja päiväraportti = reports.daily TAI reports.view; kuukausi + CSV = vain reports.view (muuten selkeä ilmoitus). Oikeudet luetaan aina oikealta käyttäjältä (myös ?mock=1).
  const canFull = !!ctx.can('reports.view'), canDaily = canFull || !!ctx.can('reports.daily');
  // Lahjakortit-välilehti: giftcards.manage. Tilaukset/Maksut: payments.manage (nav-kohta aukeaa myös pelkällä giftcards.manage → silloin vain Lahjakortit).
  const gift = createGiftApi({ rpc, io: { functionUrl } }), vouchers = createVoucherApi({ rpc }), canGift = !!ctx.can('giftcards.manage'), canPay = !!ctx.can('payments.manage');
  const TABS = ALL_TABS.filter(([k]) => (k === 'reports' ? canDaily : k === 'giftcards' || k === 'vouchers' ? canGift : canPay || !canGift));
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
  api.onChanged(() => { for (const k of ['payments', 'reports', 'giftcards', 'vouchers']) if (tabs[k]) dirty.add(k); });
  const factories = {
    orders: () => createOrdersTab({ api, ctx, gift }),
    payments: () => createPaymentsTab({ api, ctx, onOpenOrder: (no) => { select('orders'); tabs.orders.setSearch(String(no)); } }),
    reports: () => createReportsTab({ api, canFull }),
    vouchers: () => createVouchersTab({ api, vouchers, ctx, onOpenOrder: (no) => { select('orders'); tabs.orders.setSearch(String(no), { open: true }); } }),
    giftcards: () => createGiftcardsTab({ api, gift, ctx, onOpenOrder: (no) => { select('orders'); tabs.orders.setSearch(String(no), { open: true }); } }),
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
