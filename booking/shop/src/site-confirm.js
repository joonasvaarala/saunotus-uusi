// Sivuston oma vahvistusdialogi selaimen confirm()-ikkunan tilalle (kauppa ja tilaussivu). Palauttaa Promise<boolean>.
// Esc / Takaisin = false. Fokus palaa avanneeseen elementtiin. Ilman <dialog>-tukea → selaimen confirm().
export function siteConfirm(body, { yes, no, testid = 'site-confirm', doc = globalThis.document } = {}) {
  const d = doc?.createElement?.('dialog');
  if (!d || typeof d.showModal !== 'function') return Promise.resolve(globalThis.confirm(body));
  const back = doc.activeElement;
  d.className = 'bk-dialog'; d.dataset.testid = testid; d.setAttribute('aria-describedby', `${testid}-body`);
  const p = doc.createElement('p'); p.id = `${testid}-body`; p.textContent = body;
  const row = doc.createElement('div'); row.className = 'bk-dialog-actions';
  const bNo = doc.createElement('button'); bNo.type = 'button'; bNo.className = 'btn light'; bNo.textContent = no; bNo.dataset.testid = `${testid}-no`;
  const bYes = doc.createElement('button'); bYes.type = 'button'; bYes.className = 'btn'; bYes.textContent = yes; bYes.dataset.testid = `${testid}-yes`;
  row.append(bNo, bYes); d.append(p, row); doc.body.append(d);
  return new Promise((resolve) => {
    let val = false;
    bYes.onclick = () => { val = true; d.close(); };
    bNo.onclick = () => d.close();
    d.addEventListener('close', () => { d.remove(); back?.focus?.(); resolve(val); }, { once: true });
    d.showModal(); bNo.focus();
  });
}
