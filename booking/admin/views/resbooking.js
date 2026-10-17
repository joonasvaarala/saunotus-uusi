// Resurssivaraus (migraatio 17): hoito, saunotus, rituaali, seremonia, lisäpalvelu → admin_create_resource_booking (nykyiset tuotteet)
// ja "Vanha varaus" → admin_create_old_booking (vain lifecycle = 'old' -tuotteet). Valitaan tuote, aika, henkilömäärä, tila (valinnainen), asiakas, maksu.
// Ylitys (sulku- ja saunottajatarkistuksen ohitus) vaatii oikeuden bookings.override ja perustelun; vaihtoehto näkyy vain oikeuden omaaville.
import { rpc, select } from '../sb.js';
import { customerForm, customerSearch } from './customerform.js';
import { warningBox, hasWarning, MISSING_TEXT } from './therapist.js';
import { addonPicker } from './addons.js';
import { stepper } from '../stepper.js';
import { availabilityPanel, isSlotProduct } from './availability.js';
import { resName, catLabel } from './legs.js';
import { h, field, toast, run, fmtDay, fmtTime, money, todayHel, helsinkiIso, errMsg, dayStartIso, addDays, fmtDT } from '../ui.js';

export const BOOKING_TYPES = [['', 'Vuoro'], ['resurssi', 'Resurssivaraus'], ['vanha', 'Vanha varaus']];
// Varaustyypin valinta (radiogroup; nuolinäppäimet): vuoropohjainen / resurssivaraus / vanha varaus. Vaihto tallentuu URL:iin (#/uusi?tyyppi=…).
export const typeSwitch = (current, d) => h('fieldset', { class: 'srcset typeset', 'data-testid': 'booking-type' }, h('legend', { text: 'Varaustyyppi' }),
  BOOKING_TYPES.map(([v, label]) => h('label', { class: 'srcopt' }, h('input', { type: 'radio', name: 'btype', value: v, checked: v === current || null, onchange: () => { location.hash = `#/uusi${v ? `?tyyppi=${v}` : ''}${d && !v ? `?d=${d}` : ''}`; } }), h('span', { text: label }))));

const addMin = (hhmm, n) => { const [a, b] = hhmm.split(':').map(Number); const t = (a * 60 + b + n) % 1440; return `${String(Math.floor(t / 60)).padStart(2, '0')}:${String(t % 60).padStart(2, '0')}`; };

