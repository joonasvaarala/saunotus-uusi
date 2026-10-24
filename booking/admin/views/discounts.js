// Alennuskoodit ja vuosikortit (booking_142). Kaikki muutokset palvelimen RPC:illä (ei suoria taulukirjoituksia):
//   admin_list_discount_codes / admin_save_discount_code / admin_delete_discount_code  (catalog.edit; yhteinen vuosikorttikoodi lisäksi annual_cards.manage)
//   admin_list_annual_cards_details / admin_create_annual_card                          (annual_cards.manage)
//   admin_revoke_annual_card / admin_delete_annual_card (booking_152)                   (annual_cards.manage; poisto vain käyttämättömälle hallinnasta myönnetylle kortille, palvelin tarkistaa aina)
// Arvo lähetetään merkkijonona (palvelin tarkistaa muodon ^\d{1,6}(\.\d{1,2})?$), jotta liukuluvut eivät pyöristy matkalla.
import { rpc } from '../sb.js';
import { h, field, toast, run, dialog, empty, money, badge, fmtDate, todayHel } from '../ui.js';
import { normalizeCode, generatedDiscountCode, generatedAnnualCardCode } from '../../shop/src/discount-code-logic.js';
import { amText, loadAmTexts, amCreatedMessage } from '../annual-manage-texts.js';

const STATE = { active: ['ok', 'Voimassa'], inactive: ['muted', 'Pois käytöstä'], not_started: ['warn', 'Ei vielä alkanut'], expired: ['muted', 'Vanhentunut'], used_up: ['muted', 'Käytetty loppuun'] };
const dOnly = (ds) => (ds ? fmtDate(`${ds}T12:00:00Z`) : '');
const valueText = (d) => (d.kind === 'percent' ? `${String(d.value).replace(/\.0+$/, '').replace('.', ',')} %` : money(d.value));
const usageText = (d) => (d.usage_type === 'single' ? `Kertakäyttöinen (${d.used_count}/1)` : d.usage_type === 'multi' ? `Monikäyttöinen (${d.used_count}/${d.max_uses})` : `Pysyvä (käytetty ${d.used_count})`);
// vuoden voimassaolo: alku + 1 v − 1 pv (sama kuin verkko-ostossa)
const yearAfter = (ds) => { const d = new Date(`${ds}T12:00:00Z`); d.setUTCFullYear(d.getUTCFullYear() + 1); d.setUTCDate(d.getUTCDate() - 1); return d.toISOString().slice(0, 10); };
const VALUE_RE = /^\d{1,6}([.,]\d{1,2})?$/;

