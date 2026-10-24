// Paketti 11 / booking_144: Kävijät-välilehti (Talous). Rajaus Helsingin päivämäärillä, raportti ilman henkilötietoja (admin_analytics_summary).
// Näkyy samalla oikeudella kuin Raportit (reports.daily tai reports.view). Mittaus itse on oletuksena pois (ks. public/js/analytics.js).
import { h } from '../ui.js';
import { rpc } from '../sb.js';
import { t, fmt } from '../talous-i18n.js';
import { wantsMock } from '../talous-api.js';
import { analyticsMock } from '../analytics-mock.js';

const helDay = () => new Date().toLocaleDateString('sv-SE', { timeZone:'Europe/Helsinki' });
const addDays = (str, offset) => { const d = new Date(`${str}T12:00:00Z`); d.setUTCDate(d.getUTCDate()+offset); return d.toISOString().slice(0,10); };
const presets = {
  today: now => [now,now],
  week: now => [addDays(now,-6),now],
  month30: now => [addDays(now,-29),now],
  month: now => [now.slice(0,8)+'01',now],
};
const SOURCE_KEYS = { google_search: 'a.source.google_search', google_maps: 'a.source.google_maps', social: 'a.source.social', direct: 'a.source.direct', campaign: 'a.source.campaign', referral: 'a.source.referral' };
const sourceName = k => (SOURCE_KEYS[k] ? t(SOURCE_KEYS[k]) : k);
const percent = n => fmt.pct(n || 0);
const n = x => +x || 0;
function card(title, children, id) {
  return h('section', { class:'tl-sec', 'data-testid':id }, h('h3', { text:title }), ...children);
}
function table(headings, rows, id) {
  return h('div', { class:'tl-table-scroll', 'data-testid':id },
    h('table', { class:'tl-table' },
      h('thead', {}, h('tr', {}, headings.map(x => h('th', { scope:'col', text:x })))),
      h('tbody', {}, rows.length ? rows.map(row => h('tr', {}, row.map((v, j) => h('td', { 'data-label':headings[j], text:String(v ?? '–') }))))
        : [h('tr', {}, h('td', { colspan:String(headings.length), class:'muted', text:t('a.empty') }))])));
}
export function createAnalyticsTab({ rpcCall = rpc, mock = wantsMock() } = {}) {
  const now = helDay(); let [from,to] = presets.week(now); let active = 'week'; let generation=0;
  const fromInput = h('input', { type:'date', value:from, 'aria-label':t('a.from') });
  const toInput = h('input', { type:'date', value:to, 'aria-label':t('a.to') });
  const status = h('p', { class:'muted', role:'status', 'aria-live':'polite' });
  const results = h('div', { 'data-testid':'analytics-results' });
  const buttons = Object.entries({ today:'a.today', week:'a.week', month30:'a.month30', month:'a.month', custom:'a.custom' }).map(([key, label]) => {
    const b = h('button', { type:'button', class:'btn tl-arange', 'aria-pressed':key===active?'true':'false', text:t(label) });
    b.addEventListener('click', () => { active=key; if(presets[key]) [from,to]=presets[key](helDay()); fromInput.value=from; toInput.value=to; buttons.forEach(([k,b])=>b.setAttribute('aria-pressed',String(k===key))); load(); });
    return [key,b];
  });
  const sync = () => { active='custom'; buttons.forEach(([k,b])=>b.setAttribute('aria-pressed',String(k===active))); from=fromInput.value;to=toInput.value;load(); };
  fromInput.addEventListener('change',sync); toInput.addEventListener('change',sync);
  const node = h('div', { 'data-testid':'analytics-tab' },
    h('div', { class:'tl-toolbar tl-noprint', role:'group','aria-label':t('a.range') },
      ...buttons.map(x=>x[1]), h('label', {},t('a.from'),fromInput), h('label',{},t('a.to'),toInput)),status,results);
  function draw(r) {
    const f = r?.funnel || {};
    const steps = [
      [t('a.visitors'),n(f.visitors)],
      [t('a.viewers'),n(f.product_viewers)],
      [t('a.checkouts'),n(f.checkout_starters)],
      [t('a.buyers'),n(f.buyers)],
    ];
    const max = Math.max(1, ...steps.map(x=>x[1]));
    const funnel = steps.map(([label,count],i) => {
      const prev = i ? steps[i-1][1] : count;
      const drop = i && prev ? Math.max(0,(1-count/prev)*100) : 0;
      return h('div', { class:'tl-analytics-step' },
        h('div', { class:'row between wrap' },h('strong',{text:label}),h('span',{text:fmt.int(count)})),
        h('div', { class:'tl-analytics-bar', role:'img', 'aria-label':label+': '+count },
          h('span', { class:'tl-analytics-fill', style:`width:${Math.min(100, count/max*100)}%;min-width:${count>0?'4px':'0'}` })),
        i ? h('small',{class:'muted',text:`${t('a.drop')}: ${percent(drop)}`}) : null);
    });
    const sources=(r?.sources || []).map(s=>[sourceName(s.source_category),fmt.int(s.visits),fmt.int(s.purchases),percent(s.conversion_pct),s.top_utm_campaign || s.top_referrer_domain || '–']);
    const products=(r?.top_products || []).map(p=>[p.name || p.product_slug,fmt.int(p.views),fmt.int(p.checkouts),fmt.int(p.purchases),percent(p.conversion_pct)]);
    const deviceNames={mobile:t('a.mobile'),desktop:t('a.desktop'),tablet:t('a.tablet')};
    const localeNames={fi:t('a.fi'),en:t('a.en')};
    const devices=(r?.devices_and_locales?.devices || []).map(x=>[deviceNames[x.device_type] || x.device_type,fmt.int(x.visits),fmt.int(x.purchases)]);
    const locales=(r?.devices_and_locales?.locales || []).map(x=>[localeNames[x.locale] || x.locale,fmt.int(x.visits),fmt.int(x.purchases)]);
    results.replaceChildren(
      card(t('a.funnel'),[...funnel,h('p',{class:'tl-analytics-kpi',text:`${t('a.conversion')}: ${percent(f.conversion_pct)} · ${t('a.paidOrders')}: ${fmt.int(f.paid_orders)} · ${fmt.money(f.amount_gross)}`})],'analytics-funnel'),
      card(t('a.sources'),[table([t('a.source'),t('a.visits'),t('a.purchases'),t('a.conv'),t('a.campaign')],sources,'analytics-sources-table')],'analytics-sources'),
      card(t('a.products'),[table([t('a.product'),t('a.views'),t('a.checkouts'),t('a.purchases'),t('a.conv')],products,'analytics-products-table')],'analytics-products'),
      card(t('a.devicesLocales'),[table([t('a.device'),t('a.visits'),t('a.purchases')],devices,'analytics-devices-table'),table([t('a.language'),t('a.visits'),t('a.purchases')],locales,'analytics-locales-table')],'analytics-devices-locales'));
  }
  async function load() {
    const thisGen=++generation;
    if (!/^\d{4}-\d{2}-\d{2}$/.test(from) || !/^\d{4}-\d{2}-\d{2}$/.test(to) || from>to || (new Date(to)-new Date(from))>366*864e5) {
      status.textContent=t('a.badDates');results.replaceChildren(); return;
    }
    status.textContent=t('loading');
    try {
      const r=mock ? analyticsMock(from,to) : await rpcCall('admin_analytics_summary',{p_from:from,p_to:to});
      if (thisGen!==generation) return;
      status.textContent=mock ? t('a.mock') : ''; draw(r);
    } catch(e) {
      if (thisGen!==generation) return;
      status.textContent=t('a.error')+(e?.message ? ': '+e.message : ''); results.replaceChildren();
    }
  }
  return { node, load };
}
