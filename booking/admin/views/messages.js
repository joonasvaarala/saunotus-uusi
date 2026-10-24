// Viestit (booking_121): ohje, jälkimarkkinointi, palautepyyntö. Oikeus messages.edit.
// Ajastettu lähetys on oletuksena pois. Lyhyt ohje menee tilausvahvistukseen, kun viesti on käytössä.
import { rpc } from '../sb.js';
import { h, dialog, field, toast, run, badge, empty } from '../ui.js';
import { icon } from '../icons.js';
import { CATEGORIES, UNITS, DIRECTIONS, ANCHORS, PLACEHOLDERS, timingLabel, validateMessage, emptyMessage } from '../messages-logic.js';
import { loadRichTexts, richText } from '../rich-texts.js';
import { mountRichFields, syncRichFields } from '../rich-editor.js';

const ERR = {
  invalid_name: 'Anna nimelle 1–120 merkkiä.',
  invalid_category: 'Valitse luokka.',
  invalid_delivery_mode: 'Valitse viestin toimitustapa. Tilauksen yhteydessä näytettävä viesti on Ohje.',
  invalid_text: 'Tarkista aihe ja tekstit. Käytössä oleva ohje tarvitsee lyhyen ja täyden suomenkielisen tekstin sekä aiheen.',
  invalid_timing: 'Ajastus: määrä, yksikkö, ennen tai jälkeen, ja vertailukohta. Jälkimarkkinointi ja palautepyyntö tarvitsevat ajastuksen, kun viesti on käytössä.',
  invalid_link: 'Linkin pitää olla https-osoite.',
  invalid_product: 'Tuntematon tuote.',
  unknown_field: 'Lomakkeessa on tuntematon kenttä.',
  not_found: 'Viestiä ei löydy.',
};
const catLabel = (id) => CATEGORIES.find((c) => c.id === id)?.label || id;

