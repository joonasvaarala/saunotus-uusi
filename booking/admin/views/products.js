// Tuotteet: nimet, kuvaukset, hinnat ja ALV muokataan kb.products / kb.product_price_variants -tauluihin (vain admin, SECURITY DEFINER -funktiot).
// Henkilökunta (staff) näkee tuotteet mutta ei voi muokata hintoja (ehdotus: hinnat vain adminille).
import { rpc } from '../sb.js';
import { h, dialog, field, toast, run, money, badge } from '../ui.js';

const VAT = [25.5, 24, 14, 13.5, 10, 0];
export async function render({ ctx, refs, reload }) {
  const isAdmin = ctx.role === 'admin';
  const list = h('div', { class: 'list' });
  for (const p of refs.products) {
    const c = p.config;
    list.append(h('button', { type: 'button', class: 'listrow', onclick: () => edit(p) },
      h('span', { class: 'what' }, h('strong', { text: p.name }), h('small', { text: ` ${p.category || ''}` })),
      h('span', { class: 'meta' }, c?.bookable ? badge('ok', 'Verkkovarattavissa') : badge('muted', 'Ei verkossa'), !p.active ? badge('err', 'Piilotettu') : null, h('strong', { text: money(p.price) }), h('small', { text: `ALV ${p.vat_rate} %` }))));
  }
  function edit(p) {
    const inp = (name, v, { area, ...o } = {}) => h(area ? 'textarea' : 'input', { name, value: v ?? '', rows: area ? 5 : null, disabled: !isAdmin, ...o });
    const vat = h('select', { name: 'vat_rate', disabled: !isAdmin }, VAT.map((v) => h('option', { value: v, text: `${v} %`, selected: +p.vat_rate === v || null })));
    const f = h('form', { class: 'stack' },
      field('Nimi (FI)', inp('name', p.name, { required: true })), field('Nimi (EN)', inp('name_en', p.name_en)),
      field('Kuvaus (FI)', inp('description', p.description, { area: true })), field('Kuvaus (EN)', inp('description_en', p.description_en, { area: true })),
      h('div', { class: 'row wrap' }, field('Hinta € (sis. ALV)', inp('price', p.price, { type: 'number', step: '0.01', min: '0' })), field('ALV', vat)),
      field('Hintateksti', inp('price_text', p.price_text), 'Näytetään kb:ssä; verkkokauppa laskee näytettävän hinnan hinta-kentästä. Päivitä teksti kun muutat hintaa.'),
      h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'active', disabled: !isAdmin }), ' Aktiivinen (näkyy kb:ssä)'),
      isAdmin ? h('button', { class: 'btn primary', type: 'submit', text: 'Tallenna tuote' }) : h('p', { class: 'muted', text: 'Vain ylläpitäjä voi muokata tuotteita ja hintoja.' }));
    f.active.checked = !!p.active;
    f.addEventListener('submit', (ev) => { ev.preventDefault(); run(f.querySelector('button'), async () => {
      const fd = new FormData(f);
      await rpc('admin_update_product', { p_product_id: p.id, p_patch: { name: fd.get('name'), name_en: fd.get('name_en'), description: fd.get('description'), description_en: fd.get('description_en'), price: +fd.get('price'), price_text: fd.get('price_text'), vat_rate: +fd.get('vat_rate'), active: f.active.checked } });
      toast('Tuote tallennettu'); d.close(); reload();
    }); });
    // verkkokaupan asetukset
    const c = p.config;
    const cfg = c ? h('form', { class: 'stack box' }, h('h3', { text: 'Verkkokaupan asetukset' }),
      h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'bookable', disabled: !isAdmin }), ' Varattavissa verkossa'),
      h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'shop_visible', disabled: !isAdmin }), ' Näkyy kaupan listassa'),
      h('div', { class: 'row wrap' }, field('Järjestys', h('input', { name: 'sort_order', type: 'number', value: c.sort_order, disabled: !isAdmin })), field('Min hlö', h('input', { name: 'min_persons', type: 'number', min: 1, value: c.min_persons, disabled: !isAdmin })), field('Max hlö', h('input', { name: 'max_persons', type: 'number', min: 1, value: c.max_persons ?? '', disabled: !isAdmin }))),
      isAdmin ? h('button', { class: 'btn', type: 'submit', text: 'Tallenna asetukset' }) : null) : h('p', { class: 'muted', text: 'Tuotetta ei ole vielä otettu mukaan varausjärjestelmään (product_config puuttuu).' });
    if (c) { cfg.bookable.checked = !!c.bookable; cfg.shop_visible.checked = !!c.shop_visible; cfg.addEventListener('submit', (ev) => { ev.preventDefault(); run(cfg.querySelector('button'), async () => {
      await rpc('admin_update_product_config', { p_product_id: p.id, p_patch: { bookable: cfg.bookable.checked, shop_visible: cfg.shop_visible.checked, sort_order: +cfg.sort_order.value, min_persons: +cfg.min_persons.value, max_persons: cfg.max_persons.value ? +cfg.max_persons.value : null } });
      toast('Tallennettu'); d.close(); reload(); }); }); }
    // hintavariantit
    const vars = (p.variants || []).length ? h('div', { class: 'box stack' }, h('h3', { text: 'Hintavariantit' }), ...p.variants.map((v) => {
      const inpP = h('input', { type: 'number', step: '0.01', min: '0', value: v.price, disabled: !isAdmin, 'aria-label': `Hinta: ${v.label}` });
      return h('div', { class: 'row wrap varrow' }, h('span', { class: 'grow' }, h('strong', { text: v.label }), h('small', { text: ` ${v.valid_from || ''}${v.valid_to ? '–' + v.valid_to : ''}${v.included_persons ? ` · sis. ${v.included_persons} hlö` : ''}${v.extra_person_price ? ` · lisählö ${v.extra_person_price} €` : ''}` })), inpP,
        isAdmin ? h('button', { type: 'button', class: 'btn sm', text: 'Tallenna', onclick: (e) => run(e.target, async () => { await rpc('admin_update_price_variant', { p_variant_id: v.id, p_patch: { price: +inpP.value } }); toast('Hinta tallennettu'); reload(); }) }) : null);
    })) : null;
    const d = dialog(p.name, h('div', { class: 'stack' }, f, cfg, vars), { wide: true });
  }
  return [h('h1', { text: 'Tuotteet' }), h('p', { class: 'muted', text: isAdmin ? 'Tuotetiedot tallentuvat kb-tauluihin (sivusto ja botti käyttävät samaa totuutta). Muutokset kirjataan audit-lokiin ja kb.change_logiin.' : 'Näet tuotteet; muokkaus vain ylläpitäjälle.' }), list];
}
