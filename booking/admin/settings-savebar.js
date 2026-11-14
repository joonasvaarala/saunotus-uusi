// Yksi kiinnitetty tallennuspalkki per asetusvälilehti: "2 muutosta · Tallenna · Hylkää" (HALL-ASETUKSET-01).
// Osiot tallennetaan samalla admin_save_settings-kutsulla kuin ennen (yksi kutsu per muuttunut osio), mutta käyttäjälle on yksi painike.
import { rpc } from './sb.js';
import { h, toast, run } from './ui.js';
import { tx } from './settings-widgets.js';
import { validateSection, dirtySections } from './settings-logic.js';

export function countLabel(n) {
  return n === 1 ? tx('bar_one') : `${n} ${tx('bar_many')}`;
}

/** Palauttaa { node, section(id, collect), watch(root) }. section() ottaa lähtötilanteen heti, joten kutsu vasta kun kentät on rakennettu. */
export function createSaveBar({ reload, testid = 'settings-bar' } = {}) {
  const sections = [];
  const label = h('span', { class: 'set-bar-count', role: 'status', 'aria-live': 'polite' });
  const save = h('button', { class: 'btn primary', type: 'button', text: tx('save'), 'data-testid': 'settings-save' });
  const discard = h('button', { class: 'btn', type: 'button', text: tx('discard'), 'data-testid': 'settings-discard' });
  const node = h('div', { class: 'set-bar set-noprint', hidden: true, 'data-testid': testid }, label, h('div', { class: 'row' }, discard, save));

  const state = () => dirtySections(sections.map((s) => ({ id: s.id, base: s.base, now: s.collect() })));
  const refresh = () => {
    const { count } = state();
    node.hidden = count === 0;
    label.textContent = count ? countLabel(count) : '';
  };
  discard.addEventListener('click', () => { if (reload) reload(); });
  save.addEventListener('click', () => run(save, async () => {
    const { dirty } = state();
    const todo = [];
    for (const id of dirty) {
      const sec = sections.find((s) => s.id === id);
      const now = sec.collect();
      const check = validateSection(id, now);
      if (!check.ok) throw Object.assign(new Error(check.message), { code: check.code });
      todo.push({ sec, now, value: check.value });
    }
    for (const t of todo) {
      await rpc('admin_save_settings', { p_section: t.sec.id, p: t.value });
      t.sec.base = t.now;
      refresh();
    }
    toast(tx('saved'));
    if (reload) await reload();
  }));

  return {
    node,
    section(id, collect) { sections.push({ id, collect, base: collect() }); },
    watch(root) { for (const ev of ['input', 'change']) root.addEventListener(ev, refresh); refresh(); },
    refresh,
  };
}
