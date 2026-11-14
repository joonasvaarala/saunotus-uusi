// Tilausnäkymä v3 (PR 1): asiakasnäkymä reitillä #/asiakkaat/<id> (luonnos asiakas-desktop / asiakas-mobiili).
// Data: admin_get_customer (booking_278 H: stats, open_balance, open_orders, gift_cards). Tulevat ja menneet tilaukset, yhteystiedot,
// markkinointilupa, lahjakortit, vuosikortti ja asiakkaan muistiinpano. Asiakashistoria näkyy VAIN täällä (ei tilauskortissa).
// Yhdistä/Anonymisoi (PR 4, booking_285) on omassa moduulissaan (customer-admin-panel.js) ja näkyy vain oikeudella customers.admin + palvelimen kytkimellä.
// HALL-ASIAKKAAT-01: kortit muokataan paikallaan (views/customer-cards.js); vanhaa asiakasmodaalia ei käytetä. Tallennuksen jälkeen näkymä piirretään uudelleen.
import { rpc as sbRpc } from '../sb.js';
import { h, errMsg } from '../ui.js';
import { fmt, getLang } from '../talous-i18n.js';
import { ov, loadOvTexts } from '../order-view-texts.js';
import { customerModel, customerOrderBadges } from '../order-view-logic.js';
import { contactButtons } from './order-view.js';
import { renderCustomerAdminPanel, loadAdminStatus } from './customer-admin-panel.js';
import { contactCard, consentCard, notesCard, annualCard } from './customer-cards.js';
import { loadAmTexts } from '../annual-manage-texts.js';
import { newBookingHref } from '../customer-edit-logic.js';

const c = (k, vars) => ov(`customer_view.${k}`, vars);
const card = (title, testid, ...kids) => h('section', { class: 'ov-card', 'data-testid': testid }, title ? h('div', { class: 'ov-card-head' }, typeof title === 'string' ? h('h2', { class: 'ov-h', text: title }) : title) : null, ...kids);
const shortDate = (iso) => {
  if (!iso) return '';
  const lang = getLang() === 'en' ? 'en-GB' : 'fi-FI';
  return new Intl.DateTimeFormat(lang, { timeZone: 'Europe/Helsinki', weekday: 'short', day: 'numeric', month: 'numeric', year: 'numeric' }).format(new Date(iso));
};

function orderRow(o) {
  const when = o.first_start || o.created_at;
  return h('a', { class: 'ov-crow', href: `#/tilaukset/${o.order_no}`, 'data-testid': 'cv-order', 'data-order-no': o.order_no },
    h('strong', { class: 'ov-crow-no', text: `#${o.order_no}` }),
    h('span', { class: 'ov-crow-when', text: when ? `${shortDate(when)} ${fmt.time(when)}` : '–' }),
    h('span', { class: 'ov-crow-what', text: [o.product, o.persons ? ov('order_view.persons', { n: o.persons }) : null, o.count > 1 ? c('res_more', { n: o.count - 1 }) : null].filter(Boolean).join(' · ') }),
    h('span', { class: 'ov-crow-badges' }, customerOrderBadges(o).map((b) => h('span', { class: `badge ${b.kind}`, text: ov(`order_view.${b.key}`) }))),
    h('span', { class: 'ov-crow-sum', text: fmt.money(o.total) }));
}