export async function render({ ctx, refs, query, kind }) {
  const old = kind === 'vanha';
  const [addons, rules] = await Promise.all([
    rpc('admin_list_addons').catch(() => []),
    select('product_space_rules', { select: 'product_id,leg_no,priority,space_id,mode,min_persons,max_persons,selection,active', active: 'eq.true' }).catch(() => null),   // staff_read; null = ei saatavilla (tilavalinta piiloon)
  ]);
  const hasRules = (id) => !rules || rules.some((x) => x.product_id === id);
  const products = refs.products.filter((p) => p.config?.resource_class === 'resourced' && hasRules(p.id)
    && (old ? p.config.lifecycle === 'old' : p.config.lifecycle === 'current' && p.config.sale_kind === 'other' && p.active !== false));
  const spaceOpts = (p) => [...new Map((rules || []).filter((x) => x.product_id === p.id && x.leg_no === 1).sort((a, b) => a.priority - b.priority).map((x) => [x.space_id, x])).values()]
    .map((x) => ({ id: x.space_id, name: refs.resources.find((r) => r.id === x.space_id)?.name || `tila ${x.space_id}`, mode: x.mode }));
  const st = { customer: null, product: products[0] || null };
  const result = h('div', {}); const errBox = h('p', { class: 'err', role: 'alert', hidden: true });
  const groups = [...new Set(products.map((p) => p.category || ''))].sort((a, b) => catLabel(a).localeCompare(catLabel(b), 'fi'));
  const prodSel = h('select', { name: 'product', required: true, 'aria-label': 'Tuote' }, groups.map((g) => h('optgroup', { label: catLabel(g) }, products.filter((p) => (p.category || '') === g).map((p) => h('option', { value: p.id, text: `${p.name}${p.config.duration_minutes ? ` (${p.config.duration_minutes} min)` : ''}` })))));
  const date = h('input', { type: 'date', name: 'date', required: true, value: /^\d{4}-\d\d-\d\d$/.test(query.get('d') || '') ? query.get('d') : todayHel() });
  const time = h('input', { type: 'time', name: 'time', required: true, step: 300, value: '15:00' });
  const end = h('input', { type: 'time', name: 'end', step: 300 });
  const endHint = h('small', { class: 'muted' }); const windowHint = h('small', { class: 'muted', 'data-testid': 'window-hint' });
  const pst = stepper({ label: 'Henkilömäärä', value: 1, min: 1, max: 99, inputName: 'n', size: 'lg' }); const persons = pst.input;   // jaettu − [ n ] + -stepper (stepper.js); persons.value / 'input'-tapahtuma toimivat kuten ennen
  const personsHint = h('small', { class: 'muted' });
  const spaceSel = h('select', { name: 'space' }); const spaceFld = field('Tila', spaceSel, 'Automaattinen valinta noudattaa tuotteen sääntöjä (esim. Lovi vain kun Rauni on suljettu).');
  const parentSel = h('select', { name: 'parent' }); const parentFld = field('Vanhempi varaus', parentSel, 'Lisäpalvelu vaatii jälkilöyly- tai yksityisvuorovarauksen samalle ajalle; automaattinen haku valitsee sopivan.');
  const price = h('input', { type: 'number', step: '0.01', min: '0', name: 'price', placeholder: 'Tuotteen hinta' });
  const invRef = h('input', { name: 'invref', maxlength: 100 });
  const note = h('textarea', { name: 'note', rows: 2 });
  const method = h('select', { name: 'method' }, refs.methods.filter((m) => m.active).map((m) => h('option', { value: m.code, text: m.label, selected: m.code === 'pay_later' || null })));
  const paid = h('input', { type: 'checkbox', name: 'paid' });
  // Lisäpalvelut hoito-/saunotus-/tapahtumavarauksessa (resurssivaraus): vain lisäpalvelut, joiden applies_modes sisältää 'resource' (pyyhe).
  // Saunavihta, turvenaamio ja jalkakylpy tarjotaan vain yleisillä vuoroilla ja yksityisvarauksessa (Joonas 17.10.). Tapahtuma (kategoria event) = tila 'event': ei lisäpalveluita (pyyhekään ei).
  const picker = addonPicker(addons, { getPersons: () => +persons.value || 0, getMode: () => (st.product?.category === 'event' ? 'event' : 'resource'), onChange: () => {} });
  // ylitys: vain bookings.override-oikeudella
  const canOverride = ctx.can('bookings.override');
  const ovr = h('input', { type: 'checkbox', name: 'override' });
  const ovrReason = h('textarea', { name: 'override_reason', rows: 2, maxlength: 300, placeholder: 'Esim. sovittu erikseen, saunottaja järjestetty', 'aria-required': 'true' });
  const ovrBox = h('fieldset', { class: 'box override-box', 'data-testid': 'override-box' }, h('legend', { text: 'Ylitys' }),
    h('label', { class: 'check' }, ovr, ' Ohita sulku-, saunottaja- ja aikaikkunatarkistus (ylitys)'),
    h('div', { class: 'ovr-reason', hidden: true }, field('Perustelu (pakollinen)', ovrReason, 'Ylitys kirjataan varaukseen ja näkyy Tarkista-listalla.')));
  ovr.addEventListener('change', () => { ovrBox.querySelector('.ovr-reason').hidden = !ovr.checked; if (ovr.checked) ovrReason.focus(); });
  // saatavuus (migraatio 25): hoidot ja rituaali näyttävät vapaat ajat; muut tuotteet ja Vanha varaus syöttävät ajan käsin
  let availFrom = date.value; let availTimer = null;
  const avail = old ? null : availabilityPanel({ getQuery: () => (isSlotProduct(st.product) ? { productId: st.product.id, from: availFrom, persons: +persons.value || 1, override: canOverride && ovr.checked, reason: ovrReason.value } : null),
    onPick: (r) => { date.value = r.session_date; time.value = fmtTime(r.starts_at); errBox.hidden = true; sync(false); } });
  if (avail) avail.node.hidden = true;
  const loadAvail = () => { if (!avail) return; avail.node.hidden = !isSlotProduct(st.product); avail.load(); };
  const reloadSoon = () => { clearTimeout(availTimer); availTimer = setTimeout(loadAvail, 400); };
  const ui = {};
  const cf = customerForm({ id: 'rb', onKind: (k) => { if (!st.customer) method.value = k === 'company' && refs.methods.some((m) => m.active && m.code === 'invoice') ? 'invoice' : 'pay_later'; } });
  const cs = customerSearch({ cf, st });
  cf.elements.name.addEventListener('input', () => { if (st.customer) cs.reset(); });

  async function loadParents(p) {
    const ids = p.config.requires_parent_product_ids || [];
    parentFld.hidden = !ids.length; parentSel.replaceChildren(h('option', { value: '', text: 'Etsi automaattisesti' }));
    if (!ids.length) return;
    const from = dayStartIso(date.value || todayHel());
    const lists = await Promise.all(ids.map((id) => rpc('admin_list_reservations', { p_product_id: id, p_from: from, p_status: 'active', p_limit: 50 }).catch(() => [])));
    for (const r of lists.flat().sort((a, b) => a.starts_at.localeCompare(b.starts_at))) parentSel.append(h('option', { value: r.reservation_id, text: `#${r.order_no} ${r.product_name} · ${fmtDT(r.starts_at)} · ${r.customer_name || '–'}` }));
  }
  const sync = (reload = true) => {
    const p = refs.productById.get(+prodSel.value) || st.product; st.product = p; if (!p) return;
    const c = p.config; const dur = c.duration_minutes;
    pst.setRange(c.min_persons || 1, c.max_persons || 99);   // rajaa myös nykyisen arvon
    personsHint.textContent = `${c.min_persons || 1}${c.max_persons ? `–${c.max_persons}` : '+'} hlö${c.required_skill ? ` · vaatii saunottajan (taito: ${c.required_skill})` : ''}`;
    endHint.textContent = dur ? `Oletuskesto ${dur} min${time.value ? ` → päättyy ${addMin(time.value, dur)}` : ''}` : 'Päättymisaika pakollinen (tuotteella ei ole oletuskestoa)';
    end.required = !dur;
    windowHint.textContent = c.time_window_class === 'therapy' ? 'Aikaikkuna: ma–pe 16:00–20:30, la–su 13:00–20:30 (päättyy viimeistään 20:30).' : c.time_window_class === 'ritual' ? 'Alkuaika vain 16:00, 16:30 tai 17:00.' : '';
    const sp = rules ? spaceOpts(p) : [];
    spaceFld.hidden = sp.length < 2; spaceSel.replaceChildren(h('option', { value: '', text: 'Automaattinen' }), ...sp.map((x) => h('option', { value: x.id, text: x.name })));
    price.placeholder = p.price != null ? `Tuotteen hinta ${money(p.price)}` : 'Hinta';
    picker.sync(); loadParents(p);
    if (reload) loadAvail();
  };
  for (const el of [prodSel, time]) el.addEventListener('change', () => sync(el === prodSel)); time.addEventListener('input', () => sync(false));
  time.addEventListener('input', () => { if (avail?.selected && fmtTime(avail.selected.starts_at) !== time.value) avail.clearSelection(); });
  persons.addEventListener('input', () => { picker.sync(); reloadSoon(); }); date.addEventListener('change', () => { if (st.product) loadParents(st.product); availFrom = date.value || todayHel(); avail?.clearSelection(); loadAvail(); });
  if (avail) { ovr.addEventListener('change', loadAvail); ovrReason.addEventListener('change', loadAvail); }

  const f = h('form', { class: 'stack card nbform', novalidate: true, 'data-testid': old ? 'old-booking-form' : 'resource-booking-form' }, h('h3', { text: old ? 'Vanha varaus' : 'Resurssivaraus' }),
    h('p', { class: 'muted', text: old ? 'Kirjaa varaus vanhalle tuotteelle (esim. siirtynyt hoito). Resurssivaikutus säilyy: sulut, päällekkäisyys ja saunottaja tarkistetaan.' : 'Nykyinen resurssituote (hoito, saunotus, rituaali, seremonia, lisäpalvelu) ylläpidon kautta. Tila ja saunottaja varataan tuotteen sääntöjen mukaan.' }),
    field('Tuote', prodSel), avail ? avail.node : null,
    h('div', { class: 'row wrap' }, field('Päivä', date), field('Alkaa', time), field('Päättyy (valinnainen)', end, null)), endHint, windowHint,
    h('div', { class: 'row wrap' }, h('div', { class: 'fld' }, h('span', { class: 'fld-lab', text: 'Henkilömäärä' }), pst.node), field('Hinta € (ohita automaattinen)', price)), personsHint,
    spaceFld, parentFld,
    h('h3', { text: 'Asiakas' }), cs.row, cs.found, cf.node, picker.node,
    field('Laskun viite / tilausnumero (valinnainen)', invRef),
    field('Sisäinen huomio', note),
    h('div', { class: 'row wrap' }, field('Maksutapa', method), h('label', { class: 'check' }, paid, ' Maksettu jo')),
    canOverride ? ovrBox : null, errBox,
    h('button', { class: 'btn primary', type: 'submit', text: old ? 'Kirjaa vanha varaus' : 'Luo resurssivaraus' }));
  f.addEventListener('submit', (ev) => { ev.preventDefault(); run(f.querySelector('button[type=submit]'), async () => { try {   // virhe vain lomakkeen sisällä (ei lisäksi ilmoitusta, joka peittäisi lomakkeen)
    errBox.hidden = true;
    const fail = (m) => { throw new Error(m); };
    if (!st.product) fail('Ei valittavia tuotteita.');
    if (!date.value || !time.value) fail('Anna päivä ja alkamisaika.');
    if (!st.customer && !cf.elements.name.value.trim()) fail('Valitse asiakas tai anna nimi.');
    const start = helsinkiIso(`${date.value}T${time.value}`);
    const endIso = end.value ? helsinkiIso(`${date.value}T${end.value}`) : null;
    if (endIso && endIso <= start) fail('Päättymisen pitää olla alkamisen jälkeen.');
    if (!endIso && !st.product.config.duration_minutes) fail('Anna päättymisaika (tuotteella ei ole oletuskestoa).');
    const useOvr = canOverride && ovr.checked;
    if (useOvr && ovrReason.value.trim().length < 3) { ovrReason.focus(); fail('Ylitys vaatii perustelun (vähintään 3 merkkiä).'); }
    const addonsSel = picker.node.hidden ? [] : picker.value();
    const args = { p_product_id: st.product.id, p_start: start, p_persons: +persons.value, ...(st.customer ? { p_customer_id: st.customer.id } : { p_customer: cf.data() }),
      p_end: endIso, p_space_id: spaceSel.value ? +spaceSel.value : null, p_payment_method: method.value, p_paid: paid.checked, p_note: note.value || null,
      p_price: price.value ? +price.value : null, p_override: useOvr, p_override_reason: useOvr ? ovrReason.value.trim() : null,
      p_addons: addonsSel.length ? addonsSel : null, p_parent_reservation_id: parentSel.value ? +parentSel.value : null, p_invoice_reference: invRef.value.trim() || null };
    let r;
    r = await rpc(old ? 'admin_create_old_booking' : 'admin_create_resource_booking', args);
    if (hasWarning(r)) toast(MISSING_TEXT, 'warn'); else toast(`Varaus luotu (tilaus #${r.order_no})`);
    result.replaceChildren(...[warningBox(r, { ctx, onDone: () => { result.replaceChildren(); } }), h('div', { class: 'card ok-box', role: 'status' }, h('h3', { text: `Varaus luotu – tilaus #${r.order_no}` }),
      h('p', { text: `${r.product_name}, ${fmtDay(r.starts_at)} ${fmtTime(r.starts_at)}–${fmtTime(r.ends_at)} · ${money(r.total)}${r.legs ? ` · ${r.legs} lisäresurssia` : ''}` }),
      h('div', { class: 'row wrap' }, h('a', { class: 'btn', href: `#/?d=${date.value}`, text: 'Näytä päivänäkymä' }), h('a', { class: 'btn ghost', href: '#/varaukset', text: 'Varaukset' })))].filter(Boolean));
    result.scrollIntoView?.({ block: 'nearest' });
  } catch (e) { errBox.textContent = errMsg(e); errBox.hidden = false; errBox.scrollIntoView?.({ block: 'nearest' }); } }); });
  const body = products.length ? [f, result] : [h('p', { class: 'empty', text: old ? 'Ei vanhoja tuotteita, joille voisi kirjata varauksen.' : 'Ei resurssituotteita, joille voisi luoda varauksen.' })];
  if (products.length) sync();
  return [h('h1', { text: old ? 'Vanha varaus' : 'Resurssivaraus' }), typeSwitch(kind), ...body];
}
