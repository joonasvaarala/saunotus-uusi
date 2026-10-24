// Manuaalinen varaus (puhelin, paikan päällä, sähköposti): 1 Vuoro ja päivä → 2 Henkilömäärä → 3 Asiakas → 4 Lisäpalvelut → 5 Maksu ja hinta → 6 Muistiinpano.
// Vuosikorttiasiakkaalle yleiseen vuoroon: "Vuosikorttivaraus" (ilmainen, 1 hlö, yksi tuleva varaus kerrallaan).
// Teksti FI/EN (../nb-texts.js, kieli kuten Talous-näkymillä). Palvelinkutsut (admin_create_booking jne.) ja niiden parametrit ovat ennallaan; vain käyttöliittymä on uusittu.
import { rpc } from '../sb.js';
import { customerForm, customerSearch } from './customerform.js';
import { warningBox, hasWarning } from './therapist.js';
import { addonPicker } from './addons.js';
import { reservationDialog } from './shared.js';
import { h, toast, errMsg, fmtTime, fmtDay, money, todayHel, addDays, empty, revealSection, revealIfHidden } from '../ui.js';
import { icon } from '../icons.js';
import { stepper } from '../stepper.js';
import { nbt as T, nbLang } from '../nb-texts.js';
import { setLang, LANGS, getLang } from '../talous-i18n.js';
import { priceFor, personsRange, effectiveKind, invoiceRefFor, paidDefault, parsePrice, summary } from '../nb-logic.js';
import { typeSwitch, render as renderResource } from './resbooking.js';