export async function renderCustomerView({ ctx, rpc = sbRpc, id, now = null, pastLimit = 5 }) {
  await loadOvTexts(rpc);
  const canEdit = !!ctx?.can?.('customers.manage'), canAnnual = !!ctx?.can?.('annual_cards.manage');
  if (canAnnual) await loadAmTexts(rpc).catch(() => false);
  const root = h('div', { class: 'ov-page ov-customer', 'data-testid': 'customer-view' });
  let raw;
  try { raw = await rpc('admin_get_customer', { p_id: Number(id) }); }
  catch (e) {
    root.append(h('nav', { class: 'ov-crumb' }, h('a', { href: '#/asiakkaat', text: `← ${c('crumb')}` })), h('p', { class: 'err', role: 'alert', text: c('load_failed', { error: errMsg(e) }) }));
    return root;
  }
  const m = customerModel(raw, { now: now ? new Date(now) : new Date() });
  const s = m.stats;
  const since = s.first_order_at || m.created_at;
  const head = h('header', { class: 'ov-head' },
    h('div', { class: 'ov-head-main' },
      h('div', { class: 'ov-title' }, h('h1', { 'data-testid': 'cv-name', text: m.name || '–' }),
        h('span', { class: 'ov-badges' }, h('span', { class: 'badge muted', text: m.kind === 'company' ? c('kind_company') : c('kind_private') }),
          m.consent.given ? h('span', { class: 'badge ok', text: c('consent_yes') }) : null, m.language ? h('span', { class: 'badge muted', text: String(m.language).toUpperCase() }) : null)),
      h('p', { class: 'muted ov-meta', text: [since ? c('meta_since', { year: new Date(since).getFullYear() }) : null, c('meta_orders', { n: s.orders || 0 }), s.no_show ? c('meta_no_show', { n: s.no_show }) : null].filter(Boolean).join(' · ') })),
    h('div', { class: 'ov-head-actions' }, contactButtons({ phone: m.phone, email: m.email }, { big: true }),
      ctx?.can?.('bookings.manage') && !m.anonymized && !m.merged_into ? h('a', { class: 'btn primary', href: newBookingHref(m.id), 'data-testid': 'cv-new-booking', text: c('new_booking') }) : null));
  const stat = (label, value, sub, testid, cls = '') => h('div', { class: `ov-stat ${cls}`, 'data-testid': testid }, h('span', { class: 'ov-cap', text: label }), h('strong', { text: value }), sub ? h('small', { class: 'muted', text: sub }) : null);
  const stats = h('div', { class: 'ov-stats', 'data-testid': 'cv-stats' },
    stat(c('stat_open'), m.open_balance != null ? fmt.money(m.open_balance) : '–', m.open_orders ? c('stat_open_sub', { n: m.open_orders }) : c('stat_open_none'), 'cv-stat-open', m.open_balance > 0.004 ? 'is-err' : ''),
    stat(c('stat_visits'), String(s.visits ?? 0), s.last_visit ? c('stat_visits_sub', { when: fmt.date(s.last_visit) }) : null, 'cv-stat-visits'),
    stat(c('stat_upcoming'), String(s.upcoming ?? 0), s.next_at ? c('stat_upcoming_sub', { when: fmt.date(s.next_at) }) : null, 'cv-stat-upcoming'),
    stat(c('stat_no_show'), String(s.no_show ?? 0), s.last_no_show ? fmt.date(s.last_no_show) : null, 'cv-stat-noshow'));
  const pastList = h('div', { class: 'ov-clist' });
  let showAll = false;
  const paintPast = () => pastList.replaceChildren(...(m.past.length ? (showAll ? m.past : m.past.slice(0, pastLimit)).map(orderRow) : [h('p', { class: 'muted', text: c('no_past') })]));
  paintPast();
  const allBtn = m.past.length > pastLimit ? h('button', { type: 'button', class: 'linkish', 'data-testid': 'cv-show-all', text: c('show_all', { n: m.past.length }), onclick: (e) => { showAll = true; paintPast(); e.currentTarget.hidden = true; } }) : null;
  const main = h('div', { class: 'ov-main' }, stats,
    card(c('upcoming'), 'cv-upcoming', h('div', { class: 'ov-clist' }, m.upcoming.length ? m.upcoming.map(orderRow) : h('p', { class: 'muted', text: c('no_upcoming') }))),
    card(h('div', { class: 'row between' }, h('h2', { class: 'ov-h', text: c('past') }), allBtn), 'cv-past', pastList));
  const kv = (rows) => h('dl', { class: 'ov-kv' }, rows.filter(Boolean).map(([k, v]) => [h('dt', { text: k }), h('dd', { text: v || '–' })]));
  const gifts = m.gift_cards;
  const onSaved = () => renderCustomerView({ ctx, rpc, id, now, pastLimit }).then((n) => root.replaceWith(n));
  const side = h('aside', { class: 'ov-side' },
    contactCard({ rpc, m, raw, canEdit, onSaved }),
    consentCard({ rpc, m, canEdit, onSaved }),
    gifts ? card(c('gift_cards'), 'cv-gift', gifts.bought_count ? kv([[c('gift_bought', { n: gifts.bought_count }), fmt.money(gifts.bought_total)], [c('gift_redeemed'), String(gifts.redeemed_count ?? 0)]])
      : h('p', { class: 'muted ov-small', text: c('gift_none') }),
      (gifts.bought || []).length ? h('ul', { class: 'ov-gifts' }, gifts.bought.slice(0, 5).map((g) => h('li', {}, h('code', { text: g.code_masked }), ` · ${fmt.money(g.balance)} / ${fmt.money(g.initial_amount)}${g.valid_to ? ` · ${fmt.date(g.valid_to)}` : ''}`))) : null) : null,
    annualCard({ rpc, m, canManage: canAnnual, onSaved }),
    notesCard({ rpc, m, canEdit, onSaved }));
  // PR 4: Yhdistä/Anonymisoi. Osio ilmestyy vain, jos palvelin sanoo (oikeus + kytkin). Onnistumisen jälkeen avataan säilytetty asiakas tai ladataan näkymä uudelleen.
  const adminStatus = await loadAdminStatus(rpc);
  const adminPanel = renderCustomerAdminPanel({ rpc, ctx, customer: m, status: adminStatus,
    onDone: (keepId) => { if (Number(keepId) === Number(m.id)) renderCustomerView({ ctx, rpc, id, now, pastLimit }).then((n) => root.replaceWith(n)); else { globalThis.location.hash = `#/asiakkaat/${keepId}`; } } });
  if (adminPanel) side.append(adminPanel);
  root.append(...[h('nav', { class: 'ov-crumb' }, h('a', { href: '#/asiakkaat', 'data-testid': 'cv-back', text: `← ${c('crumb')}` }), ' / ', h('span', { text: m.name || '' })),
    m.anonymized ? h('p', { class: 'muted', text: c('anonymized') }) : null,
    m.merged_into ? h('p', { class: 'muted', 'data-testid': 'cv-merged' }, c('merged_notice', { id: m.merged_into }), ' ', h('a', { href: `#/asiakkaat/${m.merged_into}`, text: c('merged_open') })) : null, head, h('div', { class: 'ov-grid' }, main, side)].filter(Boolean));
  return root;
}