export async function render({ ctx, refs }) {
  await loadRichTexts(rpc);
  const can = ctx.can('messages.edit');
  const wrap = h('section', { class: 'stack', 'data-testid': 'messages-page', 'aria-labelledby': 'messages-h' });
  if (!can) {
    wrap.append(h('h1', { id: 'messages-h', text: 'Viestit' }), h('p', { class: 'muted', text: 'Viestien muokkaus vaatii oikeuden messages.edit.' }));
    return wrap;
  }
  const products = [...(refs?.products || [])].sort((a, b) => String(a.name).localeCompare(String(b.name), 'fi'));

  async function draw() {
    const bundle = await rpc('admin_list_messages');
    const rows = bundle?.messages || [];
    const sw = h('input', { type: 'checkbox', 'data-testid': 'messages-timed', checked: bundle?.timed_enabled === true || null });
    sw.addEventListener('change', () => run(sw, async () => {
      await rpc('admin_set_messages_timed', { p_enabled: sw.checked });
      toast(sw.checked ? 'Ajastetut viestit päällä' : 'Ajastetut viestit pois päältä');
    }));
    const list = h('div', { class: 'list', 'data-testid': 'message-list' }, rows.length ? rows.map((m) => h('button', { type: 'button', class: 'listrow', 'data-testid': `message-${m.id}`, onclick: () => edit(m) },
      h('span', { class: 'what' }, h('strong', { text: m.name }), h('small', { text: timingLabel(m) })),
      h('span', { class: 'meta' }, badge(m.active ? 'ok' : 'muted', m.active ? 'Käytössä' : 'Pois'), badge('muted', catLabel(m.category)), h('small', { text: `${(m.product_ids || []).length} tuotetta` })))) : [empty('Ei viestejä. Lisää ensimmäinen pohja.')]);
    wrap.replaceChildren(
      h('div', { class: 'row between wrap' }, h('h1', { id: 'messages-h' }, icon('mail', 22), ' Viestit'), h('button', { type: 'button', class: 'btn', 'data-testid': 'message-new', onclick: () => edit(emptyMessage()) }, 'Uusi viesti')),
      h('p', { class: 'muted', text: 'Ohjeen lyhyt teksti näkyy tilausvahvistuksessa ja tilaussivulla, ja täysi teksti avautuu napista Näytä ohjeet. Jälkimarkkinointi ja palautepyyntö lähtevät vain ajastettuna. Jälkimarkkinointi lähtee vain, jos asiakkaalla on markkinointilupa, ja viestin loppuun tulee peruutuslinkki. Ohje ja palautepyyntö ovat palveluviestejä. Sama viesti lähtee tilauksesta kerran, vaikka tuotteita olisi useita.' }),
      h('label', { class: 'check big', 'data-testid': 'messages-timed-label' }, sw, h('span', {}, h('strong', { text: 'Ajastetut viestit päällä' }), h('small', { text: 'Oletus pois. Ennen päälle kytkemistä tarkista pohjat. Lähetys kunnioittaa yhä sähköpostin tilaa (off, dry_run, live) ja vastaanottajarajausta. Kytkin ei lähetä yli 36 tuntia myöhässä olevia vanhoja viestejä.' }))),
      list);
  }

  async function edit(row) {
    const isNew = !row?.id;
    const inp = (name, value, extra = {}) => h(extra.area ? 'textarea' : 'input', { name, value: value ?? '', rows: extra.area ? 5 : null, ...extra, area: null });
    const sel = (name, options, current, placeholder) => h('select', { name }, h('option', { value: '', text: placeholder, selected: !current || null }), options.map((o) => h('option', { value: o.id, text: o.label, selected: o.id === current || null })));
    const cat = h('select', { name: 'category', required: true }, CATEGORIES.map((c) => h('option', { value: c.id, text: c.label, selected: c.id === (row.category || 'instruction') || null })));
    const orderOnlyOption = h('option', { value: 'order_only', text: 'Ohjeet tilauksen yhteydessä (ei erillistä lähetystä)' });
    const deliveryMode = h('select', { name: 'delivery_mode', 'data-testid': 'message-delivery-mode' },
      h('option', { value: 'scheduled', text: 'Ajastettu lähetys' }), orderOnlyOption);
    deliveryMode.value = row.delivery_mode || 'scheduled';
    const shortBox = h('div', { class: 'stack', 'data-testid': 'message-short' },
      field('Lyhyt ohje (FI)', inp('short_fi', row.short_fi, { area: true, 'data-rich': '1' }), `Näkyy tilausvahvistuksessa. ${richText('hint_message')}`),
      field('Lyhyt ohje (EN)', inp('short_en', row.short_en, { area: true, 'data-rich': '1' }), richText('hint_message')));
    const productBox = h('div', { class: 'msg-products', 'data-testid': 'message-products' }, products.map((p) => h('label', { class: 'check' },
      h('input', { type: 'checkbox', name: 'product', value: String(p.id), checked: (row.product_ids || []).includes(p.id) || null }),
      ` ${p.name}${p.active === false ? ' (piilotettu)' : ''}`)));
    const timingBox = h('fieldset', { class: 'box', 'data-testid': 'message-timing' }, h('legend', { text: 'Ajastus' }),
      h('p', { class: 'muted', text: 'Tyhjä määrä = ei ajastettua lähetystä. Ohjeen lyhyt teksti näkyy vahvistuksessa silti. Ennen saapumista: jos hetki oli jo ohi tilausta tehdessä, viestiä ei lähetetä. Usean tuotteen tilauksessa ennen = aikaisin saapuminen, jälkeen = myöhäisin.' }),
      h('div', { class: 'row wrap' },
        field('Määrä', inp('send_amount', row.send_amount ?? '', { type: 'number', min: 1, max: 3650, inputmode: 'numeric' })),
        field('Yksikkö', sel('send_unit', UNITS, row.send_unit || '', '—')),
        field('Suunta', sel('send_direction', DIRECTIONS, row.send_direction || '', '—')),
        field('Verrattuna', sel('send_anchor', ANCHORS, row.send_anchor || '', '—'))));
    const f = h('form', { class: 'stack', 'data-testid': 'message-form' },
      field('Nimi hallinnassa', inp('name', row.name, { required: true, maxlength: 120 })),
      field('Luokka', cat),
      field('Toimitustapa', deliveryMode),
      h('label', { class: 'check' }, h('input', { type: 'checkbox', name: 'active', checked: row.active === true || null }), ' Käytössä'),
      h('div', { class: 'row wrap' }, field('Aihe (FI)', inp('subject_fi', row.subject_fi, { maxlength: 200 })), field('Aihe (EN)', inp('subject_en', row.subject_en, { maxlength: 200 }))),
      shortBox,
      field('Teksti (FI)', inp('body_fi', row.body_fi, { area: true, 'data-rich': '1' }), `Ohjeessa tämä on täysi ohje tilaussivulla. Muissa luokissa tämä on sähköpostin teksti. ${richText('hint_message')}`),
      field('Teksti (EN)', inp('body_en', row.body_en, { area: true, 'data-rich': '1' }), `Jos englanti puuttuu, käytetään suomea. ${richText('hint_message')}`),
      field('Linkki (https)', inp('link_url', row.link_url, { type: 'url', inputmode: 'url', placeholder: 'https://' }), 'Esimerkiksi Google-arvostelu. Painike sähköpostiin ja paikkamerkki {linkki}.'),
      timingBox,
      h('fieldset', { class: 'box' }, h('legend', { text: 'Tuotteet' }),
        h('p', { class: 'muted', text: 'Viesti koskee valittuja tuotteita. Yksi viesti voi olla monella tuotteella. Tilauksesta lähtee yksi sähköposti, ei yksi per tuote.' }),
        products.length ? productBox : h('p', { class: 'muted', text: 'Tuotteita ei löytynyt.' })),
      h('div', { class: 'box', 'data-testid': 'message-placeholders' }, h('strong', { text: 'Paikkamerkit' }),
        h('ul', {}, PLACEHOLDERS.map((p) => h('li', {}, h('code', { text: `{${p.key}}` }), ` ${p.help}`))),
        h('p', { class: 'muted', text: 'Jälkimarkkinointiin lisätään peruutuslinkki automaattisesti. Se ei ole paikkamerkki. Linkki asettaa markkinointiluvan pois ja estää myöhemmät jälkimarkkinointiviestit.' })),
      h('button', { class: 'btn primary', type: 'submit', text: isNew ? 'Lisää viesti' : 'Tallenna' }));
    const syncMode = () => {
      const orderOnly = deliveryMode.value === 'order_only';
      timingBox.hidden = orderOnly;
      for (const control of timingBox.querySelectorAll('input, select')) control.disabled = orderOnly;
    };
    const syncCat = () => {
      const instruction = cat.value === 'instruction';
      shortBox.hidden = !instruction;
      orderOnlyOption.disabled = !instruction;
      if (!instruction) deliveryMode.value = 'scheduled';
      syncMode();
    };
    cat.addEventListener('change', syncCat);
    deliveryMode.addEventListener('change', syncMode);
    syncCat();
    const d = dialog(isNew ? 'Uusi viesti' : row.name, f, { wide: true });
    try { await mountRichFields(f); } catch (e) { console.error(e); }
    f.addEventListener('submit', (ev) => {
      ev.preventDefault();
      const btn = f.querySelector('button[type=submit]');
      run(btn, async () => {
        syncRichFields(f);
        const fd = new FormData(f);
        const amount = String(fd.get('send_amount') || '').trim();
        const raw = {
          name: fd.get('name'), category: fd.get('category'), delivery_mode: deliveryMode.value, active: f.elements.active.checked,
          subject_fi: fd.get('subject_fi'), subject_en: fd.get('subject_en'),
          short_fi: fd.get('short_fi'), short_en: fd.get('short_en'),
          body_fi: fd.get('body_fi'), body_en: fd.get('body_en'), link_url: fd.get('link_url'),
          send_amount: amount, send_unit: fd.get('send_unit'), send_direction: fd.get('send_direction'), send_anchor: fd.get('send_anchor'),
          product_ids: [...f.querySelectorAll('input[name=product]:checked')].map((el) => Number(el.value)),
        };
        const v = validateMessage(raw);
        if (!v.ok) throw Object.assign(new Error(ERR[v.code] || v.code), { code: v.code });
        if (v.value.active && !v.value.product_ids.length) toast('Viesti on käytössä, mutta sillä ei ole tuotteita, joten se ei osu tilauksiin.');
        await rpc('admin_save_message', { p_id: isNew ? null : row.id, p_data: v.value });
        toast('Viesti tallennettu');
        d.close();
        await draw();
      });
    });
  }

  await draw();
  return wrap;
}
