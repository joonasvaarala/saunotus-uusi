// Talous-sivun yhteiset UI-osat: koodien nimet, merkit, sivutus, laajennettava rivi, toimintonapit, virhe-/tyhjätilat.
import { h, badge, errMsg, toast, dialog } from '../ui.js';
import { icon } from '../icons.js';
import { t, fmt, has } from '../talous-i18n.js';
import { FeatureNotReady } from '../talous-api.js';

export const PAY = ['unpaid', 'pending', 'paid', 'partially_paid', 'refunded', 'partially_refunded', 'failed'];
export const PSTAT = ['pending', 'paid', 'partially_refunded', 'refunded', 'failed', 'cancelled'];
export const SOURCES = ['web', 'admin', 'phone', 'email', 'walk_in', 'johku_import', 'other'];
export const METHODS = ['cash', 'card_terminal', 'mobilepay', 'visma_pay', 'bank_transfer', 'invoice', 'gift_card', 'partner_voucher', 'other', 'pay_later'];
export const PAGE_SIZES = [25, 50, 100];
const lab = (prefix, code) => (has(`${prefix}.${code}`) ? t(`${prefix}.${code}`) : code || '–');
export const payLabel = (c) => lab('pay', c);
export const pstatLabel = (c) => lab('pstat', c);
export const sourceLabel = (c) => lab('src', c);
// maksutavan nimi: oma käännös, muuten palvelimen method_label, muuten koodi
export const methodLabel = (c, serverLabel) => (has(`method.${c}`) ? t(`method.${c}`) : serverLabel || c || '–');
export const groupLabel = (c) => lab('group', c);
export const payBadge = (c) => badge(`pay-${c}`, payLabel(c));
export const pstatBadge = (c) => badge(PAY.includes(c) && c !== 'unpaid' ? `pay-${c}` : c === 'cancelled' ? 'muted' : 'pay-pending', pstatLabel(c));
// Johku-lähtöinen (booking_41): pieni merkki, ei kirjanpitoon
export const johkuBadge = () => { const b = badge('src-johku', t('johku.badge')); b.title = t('johku.badgeTitle'); b.dataset.testid = 'johku-badge'; return b; };
export const sourceBadge = (c) => badge(c === 'johku_import' ? 'src-johku' : 'muted', sourceLabel(c));

// Virheviesti: tunnettu palvelinkoodi (nothing_to_pay …) → käännetty teksti, muuten ui.js:n errMsg
export const friendly = (e) => (e?.code && has(`err.${e.code}`) ? t(`err.${e.code}`) : errMsg(e));
export const loading = () => h('p', { class: 'muted tl-loading', role: 'status', text: t('loading') });
export const emptyBox = (text) => h('p', { class: 'empty tl-empty', role: 'status', text });
// Virhe: puuttuva ominaisuus → rauhallinen ilmoitus; muu virhe → punainen + "Yritä uudelleen"
export function errorBox(e, retry) {
  if (e instanceof FeatureNotReady) return h('p', { class: 'muted tl-empty', role: 'status', text: t('notReady', { rpc: e.rpc }) });
  return h('div', { class: 'tl-error', role: 'alert' }, h('p', { class: 'err', text: friendly(e) }), retry ? h('button', { type: 'button', class: 'btn', onclick: retry }, t('retry')) : null);
}

// Sivutus (palvelinpuolinen): ensimmäinen / edellinen / sivunumero / seuraava / viimeinen. onPage(offset)
export function pager({ total, offset, limit, onPage }) {
  const pages = Math.max(1, Math.ceil(total / limit)), cur = Math.min(pages, Math.floor(offset / limit) + 1);
  const go = (p) => onPage((Math.min(Math.max(1, Math.round(p) || cur), pages) - 1) * limit);
  const ico = { first: 'pgfirst', prev: 'pgprev', next: 'pgnext', last: 'pglast' };
  const b = (name, label, target, dis) => h('button', { type: 'button', class: 'btn ghost tl-pgbtn', 'aria-label': label, title: label, disabled: dis, 'data-testid': `pg-${name}`, onclick: () => go(target) },
    h('span', { 'aria-hidden': 'true' }, icon(ico[name], 20)));
  const input = h('input', { type: 'number', min: 1, max: pages, value: cur, inputmode: 'numeric', class: 'tl-pageinput', 'aria-label': t('pager.goto'), 'data-testid': 'pg-input', onchange: (e) => go(+e.target.value) });
  return h('nav', { class: 'tl-pager', 'aria-label': t('pager.label'), 'data-testid': 'pager', 'data-page': cur, 'data-pages': pages },
    b('first', t('pager.first'), 1, cur <= 1), b('prev', t('pager.prev'), cur - 1, cur <= 1),
    h('span', { class: 'tl-pgof' }, input, h('span', { text: `/ ${fmt.int(pages)}` })),
    b('next', t('pager.next'), cur + 1, cur >= pages), b('last', t('pager.last'), pages, cur >= pages));
}
export function pageSizeSelect(value, onChange) {
  return h('label', { class: 'fld' }, h('span', { text: t('pagesize') }),
    h('select', { 'data-testid': 'pagesize', onchange: (e) => onChange(+e.target.value) }, PAGE_SIZES.map((n) => h('option', { value: n, selected: n === value ? true : null, text: String(n) }))));
}
// Alasvetovalikko "kaikki" + koodit
export function selectFld(label, testid, codes, labelOf, value, onChange, allText = t('all')) {
  const sel = h('select', { 'data-testid': testid, onchange: (e) => onChange(e.target.value) }, h('option', { value: '', text: allText }), codes.map((c) => h('option', { value: c, text: labelOf(c) })));
  sel.value = value || '';
  return h('label', { class: 'fld' }, h('span', { text: label }), sel);
}
export const dateFld = (label, testid, value, onChange) => h('label', { class: 'fld' }, h('span', { text: label }), h('input', { type: 'date', value: value || '', 'data-testid': testid, onchange: (e) => onChange(e.target.value) }));
export function searchFld(placeholder, testid, onChange) {
  let timer;
  const input = h('input', { type: 'search', placeholder, 'aria-label': placeholder, 'data-testid': testid, autocomplete: 'off',
    oninput: (e) => { clearTimeout(timer); timer = setTimeout(() => onChange(e.target.value.trim()), 300); },
    onkeydown: (e) => { if (e.key === 'Enter') { clearTimeout(timer); onChange(e.target.value.trim()); } } });
  return { node: h('label', { class: 'fld tl-search' }, h('span', { text: t('search') }), input), input };
}

