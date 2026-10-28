// Manuaalinen varaus (puhelin, paikan päällä, sähköposti): 1 Vuoro ja päivä → 2 Henkilömäärä → 3 Asiakas → 4 Lisäpalvelut → 5 Maksu ja hinta → 6 Muistiinpano.
// Vuosikorttiasiakkaalle yleiseen vuoroon: "Vuosikorttivaraus" (ilmainen, 1 hlö, yksi tuleva varaus kerrallaan).
// Teksti FI/EN (../nb-texts.js, kieli kuten Talous-näkymillä). Palvelinkutsut (admin_create_booking jne.) ja niiden parametrit ovat ennallaan; vain käyttöliittymä on uusittu.
import { rpc, select } from '../sb.js';
import { customerForm, customerSearch } from './customerform.js';
import { warningBox, hasWarning } from './therapist.js';
import { addonPicker } from './addons.js';
import { reservationDialog } from './shared.js';
import { h, toast, errMsg, fmtTime, fmtDay, money, todayHel, addDays, empty, revealSection, revealIfHidden, helsinkiIso } from '../ui.js';
import { icon } from '../icons.js';
import { stepper } from '../stepper.js';
import { nbt as T, nbLang } from '../nb-texts.js';
import { setLang, LANGS, getLang } from '../talous-i18n.js';
import { priceFor, personsRange, staffPersonsMax, effectiveKind, invoiceRefFor, paidDefault, parsePrice, summary, bookingNotices, applyDiscount } from '../nb-logic.js';
import { loadBookingTexts, bookingText, noticeText } from '../booking-texts.js';
import { confirmDialog } from '../confirm.js';
import { typeSwitch, render as renderResource } from './resbooking.js';
import { invoiceHref, openInvoiceAfterBooking } from '../invoice-link.js';

