// Kyllä/ei -dialogi. Palauttaa true vain Kyllä-painikkeesta.
import { h, dialog } from './ui.js';

export function confirmDialog({ title, body, yes, no, testid = 'confirm-dialog' }) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (value) => { if (settled) return; settled = true; resolve(value); };
    const yesBtn = h('button', { type: 'button', class: 'btn primary', 'data-testid': 'confirm-yes', text: yes, onclick: () => { finish(true); d.close(); } });
    const noBtn = h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'confirm-no', text: no, onclick: () => { finish(false); d.close(); } });
    const paragraphs = (Array.isArray(body) ? body : [body]).filter(Boolean).map((text) => h('p', { text }));
    const d = dialog(title, h('div', { class: 'stack', 'data-testid': testid },
      ...paragraphs,
      h('div', { class: 'row wrap', style: 'justify-content:flex-end' }, noBtn, yesBtn)));
    d.addEventListener('close', () => finish(false));
    yesBtn.focus();
  });
}
