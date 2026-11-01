// Lahjakortit: Omat lahjakortit (haku + voimassaolon pikajatko) ja Lunastuspyynnöt.
// Oikeus sama kuin aiemmin Talous › Lahjakortit: giftcards.manage. Toiminnot ovat talous-giftcards.js ja talous-vouchers.js.
import { rpc, functionUrl } from '../sb.js';
import { h } from '../ui.js';
import { createGiftApi } from '../giftcards-api.js';
import { createVoucherApi } from '../vouchers-api.js';
import { t, getLang, setLang, LANGS } from '../talous-i18n.js';
import { navText } from '../nav-texts.js';
import { createGiftcardsTab } from './talous-giftcards.js';
import { createVouchersTab } from './talous-vouchers.js';

const TABS = [['omat', 'ui.admin.nav.giftcards_own'], ['lunastukset', 'ui.admin.nav.giftcards_claims']];

export async function render({ ctx, query }) {
  const gift = createGiftApi({ rpc, io: { functionUrl } });
  const vouchers = createVoucherApi({ rpc });
  const openOrder = (no) => { location.hash = `#/tilaukset?order=${encodeURIComponent(no)}`; };
  const asked = query.get('tab');
  let tab = asked === 'vouchers' || asked === 'lunastukset' ? 'lunastukset' : 'omat';
  const panels = {}, buttons = {};
  let own = null, claims = null;
  function hrefFor(id) {
    const q = new URLSearchParams(location.hash.split('?')[1] || '');
    q.set('tab', id);
    if (id !== 'omat') { q.delete('code'); q.delete('browse'); }
    return `#/lahjakortit?${q.toString()}`;
  }
  function select(id, focus = false) {
    if (!panels[id]) return;
    tab = id;
    for (const [k] of TABS) {
      const on = k === id;
      buttons[k].setAttribute('aria-selected', String(on));
      buttons[k].tabIndex = on ? 0 : -1;
      panels[k].hidden = !on;
    }
    if (id === 'omat' && !own) {
      own = createGiftcardsTab({ api: null, gift, ctx, onOpenOrder: openOrder, searchFirst: true, initialSearch: (query.get('code') || '').trim(), browse: query.get('browse') === '1' });
      panels.omat.append(own.node);
      own.load();
      if (!query.get('code')) queueMicrotask(() => own.focusSearch());
    }
    if (id === 'lunastukset' && !claims) {
      claims = createVouchersTab({ api: null, vouchers, ctx, onOpenOrder: openOrder });
      panels.lunastukset.append(claims.node);
      claims.load();
    }
    const q = new URLSearchParams(location.hash.split('?')[1] || '');
    if (q.get('tab') !== id) history.replaceState(null, '', hrefFor(id));
    if (focus) buttons[id].focus();
  }
  const list = h('div', { class: 'tl-tabs', role: 'tablist', 'aria-label': navText('ui.admin.nav.giftcards'), 'data-testid': 'lahjakortit-tabs' },
    ...TABS.map(([id, key], i) => {
      const b = h('button', { type: 'button', role: 'tab', id: `lahjakortit-tab-${id}`, class: 'tl-tabbtn', 'aria-controls': `lahjakortit-pnl-${id}`, 'data-testid': `lahjakortit-tab-${id}`,
        onclick: () => select(id),
        onkeydown: (e) => {
          const nx = { ArrowRight: i + 1, ArrowLeft: i - 1, Home: 0, End: TABS.length - 1 }[e.key];
          if (nx == null) return;
          e.preventDefault();
          select(TABS[(nx + TABS.length) % TABS.length][0], true);
        } }, navText(key));
      buttons[id] = b;
      return b;
    }));
  for (const [id] of TABS) panels[id] = h('div', { role: 'tabpanel', id: `lahjakortit-pnl-${id}`, 'aria-labelledby': `lahjakortit-tab-${id}`, hidden: true, class: 'tl-panel-wrap' });
  const langs = h('div', { class: 'tl-langs tl-noprint', role: 'group', 'aria-label': t('lang.label') }, LANGS.map((l) => h('button', { type: 'button', class: 'tl-lang', 'aria-pressed': String(getLang() === l), 'data-testid': `lang-${l}`, lang: l,
    onclick: () => { if (getLang() === l) return; setLang(l); location.reload(); } }, l.toUpperCase())));
  const root = h('div', { class: 'tl', lang: getLang(), 'data-testid': 'lahjakortit' },
    h('div', { class: 'row between wrap tl-top tl-noprint' }, h('h1', { text: navText('ui.admin.nav.giftcards') }), langs),
    list, ...TABS.map(([id]) => panels[id]));
  select(tab);
  return root;
}