// Laajennettava rivi: head = napin sisältö (span-elementtejä), build() → sisältö ladataan ensimmäisellä avauksella
// bar = valinnainen rivi otsikon alla (napin ulkopuolella, jotta siinä voi olla linkkejä/nappeja; näkyy aina)
export function expandRow({ id, head, build, testid, cls = '', bar = null }) {
  const panel = h('div', { class: 'tl-panel', id: `tl-panel-${id}`, hidden: true, role: 'region', 'aria-label': t('details') });
  let loaded = false;
  const load = async () => {
    loaded = true; panel.replaceChildren(loading());
    try { panel.replaceChildren(await build()); } catch (e) { loaded = false; panel.replaceChildren(errorBox(e, load)); }
  };
  const btn = h('button', { type: 'button', class: 'tl-head', 'aria-expanded': 'false', 'aria-controls': panel.id, 'data-testid': `${testid}-head`, onclick: () => {
    const open = btn.getAttribute('aria-expanded') !== 'true';
    btn.setAttribute('aria-expanded', String(open)); panel.hidden = !open; row.classList.toggle('open', open);
    if (open && !loaded) load();
  } }, head, h('span', { class: 'tl-chev', 'aria-hidden': 'true' }, icon('chev', 20)));
  const row = h('li', { class: `tl-row ${cls}`, 'data-testid': testid }, btn, bar, panel);
  return row;
}

// Toimintonappi. Pois käytöstä vain kun toiminto ei sovellu juuri tälle tilaukselle (extraDisabled = selite; näkyy myös title-tekstinä).
export function actionBtn({ key, label, ico, testid, extraDisabled = null, onClick }) {
  const off = !!extraDisabled;
  const b = h('button', { type: 'button', class: `btn tl-btn${off ? ' is-off' : ''}`, 'data-testid': testid, 'data-action': key, disabled: off ? true : null, title: extraDisabled || null,
    onclick: async () => { b.disabled = true; try { await onClick(); } catch (e) { toast(e instanceof FeatureNotReady ? t('notReady', { rpc: e.rpc }) : friendly(e), 'err'); } finally { b.disabled = false; } } },
    ico ? h('span', { class: 'tl-ico', 'aria-hidden': 'true' }, icon(ico, 20)) : null, h('span', { text: label }));
  return b;
}
// Tulos-ilmoitus: mock-vastaus (res.mock) kertoo ettei mitään muutettu; oikea vastaus = onnistui
export const doneToast = (res, rpcName) => (res?.mock ? toast(t('mock.done', { rpc: rpcName }), 'warn') : toast(t('done', { rpc: rpcName }), 'ok'));
// Yksinkertainen vahvistus-/lomakedialogi mock-toimintoihin
export function formDialog(title, fields, submitText, onSubmit) {
  const form = h('form', { class: 'stack', novalidate: true, onsubmit: async (ev) => {
    ev.preventDefault(); const btn = form.querySelector('button[type=submit]'); btn.disabled = true;
    try { await onSubmit(new FormData(form)); d.close(); } catch (e) { if (!e?.handled) toast(friendly(e), 'err'); } finally { btn.disabled = false; }   // handled = virhe näytettiin jo kentän alla
  } }, fields, h('button', { class: 'btn primary', type: 'submit', text: submitText }));
  const d = dialog(title, form);
  return d;
}
