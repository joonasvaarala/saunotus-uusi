// Vuosikorttikoodin näyttö kassalla (booking_146): koodi isona + Kopioi koodi, voimassaolo ja sähköpostin tila.
// Käyttö: Talous › Tilaukset -tilauksen tiedot (vuosikorttitilaus) ja dialogi heti maksun kirjauksen jälkeen. Tekstit: ../annual-card-texts.js.
import { h, dialog } from '../ui.js';
import { fmt } from '../talous-i18n.js';
import { acText } from '../annual-card-texts.js';
import { annualCardModel } from '../annual-card-logic.js';

async function copyText(text, node) {
  try { if (navigator.clipboard?.writeText) { await navigator.clipboard.writeText(text); return true; } } catch { /* varatapa alla */ }
  try {
    const r = document.createRange(); r.selectNodeContents(node); const s = getSelection(); s.removeAllRanges(); s.addRange(r);
    return document.execCommand?.('copy') === true;
  } catch { return false; }
}

/** Palauttaa DOM-solmun tai null (ei vuosikorttitilaus). */
export function annualCardPanel(info) {
  const m = annualCardModel(info);
  if (!m) return null;
  if (m.state !== 'card') return h('div', { class: 'ac-panel', 'data-testid': 'annual-card' }, h('p', { class: 'ac-mail warn', 'data-testid': 'annual-card-note', text: acText(m.noteKey) }));
  const code = h('output', { class: 'ac-code', 'data-testid': 'annual-card-code', 'aria-label': acText('ui.admin.annual_card.code_label'), text: m.code });
  const live = h('span', { class: 'muted ac-copied', role: 'status', 'aria-live': 'polite', 'data-testid': 'annual-card-copied' });
  const btn = h('button', { type: 'button', class: 'btn', 'data-testid': 'annual-card-copy', text: acText('ui.admin.annual_card.copy'),
    onclick: async () => { live.textContent = (await copyText(m.code, code)) ? acText('ui.admin.annual_card.copied') : acText('ui.admin.annual_card.copy_failed'); } });
  return h('div', { class: 'ac-panel', 'data-testid': 'annual-card' },
    h('span', { class: 'ac-label', text: acText('ui.admin.annual_card.code_label') }), code,
    h('div', { class: 'ac-row' }, btn, live),
    h('p', { class: 'ac-valid', 'data-testid': 'annual-card-valid', text: acText('ui.admin.annual_card.valid', { from: fmt.date(m.from), to: fmt.date(m.to) }) }),
    m.cardNoteKey ? h('p', { class: 'ac-mail err', text: acText(m.cardNoteKey) }) : null,
    h('p', { class: `ac-mail ${m.mail.tone}`, 'data-testid': 'annual-card-email', 'data-status': m.mail.status, text: acText(m.mail.key, { to: m.mail.to }) }),
    h('p', { class: 'muted ac-tell', text: acText('ui.admin.annual_card.tell') }));
}

/** Maksun kirjauksen jälkeen: dialogi, jos tilauksesta syntyi vuosikortti. Palauttaa dialogin tai null. */
export function showAnnualCardDialog(info) {
  const m = annualCardModel(info);
  if (!m || m.state !== 'card') return null;
  let d = null;
  d = dialog(acText('ui.admin.annual_card.created'), h('div', { class: 'stack' }, annualCardPanel(info),
    h('button', { type: 'button', class: 'btn primary', 'data-testid': 'annual-card-close', text: acText('ui.admin.annual_card.close'), onclick: () => d.close() })));
  d.setAttribute('data-testid', 'annual-card-dialog');
  return d;
}