export async function render({ ctx, refs, query, reload }) {
  const kind = query.get('tyyppi');   // migraatio 17: resurssivaraus / vanha varaus omalla lomakkeellaan
  if (kind === 'resurssi' || kind === 'vanha') return renderResource({ ctx, refs, query, kind });
  const [addons, rules] = await Promise.all([
    rpc('admin_list_addons').catch(() => []),
    select('schedule_rules', { select: 'id,product_id,label,mode,start_time,duration_minutes,min_persons,max_persons,weekdays,space_id', active: 'eq.true', order: 'sort_order.asc,id.asc' }).catch(() => []),
    loadBookingTexts(rpc).catch(() => false),
  ]);
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
    st.blocks = v.blocks || [];
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
      const bookable = ok || s.status === 'full' || s.status === 'unavailable';
      const b = h('button', { type: 'button', role: 'radio', 'aria-checked': st.session?.rule_id === s.rule_id && st.session?.starts_at === s.starts_at ? 'true' : 'false', class: `slotbtn ${s.status}`, disabled: !bookable || null, onclick: () => { st.session = s; st.discount = null; sessionsBox.querySelectorAll('.slotbtn').forEach((x) => x.setAttribute('aria-checked', 'false')); b.setAttribute('aria-checked', 'true'); drawForm(true); } },
        h('strong', { text: `${fmtTime(s.starts_at)}–${fmtTime(s.ends_at)}` }), h('span', { text: slotName(s) }), h('small', { text: ok ? (s.mode === 'exclusive' ? T('nb.privFree') + holdPrivTxt(s) : T('nb.free', { n: s.remaining }) + holdTxt(s)) : s.status === 'full' ? `${T('nb.full')} · ${bookingText('slot_full')}` : s.status === 'unavailable' ? bookingText('slot_closed') : T('nb.na') }));
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
    const capMax = staffPersonsMax(s);
    const pers = stepper({ label: T('nb.persons'), value: rng.min, min: rng.min, max: capMax, inputName: 'n', size: 'lg', onChange: () => upd() });
    const persHint = h('small', { class: 'fld-hint', text: s.mode === 'exclusive' ? T('nb.personsHintMin', { min: rng.min, max: rng.max }) + (s.wlHold ? ` ${T('nb.holdHintPriv', { time: fmtTime(s.wlHold.until) })}` : '') : T('nb.personsHint', { free: s.remaining, min: rng.min }) + (s.wlHold ? ` ${T('nb.holdHint', { n: s.wlHold.n, time: fmtTime(s.wlHold.until) })}` : '') });
    const persErr = fieldErr();
    const priceIn = h('input', { type: 'text', inputmode: 'decimal', name: 'price', autocomplete: 'off', placeholder: T('nb.priceAuto') });
    const priceErr = fieldErr(); priceIn.addEventListener('input', () => { clearFieldErr(priceIn, priceErr); upd(); });
    const priceHint = h('small', { class: 'fld-hint' });
    const priceBox = h('details', { class: 'nb-price' }, h('summary', { text: T('nb.priceOpen') }), h('label', { class: 'fld' }, h('span', { class: 'fld-lab', text: T('nb.price') }), priceIn, priceHint, priceErr));
    const sumLines = h('span', { class: 'nb-sum-lines' }), sumTotal = h('strong', { class: 'nb-sum-total' });
    const errBox = h('p', { class: 'nb-err', role: 'alert', hidden: true, 'data-testid': 'form-error' });
    const warnBox = h('div', { class: 'nb-warn', role: 'status', hidden: true, 'data-testid': 'booking-warning' });
    let serverNotices = []; let previewTimer = 0; let previewSeq = 0;
    const cardChk = h('input', { type: 'checkbox', name: 'cardbooking' });
    const cardRow = h('label', { class: 'check big cardrow', hidden: true }, cardChk, h('span', {}, h('strong', { text: T('nb.card') }), h('small', { text: T('nb.cardHint') })));
    let picker = null, paySec = null, persSec = null;
    const dueNow = () => {
      const card = cardChk.checked;
      const ad = card ? 0 : (picker ? picker.total() : 0);
      const sm = summary({ session: s, persons: pers.get(), override: parsePrice(priceIn.value), addons: ad, annualCard: card });
      const disc = card ? 0 : (st.discount?.discount || 0);
      return { sm, total: card ? 0 : Math.max(0, applyDiscount(sm.total, disc)), disc };
    };
    const paintWarnings = () => {
      const notices = dedupeNotices([...bookingNotices(s, pers.get()), ...serverNotices]);
      warnBox.hidden = !notices.length;
      warnBox.replaceChildren(...notices.map((n) => h('p', { text: noticeText(n) })));
      return notices;
    };
    const upd = () => {
      const card = cardChk.checked;
      const { sm, total, disc } = dueNow();
      const ad = card ? 0 : picker.total();
      priceHint.textContent = T('nb.priceHint', { auto: money(priceFor(s, nPersons())) });
      const bits = [];
      if (card) bits.push(T('nb.sumCard'));
      else {
        if (ad) bits.push(`${T('nb.sumSlot')} ${money(sm.slot)} + ${T('nb.sumAddons').toLowerCase()} ${money(ad)}`);
        else if (sm.overridden) bits.push(`${T('nb.sumSlot')} (${T('nb.ownPrice')}) ${money(sm.slot)}`);
        if (disc) bits.push(`${bookingText('discount_line', { code: st.discount.code })} −${money(disc)}`);
      }
      sumLines.textContent = bits.join(' · ');
      sumTotal.textContent = money(total);
      paintGiftRest(total);
      paintWarnings();
      clearTimeout(previewTimer);
      previewTimer = setTimeout(refreshPreview, 250);
      if (!fromDiscount && st.discount?.code) {
        clearTimeout(discountTimer);
        discountTimer = setTimeout(() => { if (st.discount?.code) useDiscount(st.discount.code); }, 400);
      }
    };
    let fromDiscount = false; let discountTimer = 0;
    const nPersons = () => pers.get();
    picker = addonPicker(addons, { getPersons: () => pers.get(), getMode: () => s.mode, onChange: () => upd() });
    const invRef = h('input', { name: 'invref', maxlength: 100, autocomplete: 'off' });
    const invFld = h('label', { class: 'fld', hidden: true, 'data-testid': 'invref-field' }, h('span', { class: 'fld-lab' }, T('nb.invref'), h('span', { class: 'opt', text: ` (${T('nb.optional')})` })), invRef, h('small', { class: 'fld-hint', text: T('nb.invrefHint') }));
    const ui = {}; let paidTouched = false;
    const paid = h('input', { type: 'checkbox', name: 'paid' });
    paid.addEventListener('change', () => { paidTouched = true; });
    const method = h('select', { name: 'method' }, refs.methods.filter((m) => m.active).map((m) => h('option', { value: m.code, text: m.label, selected: m.code === 'pay_later' || null })));
    method.addEventListener('change', () => { if (!paidTouched) paid.checked = paidDefault(method.value); syncGift(); upd(); });
    ui.method = method;
    const codeIn = h('input', { name: 'discount', maxlength: 40, autocomplete: 'off', autocapitalize: 'characters', spellcheck: 'false', placeholder: bookingText('discount_ph'), 'data-testid': 'discount-code' });
    const codeStatus = h('p', { class: 'fld-hint', hidden: true, 'data-testid': 'discount-status' });
    const codeRemove = h('button', { type: 'button', class: 'btn ghost sm', hidden: true, 'data-testid': 'discount-remove', text: bookingText('discount_remove'), onclick: () => { st.discount = null; codeIn.value = ''; codeRemove.hidden = true; codeStatus.hidden = true; upd(); } });
    const codeApply = h('button', { type: 'button', class: 'btn sm', 'data-testid': 'discount-apply', text: bookingText('discount_apply'), onclick: () => useDiscount(codeIn.value) });
    const giftIn = h('input', { name: 'gift', maxlength: 24, autocomplete: 'off', autocapitalize: 'characters', spellcheck: 'false', placeholder: bookingText('gift_ph'), 'data-testid': 'gift-code' });
    const giftStatus = h('p', { class: 'fld-hint', hidden: true, 'data-testid': 'gift-status' });
    const giftCheck = h('button', { type: 'button', class: 'btn sm', 'data-testid': 'gift-check', text: bookingText('gift_check'), onclick: () => checkGift() });
    const restSel = h('select', { name: 'remainder', 'data-testid': 'gift-remainder' }, h('option', { value: '', text: bookingText('gift_rest_unpaid') }), ...refs.methods.filter((m) => m.active && m.code !== 'gift_card').map((m) => h('option', { value: m.code, text: m.label })));
    const restWrap = h('div', { hidden: true, 'data-testid': 'gift-rest' }, h('p', { class: 'nb-rest', 'data-testid': 'gift-rest-line' }), h('label', { class: 'fld' }, h('span', { class: 'fld-lab', text: bookingText('gift_rest_method') }), restSel));
    const giftWrap = h('div', { class: 'stack', hidden: true, 'data-testid': 'gift-card-field' },
      h('div', { class: 'nbsearch' }, h('label', { class: 'fld', style: 'flex:1' }, h('span', { class: 'fld-lab', text: bookingText('gift_code') }), giftIn), giftCheck),
      giftStatus, restWrap);
    function syncGift() { giftWrap.hidden = method.value !== 'gift_card'; if (giftWrap.hidden) { st.gift = null; giftStatus.hidden = true; } }
    function dedupeNotices(list) { const seen = new Set(); return list.filter((n) => { const k = `${n.kind}:${n.code}`; if (seen.has(k)) return false; seen.add(k); return true; }); }
    function paintGiftRest(total) {
      if (method.value !== 'gift_card' || !st.gift?.redeemable) { restWrap.hidden = true; return; }
      const covered = Math.min(Number(st.gift.balance) || 0, total);
      const rest = Math.round((total - covered) * 100) / 100;
      const line = restWrap.querySelector('[data-testid=gift-rest-line]');
      if (rest <= 0) { line.textContent = bookingText('gift_covers'); restSel.parentElement.hidden = true; }
      else { line.textContent = bookingText('gift_rest', { covered: money(covered), rest: money(rest) }); restSel.parentElement.hidden = false; }
      restWrap.hidden = false;
    }
    async function useDiscount(raw) {
      const code = String(raw || '').replace(/\s/g, '').toUpperCase();
      codeStatus.hidden = false;
      if (!code) { st.discount = null; codeStatus.textContent = ''; codeStatus.hidden = true; codeRemove.hidden = true; upd(); return; }
      codeStatus.textContent = bookingText('discount_checking');
      try {
        const addonsSel = picker.node.hidden ? [] : picker.value();
        const pp = parsePrice(priceIn.value);
        const r = await rpc('admin_preview_discount_code', { p_code: code, p_rule_id: s.rule_id, p_date: st.date, p_persons: pers.get(), p_addons: addonsSel.length ? addonsSel : null, p_price: pp.value });
        if (!r?.ok) { st.discount = null; codeRemove.hidden = true; codeStatus.textContent = r?.message || bookingText('discount'); }
        else { st.discount = { code: r.code || code, discount: Number(r.discount) || 0, type: r.type }; codeRemove.hidden = false; codeStatus.textContent = bookingText('discount_ok', { code: st.discount.code, amount: money(st.discount.discount) }); }
      } catch (e) { st.discount = null; codeRemove.hidden = true; codeStatus.textContent = errMsg(e); }
      fromDiscount = true; upd(); fromDiscount = false;
    }
    async function checkGift() {
      giftStatus.hidden = false;
      try {
        const r = await rpc('admin_check_gift_card', { p_code: giftIn.value });
        if (!r?.ok || !r.redeemable) { st.gift = null; giftStatus.textContent = r?.message || bookingText('gift_need_code'); }
        else {
          st.gift = r;
          giftStatus.textContent = r.valid_to ? bookingText('gift_ok', { balance: money(r.balance), until: r.valid_to }) : bookingText('gift_ok_open', { balance: money(r.balance) });
        }
      } catch (e) { st.gift = null; giftStatus.textContent = errMsg(e); }
      upd();
    }
    async function refreshPreview() {
      const seq = ++previewSeq;
      try {
        const r = await rpc('admin_preview_booking_limits', { p_kind: 'shift', p_rule_id: s.rule_id, p_date: st.date, p_persons: pers.get(), p_start: s.off_schedule ? s.starts_at : null, p_end: s.off_schedule ? s.ends_at : null });
        if (seq !== previewSeq) return;
        serverNotices = (r?.overbook || []).map((x) => x.code === 'capacity_exceeded' && x.capacity != null ? { kind: 'overbook', code: 'capacity_exceeded', used: x.used, capacity: x.capacity } : x.code === 'persons_max' ? { kind: 'overbook', code: 'persons_max', persons: x.persons, max: x.max } : { kind: 'overbook', code: x.code })
          .concat((r?.off_schedule || []).map((x) => ({ kind: 'off', code: x.code })));
      } catch { if (seq === previewSeq) serverNotices = []; }
      if (seq === previewSeq) paintWarnings();
    }
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
      giftWrap,
      h('div', { class: 'nbsearch' }, h('label', { class: 'fld', style: 'flex:1' }, h('span', { class: 'fld-lab', text: bookingText('discount') }), codeIn), codeApply),
      codeStatus, codeRemove,
      invFld,
      h('label', { class: 'check big' }, paid, h('span', {}, h('strong', { text: T('nb.paid') }), h('small', { text: T('nb.paidHint') }))),
      priceBox);
    const noteSec = section(T('nb.s6'), h('label', { class: 'fld' }, h('span', { class: 'fld-lab', text: T('nb.note') }), h('textarea', { name: 'note', rows: 3 }), h('small', { class: 'fld-hint', text: T('nb.noteHint') })));
    const saveBtn = h('button', { class: 'btn primary lg', type: 'submit', 'data-testid': 'save-booking', text: T('nb.save') });
    const bar = h('div', { class: 'nb-bar' }, warnBox, errBox, h('div', { class: 'nb-bar-row' }, h('div', { class: 'nb-sum', 'data-testid': 'price-summary', 'aria-live': 'polite' }, sumLines, h('span', { class: 'nb-sum-tot' }, T('nb.sumTotal'), ' ', sumTotal)), saveBtn));

    const f = h('form', { class: 'stack nbform', 'data-testid': 'booking-form', novalidate: true, onsubmit: async (ev) => {
      ev.preventDefault(); errBox.hidden = true;
      const card = cardChk.checked; const bad = []; let count = 0;
      const n = pers.get();
      if (!card && (n < rng.min || n > capMax)) { showFieldErr(pers.input, persErr, T('nb.errPersons', { min: rng.min, max: capMax })); bad.push(pers.input); count++; } else clearFieldErr(pers.input, persErr);
      if (!card && method.value === 'gift_card' && !giftIn.value.trim()) { giftStatus.hidden = false; giftStatus.textContent = bookingText('gift_need_code'); bad.push(giftIn); count++; }
      let custBad = 0; if (!st.customer) { const el = cf.validate({ focus: false }); if (el) { custBad = cf.problems().length; bad.push(el); count += custBad; } }
      const pp = parsePrice(priceIn.value);
      if (!card && !pp.ok) { showFieldErr(priceIn, priceErr, T('nb.errPrice')); priceBox.open = true; bad.push(priceIn); count++; }
      if (bad.length) {
        errBox.textContent = T('nb.errSummary', { n: count }); errBox.hidden = false;
        revealIfHidden(bad[0]); bad[0].focus({ preventScroll: true }); return;
      }
      await refreshPreview();
      const notices = paintWarnings();
      if (notices.length) {
        const over = notices.some((x) => x.kind === 'overbook');
        const off = notices.some((x) => x.kind === 'off');
        const yes = await confirmDialog({
          title: over && off ? bookingText('both_title') : over ? bookingText('over_title') : bookingText('off_title'),
          body: [...notices.map(noticeText), over ? bookingText('over_ask') : null, off ? bookingText('off_ask') : null],
          yes: bookingText('confirm_yes'), no: bookingText('confirm_no'),
        });
        if (!yes) return;
      }
      saveBtn.disabled = true; saveBtn.textContent = T('nb.saving');
      try {
        const cust = st.customer ? { p_customer_id: st.customer.id } : { p_customer: cf.data() };
        const addonsSel = picker.node.hidden ? [] : picker.value();
        const gift = method.value === 'gift_card';
        const r = card ? await rpc('admin_create_annual_card_booking', { p_customer_id: st.customer.id, p_rule_id: s.rule_id, p_date: st.date, p_note: f.elements.note.value || null })
          : await rpc('admin_create_booking', {
            p_rule_id: s.rule_id, p_date: st.date, p_persons: n, ...cust,
            p_payment_method: gift ? 'gift_card' : method.value,
            p_paid: gift ? !!restSel.value && paid.checked : paid.checked,
            p_note: f.elements.note.value || null, p_price: pp.value,
            p_addons: addonsSel.length ? addonsSel : null,
            p_invoice_reference: invoiceRefFor(kindNow(), invRef.value),
            p_discount_code: st.discount?.code || null,
            p_gift_card_code: gift ? giftIn.value.trim() : null,
            p_remainder_method: gift ? (restSel.value || null) : null,
            p_allow_overbook: notices.some((x) => x.kind === 'overbook'),
            p_allow_off_schedule: notices.some((x) => x.kind === 'off') || !!s.off_schedule,
            p_start: s.off_schedule ? s.starts_at : null,
            p_end: s.off_schedule ? s.ends_at : null,
          });
        if (hasWarning(r)) toast(T('nb.warnMissing'), 'warn'); else toast(T('nb.toast', { no: r.order_no }));
        // booking_175: yrityksen laskumaksu → luonnoslasku auki Laskut-näkymään (ei lähetystä; "Lähetä verkkolasku" / "Lähetä PDF sähköpostilla" napista)
        if (openInvoiceAfterBooking({ card, method: method.value, kind: kindNow(), canInvoices: ctx.can('invoices.manage'), orderId: r.order_id })) {
          try {
            const inv = await rpc('admin_create_invoice_from_order', { p_order_id: r.order_id });
            if (inv?.id) { location.hash = invoiceHref(inv.id); return; }
          } catch (e) { toast(errMsg(e), 'err'); }
        }
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
    syncGift(); syncCard(); syncInv();
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
  const helDow = (ds) => ({ Sun: 7, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 }[new Intl.DateTimeFormat('en-US', { weekday: 'short', timeZone: 'Europe/Helsinki' }).format(new Date(`${ds}T12:00:00Z`))] || 0);
  const offRule = h('select', { 'data-testid': 'off-rule', 'aria-label': bookingText('off_rule') }, (rules || []).map((r) => h('option', { value: r.id, text: r.label })));
  const offTime = h('input', { type: 'time', step: '300', value: '16:00', 'data-testid': 'off-time', 'aria-label': bookingText('off_time') });
  const offPanel = h('details', { class: 'nb-off', 'data-testid': 'off-schedule' },
    h('summary', { text: bookingText('off_open') }),
    h('p', { class: 'muted', text: bookingText('off_hint') }),
    h('label', { class: 'fld' }, h('span', { class: 'fld-lab', text: bookingText('off_rule') }), offRule),
    h('label', { class: 'fld' }, h('span', { class: 'fld-lab', text: bookingText('off_time') }), offTime),
    h('button', { type: 'button', class: 'btn', 'data-testid': 'off-apply', text: bookingText('confirm_yes'), onclick: () => {
      const rule = (rules || []).find((r) => String(r.id) === offRule.value); if (!rule || !offTime.value) return;
      const time = offTime.value;
      const start = helsinkiIso(`${st.date}T${time}`);
      const mins = Number(rule.duration_minutes) || 90;
      const [hh, mm] = time.split(':').map(Number);
      const endAbs = hh * 60 + mm + mins;
      const endTime = `${String(Math.floor(endAbs / 60) % 24).padStart(2, '0')}:${String(endAbs % 60).padStart(2, '0')}`;
      const end = helsinkiIso(`${st.date}T${endTime}`);
      const scheduled = (rule.weekdays || []).map(Number).includes(helDow(st.date)) && String(rule.start_time || '').slice(0, 5) === time;
      const blocked = (st.blocks || []).some((b) => String(b.space_id) === String(rule.space_id) && b.starts_at < end && b.ends_at > start);
      const product = refs.productById.get(rule.product_id);
      st.discount = null;
      st.session = {
        rule_id: rule.id, product_id: rule.product_id, label: rule.label, mode: rule.mode || 'shared',
        status: 'off_schedule', off_schedule: true, off_code: blocked ? 'closure' : scheduled ? 'outside_hours' : 'no_session', blocked,
        remaining: 0, min_persons: rule.min_persons || 1, max_persons: rule.max_persons,
        price_mode: 'fixed', base_price: Number(product?.price) || 0, unit_price: Number(product?.price) || 0,
        included_persons: Number(product?.included_persons) || 0, extra_person_price: Number(product?.extra_person_price) || 0,
        starts_at: start, ends_at: end,
      };
      drawForm(true);
    } }));
  root.append(result, h('section', { class: 'card nb-sec nb-slots' }, h('h3', { class: 'nb-h', text: T('nb.s1') }), h('div', { class: 'fld' }, h('label', { class: 'fld-lab', for: 'nb-date', text: T('nb.day') }), dayCtl), sessionsBox, (rules || []).length ? offPanel : null), formBox);
  await loadSessions(); drawForm(!!st.session);
  return [h('div', { class: 'row between wrap nb-top' }, h('h1', { text: T('nb.title') }), langs), typeSwitch('', st.date), root];
}
