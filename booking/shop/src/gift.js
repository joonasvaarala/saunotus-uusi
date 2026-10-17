// Lahjakorttisivu (/lahjakortti/, /en/gift-card/): verkkomyynti (public_gift_card_packages + public_buy_gift_card) ja saldotarkistus (public_check_gift_card).
// Näkyvyys: myyntilohko vain kun sale_enabled=true (korvaa silloin staattiset Johku-osiot #avoin ja #paketit); saldotarkistus vain kun redeem_enabled=true.
// Muuten sivu jää ennalleen (ei "ei vielä käytössä" -tekstejä). Sopimus: KOODARI_talous_A_D_fi.md §13.0, §13.2.
import { rpc } from './sb.js';
import { GT } from './gift-texts.js';
import { createGiftApi } from './gift-api.js';
import { h, makeFmt, phoneBox, field } from './gift-ui.js';
import * as G from './gift-logic.js';

const S = window.BOOKING_SHOP;
const L = GT[S.lang] ? S.lang : 'fi';
const F = makeFmt(L), { tx, money, date, pick } = F;
const api = createGiftApi({ rpc });

const saleRoot = document.getElementById('gift-app');
const balRoot = document.getElementById('gift-balance');
const show = (root) => { const sec = root?.closest('section'); if (sec) sec.hidden = false; root?.setAttribute('aria-busy', 'false'); };

function errText(r, ctx = {}) {
  const key = `err.${r?.code}`;
  return GT[L][key] ? tx(key, ctx) : (tx('err.generic'));
}

