// Hoito- ja rituaalivaraukset: käyttöliittymä. Kulku: tuotekortti → henkilömäärä → päivä (vain vapaat päivät) → kellonaika (vapaat alkuajat) → asiakaslomake
// → tarkistus ja vahvistus → vahvistussivu (sama sivu ja muutoslinkki kuin vuorovarauksissa). Kaikki palvelinkutsut kulkevat adapterin (treatments.js) kautta.
// Käyttää shop.js:n apureita ja komponentteja (h, asiakaslomake, ehtokentät, tuotekuva, hero, yhteenveto-/valintapalkki, kalenteri- ja aikalistatyylit) ctx:n kautta.
import * as A from './treatments.js';

export function createTreatmentViews(c) {
  const { h, t, S, state, money, fmt, hm, dayLong, pad2, todayHel, addDays, pname, pdesc, pimg, setHero, mount, focusTop, errorBox, phoneBox, bk, customerFields, legalFields } = c;
  const tr = t.tr;
  const horizonDays = () => A.horizonDays(state.settings);
  const tm = (iso) => fmt(iso, { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).replace('.', ':');
  const dayShort = (iso) => fmt(iso, S.lang === 'fi' ? { weekday: 'short', day: 'numeric', month: 'numeric', year: 'numeric' } : { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' });
  const when = (iso) => `${dayShort(iso)}${S.lang === 'fi' ? ', klo ' : ' · '}${tm(iso)}`;
  const q = (hash) => new URLSearchParams(hash.split('?')[1] || '');
  const errMsg = (r) => tr.errors[A.errorKey(r.code)] || tr.errors.generic;

  // hintarivi: perushinta + lisähenkilö
  const priceText = (p) => {
    const base = p.price_type === 'per_person' ? `${money(p.price)} ${t.perPerson}` : money(p.price);
    return p.price_type === 'base_plus_extra_person' && p.extra_person_price && A.maxPersons(p) > 1 ? `${base} (${t.included(p.included_persons || 1)}, ${t.extra(money(p.extra_person_price))})` : base;
  };
  // tuotekortti tuotelistaan (sama rakenne kuin vuorotuotteilla)
  const card = (p) => h('li', { class: 'bk-card' },
    pimg(p, 'card-img'),
    h('h3', {}, h('a', { href: bk(`/tuote/${p.slug}`), text: pname(p) })),
    h('p', { class: 'bk-desc', text: (pdesc(p) || '').slice(0, 170) + ((pdesc(p) || '').length > 170 ? '…' : '') }),
    h('p', { class: 'bk-meta' }, h('strong', { text: priceText(p) }), p.duration_text ? ` · ${p.duration_text}` : ''),
    h('a', { class: 'btn sm', href: bk(`/tuote/${p.slug}`) }, t.choose, h('span', { class: 'sr', text: ' – ' + pname(p) })));

  // ---- valitsin: henkilömäärä → päivä (vain vapaat) → kellonaika ----
  // opts: { n, date, time, minStartMs, onChange(sel) }; sel = { n, date, time, slot|null }
  function slotPicker(p, opts) {
    const minN = A.minPersons(p), maxN = A.maxPersons(p), today = todayHel(), maxDs = addDays(today, horizonDays());
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
      h('h3', { id: 'tr-h1' }, h('span', { class: 'bk-stepn', 'aria-hidden': 'true', text: '1' }), tr.step1),
      h('div', { class: 'bk-stepper' }, minus, num, plus),
      maxN > 1 ? h('p', { class: 'bk-hint', text: tr.maxPersons(maxN) }) : h('p', { class: 'bk-hint', text: tr.onePerson }));
    // 2) päivä
    const calBox = h('div', { class: 'bk-cal bk-cal-tr', 'aria-live': 'polite' });
    const dateBox = h('section', { class: 'bk-step-box', 'aria-labelledby': 'tr-h2' }, h('h3', { id: 'tr-h2' }, h('span', { class: 'bk-stepn', 'aria-hidden': 'true', text: '2' }), tr.step2), calBox);
    // 3) kellonaika
    const timeBox = h('section', { class: 'bk-step-box', 'aria-labelledby': 'tr-h3' });
    const setN = (n) => { n = Math.min(Math.max(n, minN), maxN); if (n === st.n) { syncN(); return; } st.n = n; syncN(); st.time = null; st.slots = new Map(); refresh(); };
    const choose = (ds) => { st.date = ds; st.time = null; drawCal(false); drawTimes(); emit(); };
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
        any ? h('p', { class: 'bk-legend' }, h('span', { class: 'dot free' }), tr.legendFree) : h('p', { class: 'bk-note bk-nofree', role: 'status', text: tr.noFreeMonth }));
      // ensimmäinen avaus ilman valittua päivää: hypätään seuraavaan kuukauteen, jossa on vapaata (enintään 4 kk)
      if (!any && !st.date && st.hop < 4 && nextOk) { st.hop++; return go(1); }
      if (st.date && !st.slots.get(st.date)?.length) { st.date = null; st.time = null; drawTimes(); emit(); }
    }
    st.hop = 0;
    function drawTimes() {
      const list = st.date ? st.slots.get(st.date) || [] : [];
      if (st.ready && st.time && !list.some((s) => s.time === st.time)) st.time = null;
      timeBox.replaceChildren(h('h3', { id: 'tr-h3' }, h('span', { class: 'bk-stepn', 'aria-hidden': 'true', text: '3' }), tr.step3),
        !st.date ? h('p', { class: 'bk-note', text: tr.pickDayFirst }) : !st.ready ? h('p', { class: 'bk-loading', role: 'status', text: t.loading })
          : h('div', { 'aria-live': 'polite' }, h('p', { class: 'bk-note', text: `${dayLong(`${st.date}T12:00:00Z`)} – ${tr.startTimes}` }),
            list.length ? h('ul', { class: 'bk-times' }, list.map((s) => h('li', {}, h('button', { type: 'button', class: 'bk-time-btn', 'aria-pressed': s.time === st.time ? 'true' : 'false',
              onclick: () => { st.time = s.time; drawTimes(); emit(); timeBox.querySelector('[aria-pressed="true"]')?.focus(); } },
              h('strong', { text: s.time }), s.end ? h('span', { class: 'bk-time-end', text: `–${tm(s.end)}` }) : null))))
              : h('p', { class: 'bk-note', text: t.noSlots })));
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
    const policy = A.POLICY, ritual = A.isRitual(p);
    const sum = h('p', { class: 'bk-pick-sum', 'aria-live': 'polite' });
    const go = h('button', { type: 'button', class: 'btn', disabled: true, text: tr.continue });
    let cur = null;
    const picker = slotPicker(p, { n: +query.get('n') || undefined, date: /^\d{4}-\d\d-\d\d$/.test(query.get('d') || '') ? query.get('d') : null, time: A.timeFromToken(query.get('t')),
      onChange: (s) => {
        cur = s;
        const ok = !!(s.date && s.slot);
        go.disabled = !ok;
        sum.textContent = ok ? tr.selected(`${dayLong(s.slot.start)}, ${s.time}`, s.n, money(s.slot.total ?? A.priceFor(p, s.n))) : '';
        history.replaceState(null, '', bk(`/tuote/${p.slug}?n=${s.n}${s.date ? `&d=${s.date}` : ''}${s.date && s.time ? `&t=${A.timeToken(s.time)}` : ''}`)); c.setLast();
      } });
    go.addEventListener('click', () => { if (cur?.slot) location.hash = `#/hoito/${p.slug}/${cur.date}/${A.timeToken(cur.time)}?n=${cur.n}`; });
    mount(h('p', {}, h('a', { href: bk('/'), text: t.backList })),
      h('p', { class: 'bk-desc', text: pdesc(p) || '' }),
      h('p', { class: 'bk-meta' }, h('strong', { text: priceText(p) }), p.duration_text ? ` · ${p.duration_text}` : ''),
      h('div', { class: 'bk-notice bk-tr-info' }, h('p', { text: tr.info(policy) }), h('p', { text: tr.horizon(A.horizonDays(state.settings)) }), ritual ? h('p', { text: tr.ritualInfo(policy) }) : null, h('p', { text: tr.payNote })),
      picker.node, h('div', { class: 'bk-continue' }, sum, go));
    await picker.ready;
    if (!query.get('n')) focusTop();
  }

  // ---- näkymä: lomake + tarkistus (#/hoito/<slug>/<pvm>/<HHMM>?n=) ----
  async function viewCheckout(p, ds, tok, query) {
    setHero(p);
    const time = A.timeFromToken(tok), n = Math.min(Math.max(+query.get('n') || A.minPersons(p), A.minPersons(p)), A.maxPersons(p));
    const back = bk(`/tuote/${p.slug}?n=${n}${/^\d{4}-\d\d-\d\d$/.test(ds) ? `&d=${ds}` : ''}${time ? `&t=${tok}` : ''}`);
    let slot = null;
    if (time && /^\d{4}-\d\d-\d\d$/.test(ds)) {
      try { slot = (await A.loadAvailability(p, n, ds, ds)).get(ds)?.find((s) => s.time === time) || null; } catch { mount(errorBox(t.loadError), phoneBox()); focusTop(); return; }
    }
    if (!slot) { mount(h('p', {}, h('a', { href: bk(`/tuote/${p.slug}`), text: t.backList })), errorBox(tr.errors.taken), h('p', {}, h('a', { class: 'btn sm', href: back, text: tr.pickAnother }))); focusTop(); return; }
    const total = slot.total ?? A.priceFor(p, n);
    const sumList = h('dl', { class: 'bk-sum' }, h('dt', { text: t.what }), h('dd', { text: pname(p) }), h('dt', { text: tr.date }), h('dd', { text: dayLong(slot.start) }),
      h('dt', { text: tr.time }), h('dd', { text: slot.end ? `${tm(slot.start)}–${tm(slot.end)}` : tm(slot.start) }), h('dt', { text: t.persons }), h('dd', { text: String(n) }));
    const cf = customerFields(), legal = legalFields(), { terms, consent } = legal;
    const msg = h('div', { id: 'bk-msg' });
    const next = h('button', { type: 'submit', class: 'btn', text: tr.toReview });
    const form = h('form', { class: 'bk-form', novalidate: true, onsubmit: (ev) => {
      ev.preventDefault(); msg.replaceChildren();
      const cust = cf.read(form, msg); if (!cust) return;
      if (!terms.checked) { msg.append(errorBox(t.acceptTermsErr)); terms.focus(); return; }
      review(cust, (new FormData(form).get('note') || '').trim());
    } }, cf.node, legal.nodes, msg, next);
    form.addEventListener('input', () => msg.replaceChildren());
    const pick = h('section', { class: 'bk-pick bk-pick-tr', 'aria-label': tr.picked },
      pimg(p, 'pick-img', { alt: false, w: 160, hgt: 160 }),
      h('div', { class: 'bk-pick-main' }, h('strong', { class: 'bk-pick-name', text: pname(p) }),
        h('span', { class: 'bk-pick-when', text: `${when(slot.start)}${slot.end ? `–${tm(slot.end)}` : ''} · ${n} ${t.person}` })),
      h('a', { class: 'bk-pick-change', href: back, text: t.changeSlot }));
    const aside = h('aside', { class: 'bk-aside', 'aria-label': t.summary }, h('h3', { text: t.summary }), sumList,
      h('p', { class: 'bk-totalrow' }, t.total + ': ', h('strong', { class: 'bk-total', text: money(total) }), ' ', h('small', { text: t.vatIncl })), h('p', { class: 'bk-pay', text: tr.payNote }));
    const formView = h('div', { class: 'bk-checkout' }, form, aside);
    const holder = h('div', {}), topBox = h('div', { class: 'bk-tr-top' });
    // vahvistusvaihe: tiedot yhteenvetona, maksu paikan päällä, "Muokkaa tietoja" / "Vahvista varaus"
    function review(cust, note) {
      const err = h('div', { id: 'bk-rmsg', 'aria-live': 'polite' });
      const ok = h('button', { type: 'button', class: 'btn', text: t.book });
      const edit = h('button', { type: 'button', class: 'btn light', text: tr.edit, onclick: () => { topBox.hidden = false; holder.replaceChildren(formView); form.querySelector('input,textarea')?.focus(); window.scrollTo({ top: 0 }); } });
      const dl = h('dl', { class: 'bk-sum' }, h('dt', { text: t.what }), h('dd', { text: pname(p) }), h('dt', { text: tr.date }), h('dd', { text: dayLong(slot.start) }), h('dt', { text: tr.time }),
        h('dd', { text: slot.end ? `${tm(slot.start)}–${tm(slot.end)}` : tm(slot.start) }), h('dt', { text: t.persons }), h('dd', { text: String(n) }),
        h('dt', { text: cust.kind === 'company' ? t.contactName : t.name }), h('dd', { text: cust.name }), cust.company ? [h('dt', { text: t.companyName }), h('dd', { text: cust.company.company_name })] : null,
        h('dt', { text: t.email }), h('dd', { text: cust.email }), h('dt', { text: t.phone }), h('dd', { text: cust.phone }), note ? [h('dt', { text: t.note.replace(/\s*\(.*\)$/, '') }), h('dd', { text: note })] : null,
        null);
      const head = h('h2', { id: 'tr-review-h', text: tr.reviewTitle, tabindex: '-1' });
      ok.addEventListener('click', async () => {
        ok.disabled = edit.disabled = true; ok.textContent = t.booking; err.replaceChildren();
        const r = await A.createBooking(p, { start: slot.start, persons: n, name: cust.name, email: cust.email, phone: cust.phone, marketing: consent.checked, locale: S.lang, note, kind: cust.kind, company: cust.company });
        if (r.ok && r.token) { state.months.clear(); location.assign(`${S.confirmHref}#${r.token}`); return; }
        ok.disabled = edit.disabled = false; ok.textContent = t.book;
        const lost = A.isSlotLost(r.code);
        err.replaceChildren(errorBox(r.ok ? tr.errors.generic : errMsg(r)), lost ? h('p', {}, h('a', { class: 'btn sm', href: back, text: tr.pickAnother })) : null);
        err.firstChild.setAttribute('tabindex', '-1'); err.firstChild.focus();
      });
      holder.replaceChildren(h('div', { class: 'bk-review' }, head, h('p', { class: 'bk-note', text: tr.reviewLead }), dl,
        h('p', { class: 'bk-totalrow' }, t.total + ': ', h('strong', { class: 'bk-total', text: money(total) }), ' ', h('small', { text: t.vatIncl })),
        h('p', { class: 'bk-pay bk-paynow', text: cust.kind === 'company' ? t.companyNote : tr.payNote }), err, h('div', { class: 'bk-actions' }, edit, ok)));
      topBox.hidden = true; head.focus(); window.scrollTo({ top: 0 });
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
    const picker = slotPicker(p, { n: it.persons, date: curDate, time: null, minStartMs: Date.now() + hours * 36e5,
      onChange: (s) => {
        cur = s; const ok = !!s.slot && (s.slot.start !== it.starts_at || s.n !== it.persons);
        save.disabled = !ok;
        sum.textContent = s.slot ? tr.selected(`${dayLong(s.slot.start)}, ${s.time}`, s.n, money(s.slot.total ?? A.priceFor(p, s.n))) : '';
      } });
    save.addEventListener('click', async () => {
      if (!cur?.slot) return;
      save.disabled = true; save.textContent = t.saving; msg.replaceChildren();
      const r = await A.changeBooking(token, { start: cur.slot.start, persons: cur.n });
      if (r.ok) { state.months.clear(); location.hash = token; window.scrollTo({ top: 0 }); return; }
      save.textContent = t.saveChange; save.disabled = false;
      msg.replaceChildren(errorBox(errMsg(r))); msg.firstChild.setAttribute('tabindex', '-1'); msg.firstChild.focus();
    });
    mount(h('p', {}, h('a', { href: `#${token}`, text: t.back })), h('h2', { text: t.changeTitle }),
      h('p', { class: 'bk-note', text: t.changeInfo(hours, fmt(b.change_deadline, { day: 'numeric', month: 'numeric', hour: 'numeric', minute: '2-digit', hourCycle: 'h23' })) }),
      h('dl', { class: 'bk-sum' }, h('dt', { text: t.what }), h('dd', { text: pname(p) }), h('dt', { text: t.when }), h('dd', { text: `${dayLong(it.starts_at)}, ${hm(it.starts_at)}–${hm(it.ends_at)}` }), h('dt', { text: t.persons }), h('dd', { text: String(it.persons) })),
      picker.node, h('div', { class: 'bk-continue' }, sum, msg, save));
    await picker.ready; focusTop();
  }

  return { card, priceText, viewTreatment, viewCheckout, viewChange };
}
