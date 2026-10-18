// Jaettu suodatinlaatikko hallinnan listoille: haku jää näkyviin, muut suodattimet ovat kiinni kunnes painike avaa ne.
// Aktiivinen suodatin (eri kuin oletus) säilyy kiinni ollessaankin, ja painikkeessa näkyy lukumäärä.
// status-solmu (esim. maksutilan siru) jää palkkiin näkyviin myös kun paneeli on kiinni.
import { h } from './ui.js';
import { icon } from './icons.js';
import { filterText } from './filter-texts.js';

let seq = 0;

function nodes(value) {
  return [].concat(value ?? []).flat().filter((n) => n != null && n !== false);
}

/** Kuinka moni kenttä poikkeaa oletuksesta. Vain defaults-avaimet lasketaan (haku ei kuulu niihin). */
export function countActive(values, defaults) {
  let n = 0;
  for (const k of Object.keys(defaults)) if (values?.[k] !== defaults[k]) n += 1;
  return n;
}

export function filterDrawer({ search, filters, activeCount, status, testid = 'filters', className = '', open = false }) {
  const panelId = `filter-panel-${++seq}`;
  const panel = h('div', { class: 'filter-panel', id: panelId, hidden: !open || null, 'data-testid': `${testid}-panel` }, ...nodes(filters));
  const label = h('span', { class: 'filter-toggle-label', 'data-testid': `${testid}-label` });
  const badge = h('span', { class: 'filter-badge', 'data-testid': `${testid}-count`, hidden: true });
  const chev = h('span', { class: 'filter-chev', 'aria-hidden': 'true' }, icon('chev', 18));
  const btn = h('button', {
    type: 'button',
    class: 'btn ghost filter-toggle',
    'aria-expanded': 'false',
    'aria-controls': panelId,
    'data-testid': `${testid}-toggle`,
    onclick: () => setOpen(btn.getAttribute('aria-expanded') !== 'true'),
  }, label, badge, chev);
  const root = h('div', { class: `filter-drawer${className ? ` ${className}` : ''}`, 'data-testid': testid },
    h('div', { class: 'filter-drawer-bar' }, ...nodes(search), ...nodes(status), btn), panel);

  function paint() {
    const on = btn.getAttribute('aria-expanded') === 'true';
    label.textContent = filterText(on ? 'ui.admin.filters.hide' : 'ui.admin.filters.show');
    const n = Math.max(0, Math.trunc(Number(typeof activeCount === 'function' ? activeCount() : 0) || 0));
    badge.hidden = n < 1;
    badge.textContent = n > 0 ? filterText('ui.admin.filters.active', { n: String(n) }) : '';
    root.classList.toggle('is-open', on);
    panel.hidden = !on;
  }
  function setOpen(on) {
    btn.setAttribute('aria-expanded', on ? 'true' : 'false');
    paint();
  }
  // Kentän oma kuuntelija ehtii päivittää tilan ennen kuin lukumäärä luetaan (kuplii paneelista).
  panel.addEventListener('change', () => paint());
  panel.addEventListener('input', () => paint());
  panel.addEventListener('click', () => paint());
  setOpen(!!open);
  return { node: root, refresh: paint, setOpen, button: btn, panel };
}