// ---------- Myynti ----------
function buildSale(pk) {
  const pkgs = pk.packages, by = new Map(pkgs.map((p) => [p.code, p]));
  const open = pkgs.find((p) => p.is_open), fixed = pkgs.filter((p) => !p.is_open);
  const months = (open || fixed[0])?.valid_months || 6;
  const lines = []; let seq = 0;
  const orderHref = (token) => `${S.orderHref?.[L] || '/tilaus/'}?t=${encodeURIComponent(token)}${api.mock ? '&mock=1&scenario=cards' : ''}`;
  const cartHost = h('div', { class: 'gc-cart', id: 'gc-cart' });
  const live = h('p', { class: 'sr', role: 'status', 'aria-live': 'polite' });
  const cap = () => G.cardsLeft(lines, pk.max_cards);

  // -- tarjotin
  const addLine = (code, amount) => {
    const p = by.get(code); if (!p) return false;
    if (cap() < 1) { live.textContent = tx('maxCardsReached', { n: pk.max_cards }); return false; }
    if (lines.length >= 10) { live.textContent = tx('maxCardsReached', { n: pk.max_cards }); return false; }
    lines.push({ id: ++seq, pkg: code, amount: amount ?? '', qty: 1, recipientName: '', recipientEmail: '', greeting: '' });
    renderCart(); live.textContent = `${tx('added')}: ${pick(p, 'name')}`;
    return true;
  };
  const tile = (p) => {
    // p.items ({label, persons, kb_product_id} | {persons, addon_code}) ei näytetä: sisältö kuvataan palvelimen description(_en)-kentässä (ei kielitettyjä item-nimiä)
    const meta = h('p', { class: 'gc-meta' }, p.is_open ? tx('amountFrom', { min: p.min_amount, max: p.max_amount }) : '', p.is_open ? ' · ' : '', tx('valid', { months: p.valid_months }));
    const kids = [h('p', { class: 'kicker', text: p.is_open ? tx('openKicker') : tx('pkgKicker') }), h('h3', { text: pick(p, 'name') }), pick(p, 'description') ? h('p', { class: 'gc-desc', text: pick(p, 'description') }) : null];
    if (p.is_open) {
      const amt = h('input', { type: 'text', inputmode: 'decimal', autocomplete: 'off', value: '', placeholder: '50' });
      const f = field({ label: tx('amountLabel'), control: amt, hint: tx('amountHint', { min: p.min_amount, max: p.max_amount }), name: 'open' });
      const btn = h('button', { type: 'button', class: 'btn gc-btn', text: tx('addOpen'), onclick: () => {
        const a = G.parseAmount(amt.value);
        if (a == null || a < p.min_amount || a > p.max_amount) { f.setError(tx('err.amount', { min: p.min_amount, max: p.max_amount })); amt.focus(); return; }
        f.setError(''); if (addLine(p.code, String(a))) amt.value = '';
      } });
      amt.addEventListener('input', () => f.setError(''));
      amt.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); btn.click(); } });
      kids.push(meta, f.wrap, btn);
    } else {
      kids.push(h('p', { class: 'gc-price' }, money(p.price), p.persons ? h('span', { class: 'gc-per', text: ` · ${tx('persons', { n: p.persons })}` }) : ''), meta,
        h('button', { type: 'button', class: 'btn gc-btn', text: tx('add'), 'aria-label': `${tx('add')}: ${pick(p, 'name')}`, onclick: () => addLine(p.code) }));
    }
    return h(p.is_open ? 'div' : 'li', { class: `gc-tile${p.is_open ? ' open' : ''}` }, kids);
  };
  const openTile = open ? h('div', { class: 'gc-open', id: 'avoin' }, tile(open)) : null;
  const pkgList = h('ul', { class: 'gc-pkgs', id: 'paketit', 'aria-label': tx('pkgKicker') }, fixed.map(tile));

  // -- ostoskori + lomake
  const buyer = { name: '', email: '', phone: '', marketing: false, terms: false };
  let buyerFields = null, totalEl = null, submitBtn = null, msg = null, lineEls = new Map();
  const updateTotal = () => {
    const tt = G.totals(lines, pkgs);
    if (totalEl) { totalEl.querySelector('.gc-sum').textContent = money(tt.total); totalEl.querySelector('.gc-cnt').textContent = tt.cards === 1 ? tx('cardsCount1') : tx('cardsCount', { n: tt.cards }); }
    for (const l of lines) { const e = lineEls.get(l.id); if (e) e.total.textContent = money(G.lineTotal(l, by.get(l.pkg))); }
  };
  function lineView(l) {
    const p = by.get(l.pkg), el = {};
    const fs = {};
    const qtyIn = h('input', { type: 'number', min: 1, max: pk.max_cards, step: 1, inputmode: 'numeric', value: l.qty, 'aria-label': tx('qty') });
    const setQty = (n) => { n = Math.max(1, Math.trunc(n) || 1); const others = lines.reduce((s, x) => s + (x === l ? 0 : x.qty), 0); if (n + others > pk.max_cards) { n = Math.max(1, pk.max_cards - others); live.textContent = tx('maxCards', { n: pk.max_cards }); } l.qty = n; qtyIn.value = n; updateTotal(); };
    qtyIn.addEventListener('change', () => setQty(Number(qtyIn.value)));
    const stepper = h('div', { class: 'bk-stepper' }, h('button', { type: 'button', class: 'bk-step', 'aria-label': tx('qtyMinus'), text: '−', onclick: () => setQty(l.qty - 1) }), qtyIn, h('button', { type: 'button', class: 'bk-step', 'aria-label': tx('qtyPlus'), text: '+', onclick: () => setQty(l.qty + 1) }));
    const rows = [];
    if (p.is_open) {
      const a = h('input', { type: 'text', inputmode: 'decimal', autocomplete: 'off', value: l.amount });
      fs.amount = field({ label: tx('amountLabel'), control: a, hint: tx('amountHint', { min: p.min_amount, max: p.max_amount }), name: 'amt' });
      a.addEventListener('input', () => { l.amount = a.value; fs.amount.setError(''); updateTotal(); });
      rows.push(fs.amount.wrap);
    }
    const rn = h('input', { type: 'text', maxlength: 120, autocomplete: 'off', value: l.recipientName });
    fs.recipientName = field({ label: tx('recipientName'), control: rn, name: 'rn' }); rn.addEventListener('input', () => { l.recipientName = rn.value; fs.recipientName.setError(''); });
    const re = h('input', { type: 'email', autocomplete: 'off', inputmode: 'email', value: l.recipientEmail });
    fs.recipientEmail = field({ label: tx('recipientEmail'), control: re, hint: tx('recipientEmailHint'), name: 're' }); re.addEventListener('input', () => { l.recipientEmail = re.value; fs.recipientEmail.setError(''); });
    const gr = h('textarea', { rows: 3 }); gr.value = l.greeting;
    fs.greeting = field({ label: tx('greeting'), control: gr, hint: tx('greetingHint', { max: G.GREETING_MAX }), name: 'gr' });
    const counter = h('p', { class: 'gc-counter', 'aria-live': 'polite' });
    const upd = () => { const g = G.greetingState(gr.value); counter.textContent = g.over ? tx('counterOver', { n: g.n, max: G.GREETING_MAX, over: -g.left }) : tx('counter', { n: g.n, max: G.GREETING_MAX }); counter.classList.toggle('gc-over', g.over); fs.greeting.setError(g.over ? tx('err.greeting', { max: G.GREETING_MAX }) : ''); };
    gr.addEventListener('input', () => { l.greeting = gr.value; upd(); }); upd();
    fs.greeting.wrap.append(counter);
    el.total = h('strong', { class: 'gc-ltotal', text: money(G.lineTotal(l, p)) });
    const li = h('li', { class: 'gc-line', 'data-line': l.id },
      h('div', { class: 'gc-lhead' }, h('h4', { text: pick(p, 'name') }), h('button', { type: 'button', class: 'gc-remove', text: tx('remove'), onclick: () => { lines.splice(lines.indexOf(l), 1); renderCart(); live.textContent = tx('remove'); } })),
      h('div', { class: 'gc-lqty' }, h('span', { class: 'gc-lab', text: tx('qty') }), stepper, h('span', { class: 'gc-lsum' }, h('span', { class: 'gc-lab', text: tx('lineTotal') }), ' ', el.total)),
      rows, fs.recipientName.wrap, fs.recipientEmail.wrap, fs.greeting.wrap);
    el.li = li; el.fs = fs; lineEls.set(l.id, el);
    return li;
  }
  function buyerField(key, label, type, extra = {}) {
    const input = h('input', { type, autocomplete: extra.ac, inputmode: extra.im, ...extra.attrs });
    const f = field({ label, control: input, name: key });
    input.addEventListener('input', () => { buyer[key] = input.value; f.setError(''); });
    return f;
  }
  function renderCart() {
    lineEls = new Map();
    if (!lines.length) { cartHost.replaceChildren(h('div', { class: 'gc-card gc-empty' }, h('h3', { text: tx('cartTitle') }), h('p', { class: 'bk-note', text: tx('cartEmpty') }))); totalEl = null; return; }
    const keep = buyerFields;
    if (!buyerFields) {
      buyerFields = { name: buyerField('name', tx('name'), 'text', { ac: 'name' }), email: buyerField('email', tx('email'), 'email', { ac: 'email', im: 'email' }), phone: buyerField('phone', tx('phone'), 'tel', { ac: 'tel', im: 'tel' }) };
      buyerFields.terms = h('input', { type: 'checkbox', id: 'gc-terms' }); buyerFields.terms.addEventListener('change', () => { buyer.terms = buyerFields.terms.checked; buyerFields.termsErr.textContent = ''; });
      buyerFields.termsErr = h('p', { class: 'gc-err', id: 'gc-terms-e', role: 'alert' });
      buyerFields.marketing = h('input', { type: 'checkbox', id: 'gc-mkt' }); buyerFields.marketing.addEventListener('change', () => { buyer.marketing = buyerFields.marketing.checked; });
    }
    void keep;
    totalEl = h('div', { class: 'gc-total' }, h('span', { class: 'gc-cnt' }), h('span', { class: 'gc-tl' }, h('span', { text: `${tx('total')} ` }), h('strong', { class: 'gc-sum' }), h('span', { class: 'bk-note', text: ` (${tx('vatIncl')})` })));
    msg = h('div', { class: 'gc-msg', role: 'alert' });
    submitBtn = h('button', { type: 'submit', class: 'btn gc-submit', text: tx('submit') });
    const form = h('form', { class: 'bk-form gc-form', novalidate: true, 'aria-label': tx('cartTitle'), onsubmit: onSubmit },
      h('fieldset', { class: 'gc-card' }, h('legend', { text: tx('cartTitle') }), h('ul', { class: 'gc-lines' }, lines.map(lineView))),
      h('fieldset', { class: 'gc-card' }, h('legend', { text: tx('buyerTitle') }), buyerFields.name.wrap, buyerFields.email.wrap, buyerFields.phone.wrap,
        h('div', { class: 'bk-check' }, buyerFields.terms, h('label', { for: 'gc-terms' }, `${tx('acceptTerms')} `, h('a', { href: S.termsHref, target: '_blank', rel: 'noopener', text: tx('termsLink') }), ' *')), buyerFields.termsErr,
        h('div', { class: 'bk-check' }, buyerFields.marketing, h('label', { for: 'gc-mkt', text: tx('marketing') }))),
      totalEl, msg, submitBtn);
    // palauta jo täytetyt ostajatiedot
    for (const k of ['name', 'email', 'phone']) buyerFields[k].control.value = buyer[k];
    buyerFields.terms.checked = buyer.terms; buyerFields.marketing.checked = buyer.marketing;
    cartHost.replaceChildren(form);
    updateTotal();
  }
  async function onSubmit(ev) {
    ev.preventDefault(); if (submitBtn.disabled) return;
    msg.replaceChildren(); let firstBad = null; const mark = (f, m) => { f.setError(m); if (!firstBad) firstBad = f.control; };
    for (const l of lines) {
      const p = by.get(l.pkg), er = G.validateLine(l, p), fs = lineEls.get(l.id).fs;
      if (er.amount) mark(fs.amount, tx('err.amount', { min: p.min_amount, max: p.max_amount }));
      if (er.recipientName) mark(fs.recipientName, tx('err.recipientName'));
      if (er.recipientEmail) mark(fs.recipientEmail, tx('err.recipientEmail'));
      if (er.greeting) mark(fs.greeting, tx('err.greeting', { max: G.GREETING_MAX }));
    }
    const be = G.validateBuyer(buyer);
    for (const k of ['name', 'email', 'phone']) if (be[k]) mark(buyerFields[k], tx(`err.${k}`));
    if (be.terms) { buyerFields.termsErr.textContent = tx('err.terms'); if (!firstBad) firstBad = buyerFields.terms; }
    if (firstBad) { msg.append(h('p', { class: 'bk-error', text: tx('err.fix') })); firstBad.focus(); return; }
    submitBtn.disabled = true; submitBtn.textContent = tx('submitting');
    try {
      const r = await api.buy(G.buyArgs({ lines, pkgs, buyer, locale: L }));
      if (r?.ok) return done(r);
      msg.append(h('p', { class: 'bk-error', text: r?.notReady ? tx('notReady') : errText(r, { n: pk.max_cards, min: open?.min_amount, max: open?.max_amount }) }));
    } catch { msg.append(h('p', { class: 'bk-error', text: tx('err.generic') }), phoneBox(S, tx)); }
    submitBtn.disabled = false; submitBtn.textContent = tx('submit');
  }
  function done(r) {
    const cards = (r.cards || []);
    const list = cards.length ? h('ul', { class: 'gc-donecards' }, cards.map((c) => h('li', {}, h('strong', { text: c.package_name ? (L === 'en' ? (by.get(c.package_code)?.name_en || c.package_name) : c.package_name) : c.package_code }), ` · ${money(c.amount)}`, c.recipient_name ? ` · ${c.recipient_name}` : ''))) : null;
    const box = h('section', { class: 'bk-conf pending gc-done', 'aria-labelledby': 'gc-done-h', tabindex: '-1' },
      h('h3', { id: 'gc-done-h', text: tx('doneTitle') }), h('span', { class: 'bk-status', text: tx('doneStatus') }),
      h('dl', { class: 'bk-sum' }, h('dt', { text: tx('doneOrder') }), h('dd', { text: `#${r.order_no}` }), h('dt', { text: tx('doneTotal') }), h('dd', { text: money(r.total) })), list,
      h('p', { text: tx('doneNote') }), r.payment_url ? h('p', {}, h('a', { class: 'btn', href: r.payment_url, text: tx('donePay') })) : h('p', { class: 'bk-pay', text: tx('donePayLater') }),
      h('div', { class: 'bk-actions' }, r.token ? h('a', { class: 'btn', href: orderHref(r.token), text: tx('doneOpen') }) : null, h('button', { type: 'button', class: 'btn light', text: tx('doneNew'), onclick: () => { lines.length = 0; buyerFields = null; Object.assign(buyer, { name: '', email: '', phone: '', marketing: false, terms: false }); renderCart(); cartHost.scrollIntoView({ block: 'start' }); } })), phoneBox(S, tx));
    cartHost.replaceChildren(box); box.focus(); box.scrollIntoView({ block: 'start' });
  }
  renderCart();
  return h('div', { class: 'gc' },
    api.mock ? h('p', { class: 'ord-mock', text: tx('mockBanner') }) : null,
    h('header', { class: 'bk-head' }, h('p', { class: 'kicker', text: tx('buyTitle') }), h('h2', { text: tx('chooseTitle') }), h('p', { class: 'lead', text: tx('buyLead', { months }) })),
    openTile, pkgList, live, h('section', { class: 'gc-cartsec', 'aria-labelledby': 'gc-cart-h' }, h('h2', { id: 'gc-cart-h', class: 'sr', text: tx('cartTitle') }), cartHost));
}