export async function render({ ctx, refs, reload }) {
  const canCodes = ctx.can('catalog.edit'), canCards = ctx.can('annual_cards.manage');
  const products = [...(refs?.products || [])].filter((p) => p.active !== false).sort((a, b) => String(a.name).localeCompare(String(b.name), 'fi'));
  const pname = (id) => products.find((p) => p.id === id)?.name || `#${id}`;
  const [codes, cards] = await Promise.all([rpc('admin_list_discount_codes'), canCards ? rpc('admin_list_annual_cards_details') : Promise.resolve(null), canCards ? loadAmTexts(rpc) : null]);
  const root = h('section', { class: 'stack', 'data-testid': 'discounts-page', 'aria-labelledby': 'disc-h' }, h('h1', { id: 'disc-h', text: 'Alennuskoodit ja vuosikortit' }),
    h('p', { class: 'muted', text: 'Asiakas syöttää koodin verkkokaupan kassalla. Alennus lasketaan palvelimella ja jaetaan tilausriveille, joten jokainen rivi säilyttää oman ALV-kantansa.' }));

  // ---- alennuskoodit
  const list = h('div', { class: 'list', 'data-testid': 'discount-list' }, (codes || []).length ? codes.map((d) => h('div', { class: 'card stack', 'data-testid': `discount-${d.code}` },
    h('div', { class: 'row between wrap' }, h('strong', { class: 'code', text: d.code }), h('span', { class: 'row wrap' },
      d.is_annual_card_code ? badge('warn', 'Yhteinen vuosikorttikoodi') : null, badge(...(STATE[d.state] || ['muted', d.state || ''])))),
    h('span', { text: d.is_annual_card_code ? 'Maksuton yleinen saunavuoro yhdelle hengelle' : `${valueText(d)} · ${d.target_scope === 'product' ? `Tuotteet: ${(d.product_ids || []).map(pname).join(', ')}` : 'Koko varaus'}` }),
    h('small', { class: 'muted', text: [d.is_annual_card_code ? null : usageText(d), d.valid_from ? `alkaa ${dOnly(d.valid_from)}` : null, d.valid_to ? `päättyy ${dOnly(d.valid_to)}` : 'ei päättymispäivää', d.description].filter(Boolean).join(' · ') }),
    canCodes && (!d.is_annual_card_code || canCards) ? h('div', { class: 'row wrap' },
      h('button', { type: 'button', class: 'btn sm', 'data-testid': `discount-edit-${d.code}`, onclick: () => editCode(d) }, 'Muokkaa'),
      h('button', { type: 'button', class: 'btn ghost sm', onclick: (e) => {
        if (!confirm(d.used_count > 0 ? `Koodia ${d.code} on käytetty, joten se poistetaan vain käytöstä. Jatketaanko?` : `Poistetaanko koodi ${d.code}?`)) return;
        run(e.currentTarget, async () => { const r = await rpc('admin_delete_discount_code', { p_id: d.id }); toast(r?.deactivated ? 'Koodi poistettu käytöstä' : 'Koodi poistettu'); reload(); });
      } }, 'Poista')) : null)) : empty('Ei alennuskoodeja.'));
  root.append(h('div', { class: 'row between wrap' }, h('h2', { text: 'Alennuskoodit' }),
    canCodes ? h('button', { type: 'button', class: 'btn primary', 'data-testid': 'discount-new', onclick: () => editCode(null) }, 'Uusi alennuskoodi') : null), list);

  // ---- vuosikortit
  if (canCards) {
    const cl = h('div', { class: 'list', 'data-testid': 'annual-list' }, (cards || []).length ? cards.map((a) => h('div', { class: 'card stack' },
      h('div', { class: 'row between wrap' }, h('strong', { class: 'code', text: a.code || '(ei koodia)' }), a.revoked_at ? badge('muted', 'Peruttu') : a.active ? badge('ok', 'Voimassa') : badge('muted', 'Pois käytöstä')),
      h('span', { text: [a.customer_name, a.customer_email].filter(Boolean).join(' · ') }),
      h('small', { class: 'muted', text: [`${dOnly(a.valid_from)} – ${dOnly(a.valid_to)}`, a.purchase_order_no ? `ostettu tilauksella #${a.purchase_order_no}` : 'myönnetty hallinnasta', a.future_bookings ? `${a.future_bookings} tuleva varaus` : null, a.notes].filter(Boolean).join(' · ') }),
      cardActions(a))) : empty('Ei vuosikortteja.'));
    root.append(h('div', { class: 'row between wrap' }, h('h2', { text: 'Vuosikortit' }),
      h('button', { type: 'button', class: 'btn primary', 'data-testid': 'annual-new', onclick: () => createCard() }, 'Myönnä vuosikortti')),
      h('p', { class: 'muted', text: amText('ui.admin.annual_manage.section_note') }), cl);
  }
  return root;

  // Peru: sama kuin asiakaskortilla (kaksi vahvistusta, tulevat varaukset valinnaisesti). Poista: vain kun palvelin merkitsee kortin
  // poistettavaksi (deletable = ei ostotilausta eikä varauksia); palvelin tarkistaa ehdot silti aina (annual_card_used / annual_card_purchased).
  function cardActions(a) {
    const revoke = a.active && !a.revoked_at ? h('button', { type: 'button', class: 'btn sm', 'data-testid': `annual-revoke-${a.id}`, onclick: (e) => run(e.currentTarget, async () => {
      if (!confirm(amText('ui.admin.annual_manage.revoke_confirm'))) return;
      const cancelFuture = confirm(amText('ui.admin.annual_manage.revoke_future_confirm'));
      const r = await rpc('admin_revoke_annual_card', { p_id: a.id, p_cancel_future: cancelFuture });
      toast(r?.cancelled ? amText('ui.admin.annual_manage.revoked_with_bookings', { count: r.cancelled }) : amText('ui.admin.annual_manage.revoked')); reload();
    }) }, amText('ui.admin.annual_manage.revoke')) : null;
    const del = a.deletable === true ? h('button', { type: 'button', class: 'btn danger sm', 'data-testid': `annual-delete-${a.id}`, onclick: (e) => run(e.currentTarget, async () => {
      if (!confirm(amText('ui.admin.annual_manage.delete_confirm', { code: a.code || `#${a.id}` }))) return;
      await rpc('admin_delete_annual_card', { p_id: a.id });
      toast(amText('ui.admin.annual_manage.deleted')); reload();
    }) }, amText('ui.admin.annual_manage.delete')) : null;
    return revoke || del ? h('div', { class: 'row wrap' }, revoke, del) : null;
  }

  function editCode(d) {
    const annual = !!d?.is_annual_card_code;
    const code = h('input', { name: 'code', value: d?.code || '', maxlength: 40, autocomplete: 'off', spellcheck: 'false', 'data-testid': 'discount-code' });
    code.addEventListener('input', () => { const p = code.selectionStart; code.value = normalizeCode(code.value); code.setSelectionRange(p, p); });
    const gen = h('button', { type: 'button', class: 'btn sm', onclick: () => { code.value = generatedDiscountCode(); } }, 'Arvo koodi');
    const desc = h('input', { name: 'description', value: d?.description || '', maxlength: 300 });
    const kind = h('select', { name: 'kind' }, h('option', { value: 'percent' }, 'Prosenttia'), h('option', { value: 'fixed' }, 'Euroa'));
    kind.value = d?.kind || 'percent';
    const val = h('input', { name: 'value', inputmode: 'decimal', value: d ? String(d.value) : '10', required: true, 'data-testid': 'discount-value' });
    const scope = h('select', { name: 'target_scope' }, h('option', { value: 'order' }, 'Koko varaus'), h('option', { value: 'product' }, 'Vain valitut tuotteet'));
    scope.value = d?.target_scope || 'order';
    const picks = h('div', { class: 'stack' }, products.map((p) => h('label', { class: 'check' }, h('input', { type: 'checkbox', value: p.id, checked: (d?.product_ids || []).includes(p.id) || null }), ` ${p.name}`)));
    const pickWrap = field('Tuotteet', picks);
    const usage = h('select', { name: 'usage_type' }, h('option', { value: 'single' }, 'Kertakäyttöinen'), h('option', { value: 'multi' }, 'Monikäyttöinen'), h('option', { value: 'permanent' }, 'Pysyvä'));
    usage.value = d?.usage_type || 'single';
    const max = h('input', { name: 'max_uses', type: 'number', min: 2, step: 1, value: d?.max_uses || 10 });
    const maxWrap = field('Käyttökertoja enintään', max);
    const from = h('input', { type: 'date', name: 'valid_from', value: d?.valid_from || '' }), to = h('input', { type: 'date', name: 'valid_to', value: d?.valid_to || '' });
    const active = h('input', { type: 'checkbox', name: 'active', checked: d?.active !== false || null });
    const shared = canCards ? h('input', { type: 'checkbox', name: 'is_annual_card_code', checked: annual || null }) : null;
    const plain = h('div', { class: 'stack' }, h('div', { class: 'row wrap' }, field('Alennus', kind), field('Määrä', val)), field('Kohdistus', scope), pickWrap, field('Käyttö', usage), maxWrap);
    const sync = () => { const sh = !!shared?.checked; plain.hidden = sh; pickWrap.hidden = scope.value !== 'product'; maxWrap.hidden = usage.value !== 'multi'; };
    for (const el of [scope, usage, shared].filter(Boolean)) el.addEventListener('change', sync);
    sync();
    const form = h('form', { class: 'stack', novalidate: true, 'data-testid': 'discount-form' },
      field('Koodi', h('div', { class: 'row wrap' }, code, gen), 'Tyhjä = palvelin arpoo 6 merkin koodin. Sallitut merkit A–Z, 0–9 ja väliviiva.'),
      field('Kuvaus (sisäinen)', desc),
      shared ? h('label', { class: 'check' }, shared, ' Yhteinen vuosikorttikoodi (maksuton yleinen vuoro yhdelle, ei lisäpalveluita)') : null,
      plain, h('div', { class: 'row wrap' }, field('Alkaa (valinnainen)', from), field('Päättyy (valinnainen)', to)),
      h('label', { class: 'check' }, active, ' Käytössä'),
      h('button', { type: 'submit', class: 'btn primary', 'data-testid': 'discount-save' }, 'Tallenna'));
    const dlg = dialog(d ? `Muokkaa koodia ${d.code}` : 'Uusi alennuskoodi', form);
    form.addEventListener('submit', (ev) => {
      ev.preventDefault();
      run(form.querySelector('[type=submit]'), async () => {
        const sh = !!shared?.checked, v = val.value.trim();
        if (!sh && !VALUE_RE.test(v)) throw new Error('Tarkista määrä (esim. 10 tai 12,50).');
        const pids = [...picks.querySelectorAll('input:checked')].map((x) => +x.value);
        if (!sh && scope.value === 'product' && !pids.length) throw new Error('Valitse vähintään yksi tuote.');
        const data = { code: normalizeCode(code.value), description: desc.value.trim() || null, kind: kind.value, value: sh ? '100' : v.replace(',', '.'),
          usage_type: usage.value, max_uses: usage.value === 'multi' ? String(max.value) : null, target_scope: scope.value, product_ids: scope.value === 'product' ? pids : [],
          valid_from: from.value || null, valid_to: to.value || null, active: active.checked, is_annual_card_code: sh };
        const r = await rpc('admin_save_discount_code', { p_id: d?.id ?? null, p_data: data });
        toast(`Koodi ${r.code} tallennettu`); dlg.close(); reload();
      });
    });
  }

  function createCard() {
    const q = h('input', { type: 'search', placeholder: 'Nimi, sähköposti tai puhelin', 'aria-label': 'Hae asiakasta', 'data-testid': 'annual-customer-search' });
    const sel = h('select', { name: 'customer', required: true, 'data-testid': 'annual-customer' }, h('option', { value: '' }, 'Hae ensin asiakas'));
    let timer = null;
    q.addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(async () => {
      const rows = q.value.trim().length >= 2 ? await rpc('admin_list_customers', { p_search: q.value.trim(), p_limit: 20, p_offset: 0 }).catch(() => []) : [];
      sel.replaceChildren(h('option', { value: '' }, rows.length ? 'Valitse asiakas' : 'Ei osumia'), ...rows.map((c) => h('option', { value: c.id }, [c.name, c.email, c.phone].filter(Boolean).join(' · '))));
      if (rows.length === 1) sel.value = String(rows[0].id);
    }, 300); });
    const from = h('input', { type: 'date', name: 'valid_from', value: todayHel(), required: true }), to = h('input', { type: 'date', name: 'valid_to' });
    const code = h('input', { name: 'code', maxlength: 40, autocomplete: 'off', spellcheck: 'false', 'data-testid': 'annual-code' });
    code.addEventListener('input', () => { code.value = normalizeCode(code.value); });
    const gen = h('button', { type: 'button', class: 'btn sm', 'data-testid': 'annual-code-generate', onclick: () => { code.value = generatedAnnualCardCode(); } }, amText('ui.admin.annual_manage.generate'));
    const notes = h('input', { name: 'notes', maxlength: 300 });
    // booking_154: "Lähetä koodi asiakkaalle" (oletuksena päällä) → p_send_email
    const send = h('input', { type: 'checkbox', name: 'send_email', checked: true, 'data-testid': 'annual-send-email' });
    const form = h('form', { class: 'stack', novalidate: true }, field('Asiakas', h('div', { class: 'stack' }, q, sel)),
      h('div', { class: 'row wrap' }, field('Alkaa', from), field('Päättyy', to, 'Tyhjä = vuoden päästä')),
      field(amText('ui.admin.annual_manage.code_label'), h('div', { class: 'row wrap' }, code, gen), amText('ui.admin.annual_manage.code_hint')), field('Muistiinpano', notes),
      h('label', { class: 'check' }, send, ' ', amText('ui.admin.annual_manage.send_email')),
      h('p', { class: 'muted', text: amText('ui.admin.annual_manage.send_email_hint') }),
      h('button', { type: 'submit', class: 'btn primary' }, 'Myönnä vuosikortti'));
    const dlg = dialog('Myönnä vuosikortti', form);
    form.addEventListener('submit', (ev) => {
      ev.preventDefault();
      run(form.querySelector('[type=submit]'), async () => {
        if (!sel.value) throw new Error('Valitse asiakas.');
        const r = await rpc('admin_create_annual_card', { p_customer_id: +sel.value, p_valid_from: from.value, p_valid_to: to.value || yearAfter(from.value), p_code: normalizeCode(code.value) || null, p_notes: notes.value.trim() || null, p_send_email: send.checked });
        toast(amCreatedMessage(r)); dlg.close(); reload();
      });
    });
  }
}
