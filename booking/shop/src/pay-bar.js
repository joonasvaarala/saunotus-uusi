// KAUPPA-KASSA-01: kassan alapalkki. Alle 900 px:n leveydellä summa ja maksuohje pysyvät lähetysnapin vieressä
// (sticky lomakkeen alareunassa), työpöydällä palkki on tavallinen lohko ja summa näkyy sivupalkissa.
// Ei omia tekstejä: yhteensä-, ALV- ja ohjetekstit annetaan ulkopuolelta (t.total, t.vatIncl, maksuohje).

// Palkin teksti: tyhjä/ei-merkkijono → ''.
export const barText = (v) => (typeof v === 'string' ? v.trim() : '');

// h = shop.js:n elementtirakentaja; submit = lähetysnappi (jää samaksi elementiksi, jotta testid ja tilat säilyvät).
export function createPayBar({ h, t, money, submit }) {
  const note = h('p', { class: 'bk-bar-note', 'data-testid': 'paybar-note', hidden: true });
  const total = h('strong', { class: 'bk-bar-total', 'data-testid': 'paybar-total' });
  const sum = h('p', { class: 'bk-bar-sum' }, h('span', { class: 'bk-bar-label', text: t.total }), ' ', total, ' ', h('small', { text: t.vatIncl }));
  const node = h('div', { class: 'bk-paybar', 'data-testid': 'paybar' }, note, h('div', { class: 'bk-bar-row' }, sum, submit));
  return {
    node,
    setTotal(amount) { total.textContent = typeof amount === 'number' ? money(amount) : barText(amount); },
    setNote(text, hidden = false) { const x = barText(text); note.textContent = x; note.hidden = hidden || !x; },
  };
}