// ---------- Saldotarkistus ----------
function buildBalance() {
  const code = h('input', { type: 'text', autocomplete: 'off', autocapitalize: 'characters', spellcheck: 'false', inputmode: 'text', maxlength: 24, placeholder: 'HHXX-XXXX-XXXX' });
  const f = field({ label: tx('balCode'), control: code, hint: tx('balHint'), name: 'bal' });
  const out = h('div', { class: 'gc-balout', 'aria-live': 'polite' });
  const btn = h('button', { type: 'submit', class: 'btn gc-btn', text: tx('balBtn') });
  code.addEventListener('input', () => { const pos = code.selectionStart; const v = G.formatCodeTyping(code.value); if (v !== code.value) { code.value = v; try { code.setSelectionRange(v.length, v.length); } catch { void pos; } } f.setError(''); });
  const row = (k, v) => [h('dt', { text: tx(k) }), h('dd', { text: v })];
  async function submit(ev) {
    ev.preventDefault(); out.replaceChildren(); if (btn.disabled) return;
    if (!G.codeComplete(code.value)) { f.setError(tx('err.code_incomplete')); code.focus(); return; }
    btn.disabled = true; btn.textContent = tx('balChecking');
    try {
      const r = await api.check(code.value);
      if (r?.ok) {
        const st = GT[L][`bst.${r.status}`] ? r.status : 'active';
        out.append(h('div', { class: 'gc-card gc-result' }, h('span', { class: `ord-badge ${r.status === 'active' ? 'st-confirmed' : r.status === 'expired' ? 'st-expired' : 'st-pending'}`, text: tx(`bst.${st}`) }),
          h('dl', { class: 'bk-sum' }, row('balCardCode', r.code), row('balBalance', money(r.balance)), r.initial_amount != null && +r.initial_amount !== +r.balance ? row('balInitial', money(r.initial_amount)) : [], r.package_name ? row('balPackage', r.package_name) : [], r.valid_to ? row('balValidTo', date(r.valid_to)) : []),
          !r.redeemable && r.not_redeemable_reason && r.status === 'active' ? h('p', { class: 'bk-note', text: GT[L][`nr.${r.not_redeemable_reason}`] ? tx(`nr.${r.not_redeemable_reason}`) : '' }) : null,
          !r.redeemable && r.not_redeemable_reason && r.status !== 'active' && GT[L][`nr.${r.not_redeemable_reason}`] ? h('p', { class: 'bk-note', text: tx(`nr.${r.not_redeemable_reason}`) }) : null));
      } else if (r?.notReady) out.append(h('p', { class: 'bk-error', text: tx('notReady') }));
      else out.append(h('p', { class: 'bk-error', role: 'alert', text: errText(r) }));
    } catch { out.append(h('p', { class: 'bk-error', role: 'alert', text: tx('err.generic') })); }
    btn.disabled = false; btn.textContent = tx('balBtn');
  }
  return h('div', { class: 'gc gc-bal' },
    h('header', { class: 'bk-head' }, h('h2', { text: tx('balTitle') }), h('p', { class: 'lead', text: tx('balLead') })),
    h('form', { class: 'bk-form gc-balform', novalidate: true, onsubmit: submit }, f.wrap, btn), out);
}

async function main() {
  let pk;
  try { pk = await api.packages(); } catch { return; }          // verkko-/palvelinvika → sivu jää staattiseksi (Johku)
  if (!pk?.ok) return;                                           // puuttuva RPC / virhe → ei muutoksia
  if (pk.sale_enabled && saleRoot && pk.packages.length) {
    document.getElementById('avoin')?.remove(); document.getElementById('paketit')?.remove();   // staattiset Johku-osiot korvataan
    saleRoot.replaceChildren(buildSale(pk)); show(saleRoot);
  }
  if (pk.redeem_enabled && balRoot) { balRoot.replaceChildren(buildBalance()); show(balRoot); }
  if (location.hash) { const t = document.getElementById(location.hash.slice(1)); t?.scrollIntoView(); }
}
main();
