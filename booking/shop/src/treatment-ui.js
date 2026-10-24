// Hoito- ja rituaalivaraukset: käyttöliittymä. Kulku: tuotekortti → henkilömäärä → päivä (vain vapaat päivät) → kellonaika (vapaat alkuajat) → asiakaslomake
// → tarkistus ja vahvistus → vahvistussivu (sama sivu ja muutoslinkki kuin vuorovarauksissa). Kaikki palvelinkutsut kulkevat adapterin (treatments.js) kautta.
// Käyttää shop.js:n apureita ja komponentteja (h, asiakaslomake, ehtokentät, tuotekuva, hero, yhteenveto-/valintapalkki, kalenteri- ja aikalistatyylit) ctx:n kautta.
import * as A from './treatments.js';
import * as O from './options-logic.js';
import { OPT } from './options-texts.js';
import { createOptionPicker } from './options-ui.js';
import { ht, holdError } from './hold-texts.js';
import { fmtMinutes } from './site-texts-logic.js';
import { createAddonPicker } from './treatment-addons.js';
import { isRichHtml } from './rich-text.js';
import { visibleText, richHost } from './rich-view.js';
import { revealForm, revealIfHidden } from './gift-ui.js';

export function createTreatmentViews(c) {
  const { h, t, S, state, money, fmt, hm, dayLong, pad2, todayHel, addDays, pname, pdesc, pimg, setHero, mount, focusTop, errorBox, phoneBox, bk, customerFields, legalFields, holdInfo = async () => ({ on: false, minutes: 15, extra: () => [] }), tx = () => null, confirmUrl = (tok) => `${S.confirmHref}#${tok}` } = c;
  const tr = t.tr;
  const horizonDays = () => A.horizonDays(state.settings);
  const tm = (iso) => fmt(iso, { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).replace('.', ':');
  const dayShort = (iso) => fmt(iso, S.lang === 'fi' ? { weekday: 'short', day: 'numeric', month: 'numeric', year: 'numeric' } : { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' });
  const when = (iso) => `${dayShort(iso)}${S.lang === 'fi' ? ', klo ' : ' · '}${tm(iso)}`;
  const q = (hash) => new URLSearchParams(hash.split('?')[1] || '');
  const ot = OPT[S.lang] || OPT.fi;   // tuotevalinnan tekstit (booking_50)
  // virheviesti: valinnan virheet (options-texts) → lisäpalveluvirheet (site_texts ui.checkout.error_<koodi>, §18.2; puuttuu → ui.shop.error_generic; palvelimen raaka message ei asiakkaalle) → pitotilan virheet → kaupan vanhat viestit
  const errMsg = (r) => (O.isOptionError(r.code) ? ot[`err.${r.code}`] : A.isAddonError(r.code) ? tx(A.errorTextKey(r.code)) || t.errorGeneric : holdError(S.lang, r.code) || tr.errors[A.errorKey(r.code)] || tr.errors.generic);
  const optPicker = (p, o) => createOptionPicker({ h, lang: S.lang, product: p, options: p.options, ...o });
  const optQ = (code) => (code ? `&o=${encodeURIComponent(code)}` : '');

  // hintarivi: perushinta + lisähenkilö
  const priceText = (p) => {
    const base = p.price_type === 'per_person' ? `${money(p.price)} ${t.perPerson}` : money(p.price);
    return p.price_type === 'base_plus_extra_person' && p.extra_person_price && A.maxPersons(p) > 1 ? `${base} (${t.included(p.included_persons || 1)}, ${t.extra(money(p.extra_person_price))})` : base;
  };
  // pakettituote (kb 7): aikajana kannasta (public_catalog().timeline / timeline_text; sisäistä taukoa ei näytetä), kesto "2 h", aikataulu kellonaikoina valitusta alkuajasta
  const fmtMin = fmtMinutes;
  const totalMin = (p) => p.duration_minutes || A.timelineMinutes(p);
  // jakson sisällä sitova väli (NBSP): rivinvaihto vain jaksojen välissä ("savusauna 1 h 30 min" ei katkea)
  const timelineText = (p) => A.timelineText(p, S.lang);
  // kesto hintarivillä: paketilla kieliversio (palvelimen duration_text on suomea ja pitkä), muilla palvelimen teksti (EN: duration_text_en, puuttuu → duration_text; booking_147)
  const durText = (p) => (A.isPackage(p) ? fmtMin(totalMin(p)) : (S.lang === 'en' && p.duration_text_en) || p.duration_text || '');
  // lahjakorttihuomautus (booking_61: voucher_note / voucher_note_en): erillinen huomautus, ei osa tuotekuvausta; en puuttuu → fi
  const voucherNote = (p) => ((S.lang === 'en' && p.voucher_note_en) || p.voucher_note || '').trim();
  const voucherNode = (p) => (voucherNote(p) ? h('aside', { class: 'bk-voucher-note', 'data-testid': 'voucher-note', role: 'note' }, h('p', { text: voucherNote(p) })) : null);
  const metaP = (p) => h('p', { class: 'bk-meta' }, h('strong', { text: priceText(p) }), durText(p) ? ` · ${durText(p)}` : '');
  // palkki: vain näkyvät jaksot, leveys = kesto (rituaali : savusauna = 20 : 90)
  const bar = (p) => h('span', { class: 'bk-tl-bar', 'aria-hidden': 'true' }, A.timelineOf(p).map((x) => h('span', { class: `bk-tl-seg ${x.key.replace(/[^a-z0-9_-]/gi, '')}`, style: `flex:${x.min} 1 0` })));
  const timelineNode = (p) => (A.isPackage(p) ? h('div', { class: 'bk-timeline', 'data-testid': 'timeline' }, h('p', { class: 'bk-tl-text', text: timelineText(p) }), bar(p)) : null);
  // aikataulurivit valitulle alkuajalle: "rituaali 16:00–16:20" … (yhteenveto ja tarkistus)
  const scheduleDd = (p, startIso) => h('dd', { class: 'bk-schedule', 'data-testid': 'schedule' }, A.timelineSlots(p, startIso).map((x) => h('span', { class: 'bk-sched-line', text: `${A.timelineLabel(x, S.lang)} ${x.from}–${x.to}` })));
  const scheduleRows = (p, startIso) => (A.isPackage(p) && startIso ? [h('dt', { text: tr.tlTitle }), scheduleDd(p, startIso)] : null);

  // tuotekortti tuotelistaan (sama rakenne kuin vuorotuotteilla)
  const card = (p) => h('li', { class: 'bk-card' },
    pimg(p, 'card-img'),
    h('h3', {}, h('a', { href: bk(`/tuote/${p.slug}`), text: pname(p) })),
    h('p', { class: 'bk-desc', text: (() => { const raw = pdesc(p) || ''; const plain = isRichHtml(raw) ? visibleText(raw).replace(/\s+/g, ' ').trim() : raw; return plain.slice(0, 170) + (plain.length > 170 ? '…' : ''); })() }),
    metaP(p),
    timelineNode(p),
    h('a', { class: 'btn sm', href: bk(`/tuote/${p.slug}`) }, t.choose, h('span', { class: 'sr', text: ' – ' + pname(p) })));

  // ---- valitsin: henkilömäärä → päivä (vain vapaat) → kellonaika ----
  // opts: { n, date, time, minStartMs, onChange(sel) }; sel = { n, date, time, slot|null }
  function slotPicker(p, opts) {
    const minN = A.minPersons(p), maxN = A.maxPersons(p), today = todayHel(), maxDs = addDays(today, horizonDays()), off = opts.stepOffset || 0;   // off: hoitovalitsin on vaihe 1 → muut vaiheet siirtyvät
    const st = { n: Math.min(Math.max(opts.n || minN, minN), maxN), date: opts.date || null, time: opts.time || null, y: 0, m: 0, seq: 0, slots: new Map(), loaded: new Map() };
    const [y0, m0] = (st.date || today).split('-').map(Number); st.y = y0; st.m = m0 - 1;
    const key = (y, m) => `${st.n}:${y}-${m}`;
    const monthSlots = async (y, m) => {   // → Map<date, slots[]>; välimuisti henkilömäärän ja kuukauden mukaan
      const k = key(y, m); if (st.loaded.has(k)) return st.loaded.get(k);
      const first = `${y}-${pad2(m + 1)}-01`, last = `${y}-${pad2(m + 1)}-${pad2(new Date(y, m + 1, 0).getDate())}`;
      const from = first < today ? today : first, to = last > maxDs ? maxDs : last;   // vain varausikkuna (public_treatment_horizon_days)
      const by = from > to ? new Map() : await A.loadAvailability(p, st.n, from, to);
      for (const [d, list] of by) { const ok = list.filter((s) => d >= today && d <= maxDs && new Date(s.start).getTime() >= (opts.minStartMs || 0)); if (ok.length) by.set(d, ok); else by.delete(d); }
      st.loaded.set(k, by); return by;
    };
    const sel = () => ({ n: st.n, date: st.date, time: st.time, slot: (st.slots.get(st.date) || []).find((s) => s.time === st.time) || null });
    const emit = () => opts.onChange?.(sel());

    // 1) henkilömäärä
    const num = h('input', { id: 'tr-n', type: 'number', min: minN, max: maxN, inputmode: 'numeric', 'aria-label': t.persons, onchange: () => setN(+num.value || minN) });
    const minus = h('button', { type: 'button', class: 'bk-step', 'aria-label': tr.fewer, onclick: () => setN(st.n - 1) }, '−');
    const plus = h('button', { type: 'button', class: 'bk-step', 'aria-label': tr.more, onclick: () => setN(st.n + 1) }, '+');
    const syncN = () => { num.value = st.n; minus.disabled = st.n <= minN; plus.disabled = st.n >= maxN; };
    const personsBox = h('section', { class: 'bk-step-box', 'aria-labelledby': 'tr-h1' },
      h('h3', { id: 'tr-h1' }, h('span', { class: 'bk-stepn', 'aria-hidden': 'true', text: String(1 + off) }), tr.step1),
      h('div', { class: 'bk-stepper' }, minus, num, plus),
      maxN > 1 ? h('p', { class: 'bk-hint', text: tr.maxPersons(maxN) }) : h('p', { class: 'bk-hint', text: tr.onePerson }));
    // 2) päivä
    const calBox = h('div', { class: 'bk-cal bk-cal-tr', 'aria-live': 'polite' });
    const dateBox = h('section', { class: 'bk-step-box', 'aria-labelledby': 'tr-h2' }, h('h3', { id: 'tr-h2' }, h('span', { class: 'bk-stepn', 'aria-hidden': 'true', text: String(2 + off) }), tr.step2), calBox);
    // 3) kellonaika
    const timeBox = h('section', { class: 'bk-step-box', 'aria-labelledby': 'tr-h3' });
    const setN = (n) => { n = Math.min(Math.max(n, minN), maxN); if (n === st.n) { syncN(); return; } st.n = n; syncN(); st.time = null; st.slots = new Map(); st.seq++; calBox.replaceChildren(h('p', { class: 'bk-loading', role: 'status', text: t.loading })); clearTimeout(st.tm); st.tm = setTimeout(refresh, 350); };   // viive: nopea +/+ ei tee rinnakkaisia hakuja
    const choose = (ds) => { st.date = ds; st.time = null; drawCal(false); drawTimes(); emit(); revealForm(timeBox, timeBox.querySelector('#tr-h3')); };
    async function drawCal(load = true) {
      const seq = ++st.seq;
      if (load) calBox.replaceChildren(h('p', { class: 'bk-loading', role: 'status', text: t.loading }));
      let by;
      try { by = await monthSlots(st.y, st.m); } catch (e) {
        if (seq === st.seq) calBox.replaceChildren(errorBox(A.isRetryable(e?.code) ? tr.errors[A.errorKey(e.code)] : t.loadError), h('p', {}, h('button', { type: 'button', class: 'btn sm light', text: tr.retry, onclick: () => drawCal() })));
        return;
      }
      if (seq !== st.seq) return;
      for (const d of [...st.slots.keys()]) if (d.startsWith(`${st.y}-${pad2(st.m + 1)}-`)) st.slots.delete(d);
      for (const [d, l] of by) st.slots.set(d, l);
      const first = new Date(st.y, st.m, 1), days = new Date(st.y, st.m + 1, 0).getDate(), lead = (first.getDay() + 6) % 7;
      const monthName = fmt(new Date(Date.UTC(st.y, st.m, 1, 12)).toISOString(), { month: 'long', year: 'numeric', timeZone: 'UTC' });
      const prevOk = `${st.y}-${pad2(st.m + 1)}-01` > today, nextOk = new Date(st.y, st.m + 1, 1).toLocaleDateString('sv-SE') <= maxDs;
      const go = (d, manual) => { if (manual) st.hop = 99; st.m += d; if (st.m < 0) { st.m = 11; st.y--; } if (st.m > 11) { st.m = 0; st.y++; } return drawCal(); };
      const nav = h('div', { class: 'bk-calnav' },
        h('button', { type: 'button', 'aria-label': t.prevMonth, disabled: !prevOk, onclick: () => go(-1, true) }, '‹'),
        h('strong', { 'aria-live': 'polite', text: monthName }),
        h('button', { type: 'button', 'aria-label': t.nextMonth, disabled: !nextOk, onclick: () => go(1, true) }, '›'));
      const wd = Array.from({ length: 7 }, (_, i) => h('span', { class: 'bk-wd', 'aria-hidden': 'true', text: fmt(new Date(Date.UTC(2024, 0, 1 + i)).toISOString(), { weekday: 'short', timeZone: 'UTC' }) }));
      const cells = Array.from({ length: lead }, () => h('span', { class: 'bk-cell empty' }));
      let any = false;
      for (let d = 1; d <= days; d++) {
        const ds = `${st.y}-${pad2(st.m + 1)}-${pad2(d)}`, list = by.get(ds);
        if (!list) { cells.push(h('span', { class: 'bk-cell off', 'aria-hidden': 'true', text: d })); continue; }   // vain vapaat päivät ovat valittavissa
        any = true;
        cells.push(h('button', { type: 'button', class: `bk-cell free${ds === today ? ' today' : ''}${ds === st.date ? ' sel' : ''}`, 'aria-pressed': ds === st.date ? 'true' : 'false', 'data-date': ds,
          'aria-label': `${dayLong(`${ds}T12:00:00Z`)}, ${t.timesFree(list.length)}`, onclick: () => choose(ds) }, d));
      }
      calBox.replaceChildren(nav, h('div', { class: 'bk-grid', role: 'group', 'aria-label': monthName }, wd, cells),
        any ? h('p', { class: 'bk-legend' }, h('span', { class: 'dot free' }), tr.legendFree)
          : A.isPackage(p) ? h('p', { class: 'bk-note bk-nofree', role: 'status', 'data-testid': 'no-times' }, h('strong', { text: tr.noTimes }), ` – ${tr.noTimesHint}`) : h('p', { class: 'bk-note bk-nofree', role: 'status', text: tr.noFreeMonth }));
      // ensimmäinen avaus ilman valittua päivää: hypätään seuraavaan kuukauteen, jossa on vapaata (enintään 4 kk)
      if (!any && !st.date && st.hop < 4 && nextOk) { st.hop++; return go(1); }
      if (st.date && !st.slots.get(st.date)?.length) { st.date = null; st.time = null; drawTimes(); emit(); }
    }
    st.hop = 0;
    function drawTimes() {
      const list = st.date ? st.slots.get(st.date) || [] : [];
      if (st.ready && st.time && !list.some((s) => s.time === st.time)) st.time = null;
      timeBox.replaceChildren(h('h3', { id: 'tr-h3' }, h('span', { class: 'bk-stepn', 'aria-hidden': 'true', text: String(3 + off) }), tr.step3),
        !st.date ? h('p', { class: 'bk-note', text: tr.pickDayFirst }) : !st.ready ? h('p', { class: 'bk-loading', role: 'status', text: t.loading })
          : h('div', { 'aria-live': 'polite' }, h('p', { class: 'bk-note', text: `${dayLong(`${st.date}T12:00:00Z`)} – ${tr.startTimes}` }),
            list.length ? h('ul', { class: 'bk-times' }, list.map((s) => h('li', {}, h('button', { type: 'button', class: 'bk-time-btn', 'aria-pressed': s.time === st.time ? 'true' : 'false',
              onclick: () => { st.time = s.time; drawTimes(); emit(); revealIfHidden(timeBox.closest('.bk-picker')?.parentElement?.querySelector('.bk-continue')); timeBox.querySelector('[aria-pressed="true"]')?.focus({ preventScroll: true }); } },
              h('strong', { text: s.time }), s.end ? h('span', { class: 'bk-time-end', text: `–${tm(s.end)}` }) : null))))
              : h('p', { class: 'bk-note', text: A.isPackage(p) ? tr.noTimes : t.noSlots })));
    }
    async function refresh() { st.hop = 0; await drawCal(); drawTimes(); emit(); }
    syncN(); drawTimes();
    const ready = (async () => {
      await drawCal(); st.ready = true;
      // URL:n päivä/aika voivat olla vanhentuneet: drawCal/drawTimes tyhjentävät puuttuvan valinnan
      drawTimes(); emit();
    })();
    return { node: h('div', { class: 'bk-picker' }, personsBox, dateBox, timeBox), get: sel, ready };
  }

  // ---- näkymä: hoitotuote (#/tuote/<slug>?n=&d=&t=) ----
  async function viewTreatment(p, query) {
    setHero(p);
    const sum = h('p', { class: 'bk-pick-sum', 'aria-live': 'polite' });
    const go = h('button', { type: 'button', class: 'btn', disabled: true, text: tr.continue });
    let cur = null;
    // pakollinen hoitovalinta (booking_50): vaihe 1; jatkaminen vasta kun valinta on tehty
    const needOpt = O.needsOption(p), showOpt = O.hasOptions(p);
    let opt = O.validCode(p, query.get('o'));
    const optP = showOpt ? optPicker(p, { value: opt, required: needOpt, step: needOpt ? '1' : null, onChange: (code) => { opt = code; upd(); } }) : null;
    const optStep = showOpt ? h('section', { class: 'bk-step-box bk-step-opt' }, optP.node) : null;
    const upd = () => {
      const s = cur || {}, slotOk = !!(s.date && s.slot), optOk = O.optionOk(p, opt);
      go.disabled = !(slotOk && optOk);
      sum.textContent = !optOk ? ot.pickToContinue : slotOk ? tr.selected(`${dayLong(s.slot.start)}, ${s.time}`, s.n, money(s.slot.total ?? A.priceFor(p, s.n))) + (opt ? ` · ${O.optName(O.findOption(p, opt), S.lang)}` : '') : '';
      if (s.n) history.replaceState(null, '', bk(`/tuote/${p.slug}?n=${s.n}${s.date ? `&d=${s.date}` : ''}${s.date && s.time ? `&t=${A.timeToken(s.time)}` : ''}${optQ(opt)}`)); c.setLast();
    };
    const picker = slotPicker(p, { n: +query.get('n') || undefined, date: /^\d{4}-\d\d-\d\d$/.test(query.get('d') || '') ? query.get('d') : null, time: A.timeFromToken(query.get('t')), stepOffset: needOpt ? 1 : 0,
      onChange: (s) => { cur = s; upd(); } });
    go.addEventListener('click', () => {
      if (!O.optionOk(p, opt)) { optP.setError(ot['err.option_required']); optP.focus(); return; }
      if (cur?.slot) location.hash = `#/hoito/${p.slug}/${cur.date}/${A.timeToken(cur.time)}?n=${cur.n}${optQ(opt)}`;
    });
    mount(h('p', {}, h('a', { href: bk('/'), text: t.backList })),
      richHost(h, pdesc(p) || '', 'bk-desc'), voucherNode(p),
      metaP(p), timelineNode(p),
      optStep, picker.node, h('div', { class: 'bk-continue' }, sum, go));
    await picker.ready;
    if (!query.get('n')) focusTop();
  }

  // ---- näkymä: lomake + tarkistus (#/hoito/<slug>/<pvm>/<HHMM>?n=) ----
  async function viewCheckout(p, ds, tok, query) {
    setHero(p);
    const time = A.timeFromToken(tok), n = Math.min(Math.max(+query.get('n') || A.minPersons(p), A.minPersons(p)), A.maxPersons(p));
    const needOpt = O.needsOption(p), showOpt = O.hasOptions(p);
    let opt = O.validCode(p, query.get('o'));   // valittu hoito (booking_50); puuttuva/virheellinen → valitaan lomakkeella
    const backUrl = () => bk(`/tuote/${p.slug}?n=${n}${/^\d{4}-\d\d-\d\d$/.test(ds) ? `&d=${ds}` : ''}${time ? `&t=${tok}` : ''}${optQ(opt)}`);
    const back = backUrl();
    let slot = null;
    if (time && /^\d{4}-\d\d-\d\d$/.test(ds)) {
      try { slot = (await A.loadAvailability(p, n, ds, ds)).get(ds)?.find((s) => s.time === time) || null; } catch { mount(errorBox(t.loadError), phoneBox()); focusTop(); return; }
    }
    if (!slot) { mount(h('p', {}, h('a', { href: bk(`/tuote/${p.slug}`), text: t.backList })), errorBox(tr.errors.taken), h('p', {}, h('a', { class: 'btn sm', href: back, text: tr.pickAnother }))); focusTop(); return; }
    const baseTotal = slot.total ?? A.priceFor(p, n);
    // lisäpalvelut (booking_61: pyyhe tuotteelle 7): haetaan palvelimelta (public_addons); puuttuu / ei sallittu → ei valitsinta
    const addons = await A.loadAddons(p);
    const ap = addons.length ? createAddonPicker({ h, t, lang: S.lang, money, addons, persons: n, onChange: () => refreshSum() }) : null;
    const aLabel = (a) => (S.lang === 'en' && a.name_en) || a.name;
    const chosenAddons = () => addons.filter((a) => (ap?.qty.get(a.id) || 0) > 0);
    const addonRows = () => chosenAddons().flatMap((a) => [h('dt', { text: aLabel(a) }), h('dd', { 'data-testid': `sum-addon-${a.code || a.id}`, text: `${ap.qty.get(a.id)} × ${money(a.price)}` })]);
    const totalNow = () => baseTotal + (ap ? ap.total() : 0);
    const optText = () => (opt ? O.optName(O.findOption(p, opt), S.lang) : ot.notChosen);
    const optDd = h('dd', { 'data-testid': 'sum-option', text: optText() });
    const sumRows = () => [h('dt', { text: t.what }), h('dd', { text: pname(p) }), showOpt ? [h('dt', { text: ot.what }), optDd] : null, h('dt', { text: tr.date }), h('dd', { text: dayLong(slot.start) }),
      h('dt', { text: tr.time }), h('dd', { text: slot.end ? `${tm(slot.start)}–${tm(slot.end)}` : tm(slot.start) }), scheduleRows(p, slot.start), h('dt', { text: t.persons }), h('dd', { text: String(n) }), addonRows()].flat();   // .flat(): sisäkkäiset rivilistat (valitsin, aikataulu, lisäpalvelut) samaan tasoon
    const sumList = h('dl', { class: 'bk-sum' }, sumRows());
    const totalEl = h('strong', { class: 'bk-total', 'data-testid': 'sum-total', text: money(totalNow()) });
    const refreshSum = () => { sumList.replaceChildren(...sumRows().flat(2).filter(Boolean)); totalEl.textContent = money(totalNow()); };
    const optP = showOpt ? optPicker(p, { value: opt, required: needOpt, onChange: (code) => { opt = code; optDd.textContent = optText(); pickWhen.textContent = whenText(); } }) : null;
    const cf = customerFields(), legal = legalFields(), { terms, consent } = legal;
    const msg = h('div', { id: 'bk-msg' });
    const next = h('button', { type: 'submit', class: 'btn', text: tr.toReview });
    const form = h('form', { class: 'bk-form', novalidate: true, onsubmit: (ev) => {
      ev.preventDefault(); msg.replaceChildren();
      if (!O.optionOk(p, opt)) { optP.setError(ot['err.option_required']); optP.focus(); return; }
      const cust = cf.read(form, msg); if (!cust) return;
      if (!terms.checked) { msg.append(errorBox(t.acceptTermsErr)); terms.focus(); return; }
      review(cust, (new FormData(form).get('note') || '').trim());
    } }, optP ? optP.node : null, ap ? ap.node : null, cf.node, legal.nodes, msg, next);
    form.addEventListener('input', () => msg.replaceChildren());
    const whenText = () => `${opt ? `${O.optName(O.findOption(p, opt), S.lang)} · ` : ''}${when(slot.start)}${slot.end ? `–${tm(slot.end)}` : ''} · ${n} ${t.person}`;
    const pickWhen = h('span', { class: 'bk-pick-when', text: whenText() });
    const pickChange = h('a', { class: 'bk-pick-change', href: back, text: t.changeSlot });
    pickChange.addEventListener('click', () => { pickChange.href = backUrl(); });   // palaa tuotesivulle valinta mukana
    const pick = h('section', { class: 'bk-pick bk-pick-tr', 'aria-label': tr.picked },
      pimg(p, 'pick-img', { alt: false, w: 160, hgt: 160 }),
      h('div', { class: 'bk-pick-main' }, h('strong', { class: 'bk-pick-name', text: pname(p) }), pickWhen),
      pickChange);
    const aside = h('aside', { class: 'bk-aside', 'aria-label': t.summary }, h('h3', { text: t.summary }), sumList,
      h('p', { class: 'bk-totalrow' }, t.total + ': ', totalEl, ' ', h('small', { text: t.vatIncl })));
    const formView = h('div', { class: 'bk-checkout' }, form, aside);
    const holder = h('div', {}), topBox = h('div', { class: 'bk-tr-top' });
    // vahvistusvaihe: tiedot yhteenvetona, maksu paikan päällä, "Muokkaa tietoja" / "Vahvista varaus"
    function review(cust, note) {
      const err = h('div', { id: 'bk-rmsg', 'aria-live': 'polite' });
      const hi = { on: false, minutes: 15, extra: () => [] };   // pitotila (§17) selviää palvelimelta kun vaihe avautuu; oletus = vanha käytös
      const bookText = () => (hi.on ? ht(S.lang, 'checkout.button') : t.book);
      const ok = h('button', { type: 'button', class: 'btn', 'data-testid': 'review-submit', text: t.book });
      const edit = h('button', { type: 'button', class: 'btn light', text: tr.edit, onclick: () => { topBox.hidden = false; holder.replaceChildren(formView); revealForm(formView, form.querySelector('input,textarea')); } });
      const dl = h('dl', { class: 'bk-sum' }, h('dt', { text: t.what }), h('dd', { text: pname(p) }), showOpt ? [h('dt', { text: ot.what }), h('dd', { 'data-testid': 'review-option', text: optText() })] : null, h('dt', { text: tr.date }), h('dd', { text: dayLong(slot.start) }), h('dt', { text: tr.time }),
        h('dd', { text: slot.end ? `${tm(slot.start)}–${tm(slot.end)}` : tm(slot.start) }), scheduleRows(p, slot.start), h('dt', { text: t.persons }), h('dd', { text: String(n) }), addonRows(),
        h('dt', { text: cust.kind === 'company' ? t.contactName : t.name }), h('dd', { text: cust.name }), cust.company ? [h('dt', { text: t.companyName }), h('dd', { text: cust.company.company_name })] : null,
        h('dt', { text: t.email }), h('dd', { text: cust.email }), h('dt', { text: t.phone }), h('dd', { text: cust.phone }), note ? [h('dt', { text: t.note.replace(/\s*\(.*\)$/, '') }), h('dd', { text: note })] : null,
        null);
      const head = h('h2', { id: 'tr-review-h', text: tr.reviewTitle, tabindex: '-1' });
      ok.addEventListener('click', async () => {
        ok.disabled = edit.disabled = true; ok.textContent = hi.on ? ht(S.lang, 'checkout.creating') : t.booking; err.replaceChildren();
        const r = await A.createBooking(p, { start: slot.start, persons: n, name: cust.name, email: cust.email, phone: cust.phone, marketing: consent.checked, locale: S.lang, note, kind: cust.kind, company: cust.company, option: opt, addons: ap ? ap.payload() : [] });
        if (r.ok && r.token) { state.months.clear(); location.assign(confirmUrl(r.token)); return; }
        ok.disabled = edit.disabled = false; ok.textContent = bookText();
        if (!r.ok && O.isOptionError(r.code) && optP) {   // palvelin hylkäsi valinnan: takaisin lomakkeelle, valitsin korostettuna (virheellinen valinta tyhjennetään)
          if (r.code === 'invalid_option') { opt = null; optP.set(null); optDd.textContent = optText(); pickWhen.textContent = whenText(); }
          topBox.hidden = false; holder.replaceChildren(formView); optP.setError(errMsg(r)); optP.node.scrollIntoView?.({ block: 'center' }); optP.focus(); return;
        }
        if (!r.ok && A.isAddonError(r.code) && ap) {   // palvelin hylkäsi lisäpalvelut: takaisin lomakkeelle, virhe lisäpalveluiden kohdalla (määrävirheessä valinta säilyy, muuten tyhjennetään)
          if (r.code !== 'addon_quantity') ap.clear();
          topBox.hidden = false; holder.replaceChildren(formView); ap.setError(errMsg(r)); ap.node.scrollIntoView?.({ block: 'center' }); ap.focus(); return;
        }
        const lost = A.isSlotLost(r.code);
        err.replaceChildren(...[errorBox(r.ok ? tr.errors.generic : errMsg(r)), lost ? h('p', {}, h('a', { class: 'btn sm', href: back, text: tr.pickAnother })) : null].filter(Boolean));   // replaceChildren(null) kirjoittaisi tekstin "null"
        err.firstChild.setAttribute('tabindex', '-1'); revealIfHidden(err); err.firstChild.focus({ preventScroll: true });
      });
      const lead = h('p', { class: 'bk-note', 'data-testid': 'review-lead', text: tr.reviewLead }), holdExtra = h('div', { 'data-testid': 'review-hold-extra' });
      holdInfo().then((x) => { Object.assign(hi, x); if (!hi.on) return; if (!ok.disabled) ok.textContent = bookText(); lead.textContent = ht(S.lang, 'checkout.review', { minutes: hi.minutes }); holdExtra.replaceChildren(...hi.extra(S.lang)); });
      holder.replaceChildren(h('div', { class: 'bk-review' }, head, lead, holdExtra, dl,
        h('p', { class: 'bk-totalrow' }, t.total + ': ', h('strong', { class: 'bk-total', 'data-testid': 'review-total', text: money(totalNow()) }), ' ', h('small', { text: t.vatIncl })),
        cust.kind === 'company' ? h('p', { class: 'bk-pay bk-paynow', text: t.companyInvoiceNote }) : null, err, h('div', { class: 'bk-actions' }, edit, ok)));
      topBox.hidden = true; revealForm(holder, head);
    }
    holder.append(formView);
    topBox.append(h('h2', { text: t.bookTitle }), pick);
    mount(topBox, holder);
    focusTop();
  }

  // ---- näkymä: hoitovarauksen muutos (vahvistussivun linkki #<token>/muuta); vähintään N h ennen alkua ----
  async function viewChange(token, b, p) {
    const it = b.items[0], hours = b.change_hours_before ?? A.POLICY.changeHoursBefore;
    const curDate = new Date(it.starts_at).toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' });
    const msg = h('div', { id: 'bk-msg', 'aria-live': 'polite' });
    const save = h('button', { type: 'button', class: 'btn', disabled: true, text: t.saveChange });
    const sum = h('p', { class: 'bk-pick-sum', 'aria-live': 'polite' });
    let cur = null;
    // hoitovalinta (booking_50): nykyinen valinta items[0].option; vanha varaus ilman valintaa (null) → "valitsematta", valinta ei pakollinen muutoksessa
    const curOpt = it.option?.code || null, showOpt = O.hasOptions(p);
    let opt = curOpt;
    const optP = showOpt ? optPicker(p, { value: curOpt, required: null, label: O.rowLabel(it, S.lang), hint: curOpt ? ot.hintChange : `${ot.notChosenNote} ${ot.hintChange}`, onChange: (code) => { opt = code; refresh(); } }) : null;
    const slotChanged = () => !!cur?.slot && (cur.slot.start !== it.starts_at || cur.n !== it.persons), optChanged = () => O.optionChanged(it, opt);
    const refresh = () => { save.disabled = !(slotChanged() || optChanged()); };
    const picker = slotPicker(p, { n: it.persons, date: curDate, time: null, minStartMs: Date.now() + hours * 36e5,
      onChange: (s) => {
        cur = s;
        refresh();
        sum.textContent = s.slot ? tr.selected(`${dayLong(s.slot.start)}, ${s.time}`, s.n, money(s.slot.total ?? A.priceFor(p, s.n))) : '';
      } });
    save.addEventListener('click', async () => {
      if (!slotChanged() && !optChanged()) return;
      save.disabled = true; save.textContent = t.saving; msg.replaceChildren();
      const r = await A.changeBooking(token, { ...(slotChanged() ? { start: cur.slot.start, persons: cur.n } : {}), option: optChanged() ? opt : null });
      if (r.ok) { state.months.clear(); location.hash = token; window.scrollTo({ top: 0 }); return; }
      save.textContent = t.saveChange; save.disabled = false;
      if (O.isOptionError(r.code) && optP) { if (r.code === 'invalid_option') { opt = curOpt; optP.set(curOpt); } optP.setError(errMsg(r)); optP.focus(); refresh(); return; }
      msg.replaceChildren(errorBox(errMsg(r))); msg.firstChild.setAttribute('tabindex', '-1'); revealIfHidden(msg); msg.firstChild.focus({ preventScroll: true });
    });
    mount(h('p', {}, h('a', { href: `#${token}`, text: t.back })), h('h2', { text: t.changeTitle }),
      h('p', { class: 'bk-note', text: t.changeInfo(hours, fmt(b.change_deadline, { day: 'numeric', month: 'numeric', hour: 'numeric', minute: '2-digit', hourCycle: 'h23' })) }),
      h('dl', { class: 'bk-sum' }, h('dt', { text: t.what }), h('dd', { text: pname(p) }), showOpt ? [h('dt', { text: ot.what }), h('dd', { 'data-testid': 'change-current-option', text: it.option ? O.optName(it.option, S.lang) : ot.notChosen })] : null, h('dt', { text: t.when }), h('dd', { text: `${dayLong(it.starts_at)}, ${hm(it.starts_at)}–${hm(it.ends_at)}` }), h('dt', { text: t.persons }), h('dd', { text: String(it.persons) })),
      optP ? optP.node : null, picker.node, h('div', { class: 'bk-continue' }, sum, msg, save));
    await picker.ready; focusTop();
  }

  return { card, priceText, timelineText, viewTreatment, viewCheckout, viewChange };
}
