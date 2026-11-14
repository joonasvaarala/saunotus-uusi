// HALL-AVOIMET-01: Tilaukset › Avoimet maksut. Yksi työjono kahdella osiolla: Maksulinkit (seurattavat maksut) ja Hyvitykset
// (hyvitysten seuranta). Osiot ovat entiset näkymät upotettuina; toiminnot, oikeudet ja RPC:t ovat ennallaan.
import { h } from '../ui.js';
import { navText } from '../nav-texts.js';
import { op } from '../open-payments-texts.js';
import { canSeePaylinks, canSeeRefunds } from '../open-payments-logic.js';

export async function render({ ctx, refs, reload }) {
  const parts = [];
  if (canSeePaylinks(ctx?.can)) parts.push(['links', op('ui.admin.open_payments.links'), () => import('./paylink-watch.js')]);
  if (canSeeRefunds(ctx?.can, ctx?.role)) parts.push(['refunds', op('ui.admin.open_payments.refunds'), () => import('./refund-watch.js')]);
  const host = h('div', { class: 'open-payments', 'data-testid': 'open-payments' });
  const sections = await Promise.all(parts.map(async ([key, title, load]) => {
    const sec = h('section', { class: 'open-payments-sec', 'data-testid': `open-payments-${key}`, 'aria-label': title });
    try {
      const mod = await load();
      const out = await mod.render({ ctx, refs, reload, embedded: true, title });
      sec.append(...[].concat(out).filter(Boolean));
    } catch (e) {
      sec.append(h('h2', { class: 'view-title', text: title }), h('p', { class: 'err', role: 'alert', text: navText('ui.admin.nav.load_failed', { error: e?.message || String(e) }) }));
    }
    return sec;
  }));
  host.append(...sections);
  return host;
}