export async function render({ ctx, refs, query, reload }) {
  const kind = query.get('tyyppi');   // migraatio 17: resurssivaraus / vanha varaus omalla lomakkeellaan
  if (kind === 'resurssi' || kind === 'vanha') return renderResource({ ctx, refs, query, kind });
  const addons = await rpc('admin_list_addons').catch(() => []);
  const st = { date: /^\d{4}-\d\d-\d\d$/.test(query.get('d') || '') ? query.get('d') : todayHel(), session: null, customer: null, pre: query.get('r') && query.get('t') ? { r: query.get('r'), t: query.get('t') } : null };
  const root = h('div', { class: 'stack nb' });
  const sessionsBox = h('div', { class: 'stack' }); const formBox = h('div', {}); const result = h('div', { class: 'nb-result' });
  const loadDay = () => { st.session = null; loadSessions(); drawForm(); };
  const dateIn = h('input', { type: 'date', id: 'nb-date', value: st.date, onchange: (e) => { if (!/^\d{4}-\d\d-\d\d$/.test(e.target.value)) return; st.date = e.target.value; loadDay(); } });
  const shiftDay = (n) => { st.date = addDays(st.date, n); dateIn.value = st.date; loadDay(); };
  const dayCtl = h('div', { class: 'nb-dayctl' },
    h('button', { type: 'button', class: 'btn ghost nb-daybtn', 'aria-label': T('nb.prevDay'), onclick: () => shiftDay(-1) }, icon('pgprev', 22)), dateIn,
    h('button', { type: 'button', class: 'btn ghost nb-daybtn', 'aria-label': T('nb.nextDay'), onclick: () => shiftDay(1) }, icon('pgnext', 22)));
  const slotName = (s) => refs.productById.get(s.product_id)?.name || s.label;
  async function loadSessions() {
    sessionsBox.replaceChildren(h('p', { class: 'muted', text: T('nb.loading') }));
    const v = await rpc('admin_day_view', { p_date: st.date });
    const list = (v.sessions || []).filter((s) => s.status !== 'closed');
    // booking_139: voimassa olevat jonotuspidot (admin_day_view.waitlist_holds). Henkilökunta voi ohittaa pidon; näytetään vuoron kohdalla.
    const holds = new Map();
    for (const w of v.waitlist_holds || []) { const k = `${w.rule_id}|${Date.parse(w.starts_at)}`; const o = holds.get(k) || { n: 0, until: w.hold_expires_at }; o.n += +w.persons || 0; if (w.hold_expires_at > o.until) o.until = w.hold_expires_at; holds.set(k, o); }
    for (const s of list) s.wlHold = holds.get(`${s.rule_id}|${Date.parse(s.starts_at)}`) || null;
    const holdTxt = (s) => (s.wlHold ? ` · ${T('nb.hold', { n: s.wlHold.n, time: fmtTime(s.wlHold.until) })}` : '');
    // booking_148: yksityisvuoron pito koskee koko vuoroa → ei henkilömäärää.
    const holdPrivTxt = (s) => (s.wlHold ? ` · ${T('nb.holdPriv', { time: fmtTime(s.wlHold.until) })}` : '');
    if (st.pre) { const m = list.find((s) => String(s.rule_id) === st.pre.r && s.starts_at === st.pre.t && s.status === 'available'); st.pre = null; if (m) st.session = m; }   // Vapaana-napista (päivänäkymä): esivalittu vuoro
    sessionsBox.replaceChildren(list.length ? h('div', { class: 'slotpick', role: 'radiogroup', 'aria-label': T('nb.slots') }, list.map((s) => {
      const ok = s.status === 'available';
      const b = h('button', { type: 'button', role: 'radio', 'aria-checked': st.session?.rule_id === s.rule_id ? 'true' : 'false', class: `slotbtn ${s.status}`, disabled: !ok || null, onclick: () => { st.session = s; sessionsBox.querySelectorAll('.slotbtn').forEach((x) => x.setAttribute('aria-checked', 'false')); b.setAttribute('aria-checked', 'true'); drawForm(true); } },
        h('strong', { text: `${fmtTime(s.starts_at)}–${fmtTime(s.ends_at)}` }), h('span', { text: slotName(s) }), h('small', { text: ok ? (s.mode === 'exclusive' ? T('nb.privFree') + holdPrivTxt(s) : T('nb.free', { n: s.remaining }) + holdTxt(s)) : s.status === 'full' ? T('nb.full') : T('nb.na') }));
      return b;
    })) : empty(T('nb.noSlots')));
  }
  // Esivalittu vuoro voi piirtyä ennen kuin sivu on liitetty DOMiin.
  function revealForm(f, tries = 0) {
    if (!f.isConnected) { if (tries < 20) setTimeout(() => revealForm(f, tries + 1), 60); return; }
    revealSection(f, f.querySelector('h3'));
  }
  // Osio: numeroitu otsikko (CSS-laskuri .nb-h::before; piilotetut osiot eivät kuluta numeroa)
  const section = (title, ...kids) => h('section', { class: 'card nb-sec' }, h('h3', { class: 'nb-h', text: title }), ...kids);
  const fieldErr = () => h('small', { class: 'fld-err', role: 'status', hidden: true });
  const showFieldErr = (input, errEl, msg) => { errEl.textContent = msg; errEl.hidden = false; input.setAttribute('aria-invalid', 'true'); };
  const clearFieldErr = (input, errEl) => { errEl.hidden = true; input.removeAttribute('aria-invalid'); };

  function drawForm(reveal = false) {
    const s = st.session;
    if (!s) { formBox.replaceChildren(h('p', { class: 'muted nb-hint', text: T('nb.pickSlot') })); return; }
    const rng = personsRange(s);
    const pers = stepper({ label: T('nb.persons'), value: rng.min, min: rng.min, max: Math.max(rng.min, rng.max), inputName: 'n', size: 'lg', onChange: () => upd() });
    const persHint = h('small', { class: 'fld-hint', text: s.mode === 'exclusive' ? T('nb.personsHintMin', { min: rng.min, max: rng.max }) + (s.wlHold ? ` ${T('nb.holdHintPriv', { time: fmtTime(s.wlHold.until) })}` : '') : T('nb.personsHint', { free: s.remaining, min: rng.min }) + (s.wlHold ? ` ${T('nb.holdHint', { n: s.wlHold.n, time: fmtTime(s.wlHold.until) })}` : '') });
    const persErr = fieldErr();
    const priceIn = h('input', { type: 'text', inputmode: 'decimal', name: 'price', autocomplete: 'off', placeholder: T('nb.priceAuto') });
    const priceErr = fieldErr(); priceIn.addEventListener('input', () => { clearFieldErr(priceIn, priceErr); upd(); });
    const priceHint = h('small', { class: 'fld-hint' });
    const priceBox = h('details', { class: 'nb-price' }, h('summary', { text: T('nb.priceOpen') }), h('label', { class: 'fld' }, h('span', { class: 'fld-lab', text: T('nb.price') }), priceIn, priceHint, priceErr));
    const sumLines = h('span', { class: 'nb-sum-lines' }), sumTotal = h('strong', { class: 'nb-sum-total' });
    const errBox = h('p', { class: 'nb-err', role: 'alert', hidden: true, 'data-testid': 'form-error' });
    const cardChk = h('input', { type: 'checkbox', name: 'cardbooking' });
    const cardRow = h('label', { class: 'check big cardrow', hidden: true }, cardChk, h('span', {}, h('strong', { text: T('nb.card') }), h('small', { text: T('nb.cardHint') })));
    let picker = null, paySec = null, persSec = null;
    const upd = () => {
      const card = cardChk.checked;
      const ad = card ? 0 : picker.total();
      const ov = parsePrice(priceIn.value);
      const n = pers.get();
      const sm = summary({ session: s, persons: n, override: ov, addons: ad, annualCard: card });
      priceHint.textContent = T('nb.priceHint', { auto: money(priceFor(s, n)) });
      sumLines.textContent = card ? T('nb.sumCard') : ad ? `${T('nb.sumSlot')} ${money(sm.slot)} + ${T('nb.sumAddons').toLowerCase()} ${money(ad)}` : sm.overridden ? `${T('nb.sumSlot')} (${T('nb.ownPrice')}) ${money(sm.slot)}` : '';
      sumTotal.textContent = money(sm.total);
    };
    picker = addonPicker(addons, { getPersons: () => pers.get(), getMode: () => s.mode, onChange: () => upd() });
    const invRef = h('input', { name: 'invref', maxlength: 100, autocomplete: 'off' });
    const invFld = h('label', { class: 'fld', hidden: true, 'data-testid': 'invref-field' }, h('span', { class: 'fld-lab' }, T('nb.invref'), h('span', { class: 'opt', text: ` (${T('nb.optional')})` })), invRef, h('small', { class: 'fld-hint', text: T('nb.invrefHint') }));
    const ui = {}; let paidTouched = false;
    const paid = h('input', { type: 'checkbox', name: 'paid' });
    paid.addEventListener('change', () => { paidTouched = true; });
    const method = h('select', { name: 'method' }, refs.methods.filter((m) => m.active).map((m) => h('option', { value: m.code, text: m.label, selected: m.code === 'pay_later' || null })));
    method.addEventListener('change', () => { if (!paidTouched) paid.checked = paidDefault(method.value); });
    ui.method = method;
    const kindNow = () => effectiveKind(st.customer, cf.kind());
    // Laskun viite vain yritysasiakkaalle: yksityiseksi vaihtuessa kenttä tyhjennetään ja piilotetaan
    const syncInv = () => { const co = kindNow() === 'company'; invFld.hidden = !co; if (!co) invRef.value = ''; };
    const syncCard = () => {
      const ok = st.customer?.customer_type === 'annual_card' && s.mode === 'shared'; cardRow.hidden = !ok; if (!ok) cardChk.checked = false;
      const card = cardChk.checked;
      if (card) picker.node.hidden = true; else picker.sync();
      persSec.hidden = card; paySec.hidden = card; upd();
    };
    cardChk.addEventListener('change', syncCard);
    const cf = customerForm({ id: 'nb', reference: false, onKind: (k) => {
      if (ui.method && !st.customer) { ui.method.value = k === 'company' && refs.methods.some((m) => m.active && m.code === 'invoice') ? 'invoice' : 'pay_later'; if (!paidTouched) paid.checked = paidDefault(ui.method.value); }
      ui.syncInv?.();
    } });
    ui.syncInv = syncInv;
    const cs = customerSearch({ cf, st, onChange: () => { syncCard(); syncInv(); } });
    cf.elements.name.addEventListener('input', () => { if (st.customer) cs.reset(); });

    persSec = section(T('nb.s2'), h('div', { class: 'nb-persons' }, pers.node, h('div', { class: 'nb-persinfo' }, persHint, persErr)));
    const custSec = section(T('nb.s3'), h('div', { class: 'nb-search' }, h('span', { class: 'fld-lab', text: T('cu.search') }), cs.row, cs.found), h('p', { class: 'nb-or muted', text: T('cu.or') }), cf.node, cardRow);
    picker.node.classList.add('nb-sec', 'card');
    paySec = section(T('nb.s5'),
      h('label', { class: 'fld' }, h('span', { class: 'fld-lab', text: T('nb.method') }), method),
      invFld,
      h('label', { class: 'check big' }, paid, h('span', {}, h('strong', { text: T('nb.paid') }), h('small', { text: T('nb.paidHint') }))),
      priceBox);
    const noteSec = section(T('nb.s6'), h('label', { class: 'fld' }, h('span', { class: 'fld-lab', text: T('nb.note') }), h('textarea', { name: 'note', rows: 3 }), h('small', { class: 'fld-hint', text: T('nb.noteHint') })));
    const saveBtn = h('button', { class: 'btn primary lg', type: 'submit', 'data-testid': 'save-booking', text: T('nb.save') });
    const bar = h('div', { class: 'nb-bar' }, errBox, h('div', { class: 'nb-bar-row' }, h('div', { class: 'nb-sum', 'data-testid': 'price-summary', 'aria-live': 'polite' }, sumLines, h('span', { class: 'nb-sum-tot' }, T('nb.sumTotal'), ' ', sumTotal)), saveBtn));

    const f = h('form', { class: 'stack nbform', 'data-testid': 'booking-form', novalidate: true, onsubmit: async (ev) => {
      ev.preventDefault(); errBox.hidden = true;
      const card = cardChk.checked; const bad = []; let count = 0;
      const n = pers.get();
      if (!card && (rng.max < rng.min || n < rng.min || n > rng.max)) { showFieldErr(pers.input, persErr, T('nb.errPersons', { min: rng.min, max: rng.max })); bad.push(pers.input); count++; } else clearFieldErr(pers.input, persErr);
      let custBad = 0; if (!st.customer) { const el = cf.validate({ focus: false }); if (el) { custBad = cf.problems().length; bad.push(el); count += custBad; } }
      const pp = parsePrice(priceIn.value);
      if (!card && !pp.ok) { showFieldErr(priceIn, priceErr, T('nb.errPrice')); priceBox.open = true; bad.push(priceIn); count++; }
      if (bad.length) {
        errBox.textContent = T('nb.errSummary', { n: count }); errBox.hidden = false;
        revealIfHidden(bad[0]); bad[0].focus({ preventScroll: true }); return;
      }
      saveBtn.disabled = true; saveBtn.textContent = T('nb.saving');
      try {
        const cust = st.customer ? { p_customer_id: st.customer.id } : { p_customer: cf.data() };
        const addonsSel = picker.node.hidden ? [] : picker.value();
        const r = card ? await rpc('admin_create_annual_card_booking', { p_customer_id: st.customer.id, p_rule_id: s.rule_id, p_date: st.date, p_note: f.elements.note.value || null })
          : await rpc('admin_create_booking', { p_rule_id: s.rule_id, p_date: st.date, p_persons: n, ...cust, p_payment_method: method.value, p_paid: paid.checked, p_note: f.elements.note.value || null, p_price: pp.value, p_addons: addonsSel.length ? addonsSel : null, p_invoice_reference: invoiceRefFor(kindNow(), invRef.value) });
        if (hasWarning(r)) toast(T('nb.warnMissing'), 'warn'); else toast(T('nb.toast', { no: r.order_no }));
        showCreated(r);
        formBox.replaceChildren(); st.session = null; loadSessions();
      } catch (e) {
        errBox.textContent = T('nb.errServer', { msg: errMsg(e) }); errBox.hidden = false; revealIfHidden(errBox);
        saveBtn.disabled = false; saveBtn.textContent = T('nb.save');
      }
    } },
      h('h3', { class: 'nb-picked' }, h('span', { text: T('nb.picked', { name: slotName(s), time: `${fmtTime(s.starts_at)}–${fmtTime(s.ends_at)}` }) }), h('small', { text: fmtDay(s.starts_at) })),
      persSec, custSec, picker.node, paySec, noteSec, bar);
    formBox.replaceChildren(f);
    syncCard(); syncInv();
    if (reveal) revealForm(f);
  }

  function showCreated(r) {
    const canPay = ctx.can('payments.manage');
    const title = h('h3', { tabindex: '-1', text: T('nb.created', { no: r.order_no }) });
    const openBooking = h('button', { type: 'button', class: `btn ${canPay ? 'ghost' : 'primary'}`, text: T('nb.openBooking'), onclick: async () => {
      openBooking.disabled = true;
      try {
        const rows = await rpc('admin_list_reservations', { p_search: String(r.order_no), p_limit: 10, p_offset: 0 });
        const row = rows.find((x) => x.reservation_id === r.reservation_id) || rows.find((x) => x.order_no === r.order_no) || rows[0];
        if (row) reservationDialog(row, { methods: refs.methods, onChange: () => {}, refs, can: ctx.can });
      } catch (e) { toast(errMsg(e), 'err'); } finally { openBooking.disabled = false; }
    } });
    result.replaceChildren(...[warningBox(r, { ctx, onDone: () => { result.replaceChildren(); } }), h('div', { class: 'card ok-box nb-done', 'data-testid': 'booking-created' },
      h('div', { class: 'nb-done-head' }, h('span', { class: 'nb-done-ico' }, icon('check', 28)), title),
      h('p', { text: T('nb.createdLine', { product: r.product_name, day: fmtDay(r.starts_at), time: `${fmtTime(r.starts_at)}–${fmtTime(r.ends_at)}`, total: money(r.total) }) }),
      h('div', { class: 'nb-done-actions' },
        canPay ? h('a', { class: 'btn primary', 'data-testid': 'open-order', href: `#/talous?tab=orders&order=${encodeURIComponent(r.order_no)}`, text: T('nb.openOrder') }) : null,
        openBooking,
        h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'another-booking', text: T('nb.another'), onclick: () => { result.replaceChildren(); dateIn.focus(); root.scrollIntoView({ block: 'start' }); } }),
        h('a', { class: 'btn ghost', href: `#/?d=${st.date}`, text: T('nb.dayView') })))].filter(Boolean));
    revealSection(result, title);
  }

  const langs = h('div', { class: 'nb-langs', role: 'group', 'aria-label': T('nb.lang') }, LANGS.map((l) => h('button', { type: 'button', class: 'nb-lang', 'aria-pressed': String(getLang() === l), lang: l, 'data-testid': `nb-lang-${l}`, onclick: () => { if (getLang() === l) return; setLang(l); reload?.(); } }, l.toUpperCase())));
  root.append(result, h('section', { class: 'card nb-sec nb-slots' }, h('h3', { class: 'nb-h', text: T('nb.s1') }), h('div', { class: 'fld' }, h('label', { class: 'fld-lab', for: 'nb-date', text: T('nb.day') }), dayCtl), sessionsBox), formBox);
  await loadSessions(); drawForm(!!st.session);
  return [h('div', { class: 'row between wrap nb-top' }, h('h1', { text: T('nb.title') }), langs), typeSwitch('', st.date), root];
}
