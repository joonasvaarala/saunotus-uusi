import { isMultiDay, occurrenceText } from './event-sale.js';

// Koulutuksen ilmoittautuminen (booking_226). Puhdas hintalasku + kassalomake.
// Verkossa maksetaan vain varausmaksu. Lisävalinnat nostavat myöhemmin laskutettavaa loppusummaa.
// Yhden hengen huone voi olla täynnä (available: false) — ruutua ei voi valita.

export const ADDON_LABEL = {
  fi: { single_room: 'Yhden hengen huone', internship: 'Harjoittelujakso' },
  en: { single_room: 'Single room', internship: 'Internship period' },
};

export const TRAINING_TEXTS = {
  fi: {
    deposit_now: 'Varausmaksu nyt',
    course_price: 'Kurssin hinta',
    addons: 'Lisävalinnat',
    total: 'Loppusumma',
    remaining: 'Laskutetaan myöhemmin',
    balance_later: 'Loppusumma laskutetaan myöhemmin. Verkossa maksetaan vain varausmaksu.',
    single_room_full: 'Yhden hengen huoneet ovat täynnä tälle ajalle.',
    country: 'Maa',
    language: 'Kieli',
    lang_fi: 'suomi',
    lang_en: 'englanti',
    privacy: 'Hyväksyn tietosuojaselosteen',
    places: 'Paikkoja jäljellä',
    pay_online: 'Maksa verkossa',
    segments: 'Jaksot',
  },
  en: {
    deposit_now: 'Reservation fee due now',
    course_price: 'Course price',
    addons: 'Options',
    total: 'Course total',
    remaining: 'To be invoiced later',
    balance_later: 'The balance is invoiced later. Only the reservation fee is paid online.',
    single_room_full: 'Single rooms are full for this date.',
    country: 'Country',
    language: 'Language',
    lang_fi: 'Finnish',
    lang_en: 'English',
    privacy: 'I accept the privacy notice',
    places: 'Places left',
    pay_online: 'Pay online',
    segments: 'Segments',
  },
};

// FI ensin, sitten yleisimmät maat. Koodi on ISO 3166-1 alpha-2.
export const COUNTRIES = [
  ['FI', 'Suomi', 'Finland'], ['SE', 'Ruotsi', 'Sweden'], ['NO', 'Norja', 'Norway'], ['DK', 'Tanska', 'Denmark'],
  ['EE', 'Viro', 'Estonia'], ['LV', 'Latvia', 'Latvia'], ['LT', 'Liettua', 'Lithuania'], ['DE', 'Saksa', 'Germany'],
  ['FR', 'Ranska', 'France'], ['ES', 'Espanja', 'Spain'], ['IT', 'Italia', 'Italy'], ['NL', 'Alankomaat', 'Netherlands'],
  ['BE', 'Belgia', 'Belgium'], ['AT', 'Itävalta', 'Austria'], ['CH', 'Sveitsi', 'Switzerland'], ['GB', 'Iso-Britannia', 'United Kingdom'],
  ['IE', 'Irlanti', 'Ireland'], ['PL', 'Puola', 'Poland'], ['CZ', 'Tšekki', 'Czechia'], ['PT', 'Portugali', 'Portugal'],
  ['GR', 'Kreikka', 'Greece'], ['IS', 'Islanti', 'Iceland'], ['US', 'Yhdysvallat', 'United States'], ['CA', 'Kanada', 'Canada'],
  ['AU', 'Australia', 'Australia'], ['NZ', 'Uusi-Seelanti', 'New Zealand'], ['JP', 'Japani', 'Japan'], ['CN', 'Kiina', 'China'],
  ['IN', 'Intia', 'India'], ['BR', 'Brasilia', 'Brazil'], ['HU', 'Unkari', 'Hungary'], ['RO', 'Romania', 'Romania'],
];

const round2 = (n) => Math.round((Number(n) + Number.EPSILON) * 100) / 100;

export function isTrainingProduct(p) {
  return p?.category === 'training' || p?.deposit === true;
}

/** listed:false ei päädy kaupan listoihin eikä päivänäkymään. */
export function listedProducts(products) {
  return (products || []).filter((p) => p && p.listed !== false);
}

/**
 * Snapshot kassalla. Hinnat tulevat palvelimen tarjouksesta, ei kentistä.
 * total = kurssin hinta + valitut lisät. remaining = total - varausmaksu.
 * Kurssin hinta puuttuu → total ja remaining ovat null (loppusumma ei ole tiedossa).
 * Valittu täysi lisä (available: false) merkitään blocked-koodilla.
 */
export function trainingQuote({ coursePrice, deposit, offers, selected } = {}) {
  const want = new Set(selected || []);
  const rows = (offers || []).filter((o) => o && want.has(o.code));
  const blocked = rows.find((o) => o.available === false);
  const addonsTotal = round2(rows.reduce((s, o) => s + Number(o.price || 0), 0));
  const base = coursePrice == null || coursePrice === '' || Number.isNaN(Number(coursePrice)) ? null : round2(coursePrice);
  const total = base == null ? null : round2(base + addonsTotal);
  const dep = round2(deposit ?? 0);
  const remaining = total == null ? null : round2(total - dep);
  return {
    base, addons: rows.map((o) => ({ code: o.code, price: round2(o.price || 0) })),
    addonsTotal, deposit: dep, total, remaining, payNow: dep, blocked: blocked ? blocked.code : null,
  };
}

export function addonLabel(code, lang) {
  return ADDON_LABEL[lang]?.[code] || ADDON_LABEL.fi[code] || code;
}

export function countryName(code, lang) {
  const row = COUNTRIES.find((c) => c[0] === code);
  if (!row) return code || '';
  return lang === 'en' ? row[2] : row[1];
}

function tx(texts, lang, key) {
  const db = texts?.tx?.(`ui.shop.training.${key}`);
  return db || TRAINING_TEXTS[lang]?.[key] || TRAINING_TEXTS.fi[key] || key;
}

/**
 * Kassalomake. ctx: { h, t, S, money, dayLong, hm, mount, focusTop, errorBox, phoneBox, bk, rpc, confirmUrl, reveal }
 */
export function createTrainingSignup(ctx) {
  const { h, t, S, money, dayLong, hm, mount, focusTop, errorBox, bk, rpc, confirmUrl, reveal } = ctx;
  const lang = S.lang === 'en' ? 'en' : 'fi';
  const L = (key) => tx(ctx.texts, lang, key);
  const moneyOrDash = (n) => (n == null ? '–' : money(n));

  async function viewCheckout(s, p, ds) {
    const offer = await rpc('public_training_checkout', { p_rule_id: s.rule_id, p_date: ds }).catch(() => null);
    const offers = Array.isArray(offer?.addons) ? offer.addons : (p.training_addons || []).map((o) => ({ ...o, available: true }));
    const coursePrice = offer?.course_price ?? p.course_price ?? null;
    const deposit = offer?.deposit_amount ?? p.deposit_amount ?? p.price ?? 200;
    const selected = new Set();
    const msg = h('div', { id: 'bk-msg' });
    const sumList = h('dl', { class: 'bk-sum bk-training', 'data-testid': 'training-summary' });
    const totalEl = h('strong', { class: 'bk-total', 'data-testid': 'training-pay-now' });
    const privacy = h('input', { type: 'checkbox', id: 'bk-training-privacy', required: true, 'data-testid': 'training-privacy' });
    const marketing = h('input', { type: 'checkbox', id: 'bk-training-marketing' });
    const country = h('select', { id: 'country', name: 'country', 'data-testid': 'training-country' },
      COUNTRIES.map(([code, fi, en]) => h('option', { value: code, text: lang === 'en' ? en : fi, selected: code === 'FI' || null })));
    const language = h('select', { id: 'language', name: 'language', 'data-testid': 'training-language' },
      h('option', { value: 'fi', text: L('lang_fi'), selected: lang !== 'en' || null }),
      h('option', { value: 'en', text: L('lang_en'), selected: lang === 'en' || null }));
    const boxes = offers.map((o) => {
      const disabled = o.available === false;
      const input = h('input', {
        type: 'checkbox', value: o.code, disabled: disabled || null, 'data-testid': `training-addon-${o.code}`,
        onchange: () => { if (input.checked) selected.add(o.code); else selected.delete(o.code); paint(); },
      });
      const label = `${addonLabel(o.code, lang)} +${money(o.price)}`;
      return h('div', { class: 'bk-check' }, input, h('label', {}, ' ', label, disabled ? h('span', { class: 'bk-hint', text: ` ${L('single_room_full')}` }) : null));
    });
    function paint() {
      const q = trainingQuote({ coursePrice, deposit, offers, selected: [...selected] });
      const rows = [
        [L('course_price'), moneyOrDash(q.base)],
        ...q.addons.map((a) => [addonLabel(a.code, lang), `+${money(a.price)}`]),
        [L('total'), moneyOrDash(q.total)],
        [L('deposit_now'), money(q.deposit)],
        [L('remaining'), moneyOrDash(q.remaining)],
      ];
      sumList.replaceChildren(...rows.flatMap(([k, v]) => [h('dt', { text: k }), h('dd', { text: v })]));
      totalEl.textContent = money(q.payNow);
    }
    paint();
    const when = isMultiDay(s) ? occurrenceText(s, lang) : `${dayLong(s.starts_at)}, ${hm(s.starts_at)}–${hm(s.ends_at)}`;
    const places = s.remaining != null ? h('p', { class: 'bk-note', 'data-testid': 'training-places', text: `${L('places')}: ${s.remaining}` }) : null;
    const segs = Array.isArray(offer?.segments) ? offer.segments : [];
    const segList = segs.length > 1 ? h('section', { 'data-testid': 'training-segments' },
      h('h3', { text: L('segments') }),
      h('ul', { class: 'bk-slotlist' }, segs.map((g) => h('li', { text: `${(lang === 'en' && g.label_en) || g.label || ''}${g.starts_at ? ` · ${dayLong(g.starts_at)}` : ''}`.trim() })))) : null;
    const submit = h('button', { type: 'submit', class: 'btn gold', 'data-testid': 'training-submit', text: L('pay_online') });
    const form = h('form', { class: 'bk-form', novalidate: true, 'data-testid': 'training-form', onsubmit: async (ev) => {
      ev.preventDefault();
      msg.replaceChildren();
      const fd = new FormData(form);
      const name = String(fd.get('name') || '').trim();
      const email = String(fd.get('email') || '').trim();
      const phone = String(fd.get('phone') || '').trim();
      if (name.length < 2 || !email || !phone) { msg.append(errorBox(t.required)); reveal?.(msg); return; }
      if (!privacy.checked) { msg.append(errorBox(t.acceptTermsErr || L('privacy'))); reveal?.(msg); privacy.focus(); return; }
      const q = trainingQuote({ coursePrice, deposit, offers, selected: [...selected] });
      if (q.blocked) { msg.append(errorBox(L('single_room_full'))); reveal?.(msg); return; }
      submit.disabled = true;
      try {
        const r = await rpc('public_create_training_signup', {
          p_rule_id: s.rule_id, p_date: ds, p_name: name, p_email: email, p_phone: phone,
          p_country: country.value, p_language: language.value, p_locale: lang,
          p_note: String(fd.get('note') || '').trim() || null,
          p_marketing_consent: marketing.checked, p_privacy_consent: true,
          p_addons: [...selected],
        });
        if (!r?.ok) throw Object.assign(new Error(t.errors?.[r?.code] || t.errorGeneric), { mapped: true });
        location.assign(confirmUrl(r.token));
      } catch (e) {
        submit.disabled = false;
        msg.append(errorBox(e.mapped ? e.message : t.errorGeneric));
        reveal?.(msg);
      }
    } },
      h('fieldset', { class: 'bk-section' }, h('legend', { text: t.details }),
        h('div', { class: 'bk-field' }, h('label', { for: 'name', text: t.name }), h('input', { id: 'name', name: 'name', required: true, autocomplete: 'name', maxlength: 120 })),
        h('div', { class: 'bk-field' }, h('label', { for: 'email', text: t.email }), h('input', { id: 'email', name: 'email', type: 'email', required: true, autocomplete: 'email', maxlength: 254 })),
        h('div', { class: 'bk-field' }, h('label', { for: 'phone', text: t.phone }), h('input', { id: 'phone', name: 'phone', type: 'tel', required: true, autocomplete: 'tel', maxlength: 30 })),
        h('div', { class: 'bk-field' }, h('label', { for: 'country', text: L('country') }), country),
        h('div', { class: 'bk-field' }, h('label', { for: 'language', text: L('language') }), language),
        h('div', { class: 'bk-field' }, h('label', { for: 'note', text: t.note }), h('textarea', { id: 'note', name: 'note', rows: 3, maxlength: 1000 }))),
      boxes.length ? h('fieldset', { class: 'bk-section', 'data-testid': 'training-addons' }, h('legend', { text: L('addons') }), ...boxes) : null,
      h('p', { class: 'bk-note', 'data-testid': 'training-balance', text: L('balance_later') }),
      h('div', { class: 'bk-check' }, privacy, h('label', { for: 'bk-training-privacy' }, L('privacy'), ' ', h('a', { href: S.privacyHref || S.termsHref, target: '_blank', rel: 'noopener', text: t.termsLink || '' }), ' *')),
      h('div', { class: 'bk-check' }, marketing, h('label', { for: 'bk-training-marketing', text: t.consentMarketing })),
      msg, submit);
    const pick = h('section', { class: 'bk-pick', 'aria-label': t.pickedSlot },
      h('div', { class: 'bk-pick-main' }, h('strong', { class: 'bk-pick-name', text: (lang === 'en' && p.name_en) || p.name }),
        h('span', { class: 'bk-pick-when', text: when })),
      h('a', { class: 'bk-pick-change', href: bk(`/tuote/${p.slug}/${ds}`), text: t.changeSlot }));
    mount(h('h2', { text: t.bookTitle }), pick, places, segList,
      h('div', { class: 'bk-checkout' }, form,
        h('aside', { class: 'bk-aside', 'aria-label': t.summary }, h('h3', { text: t.summary }), sumList,
          h('p', { class: 'bk-totalrow' }, `${L('deposit_now')}: `, totalEl))));
    focusTop();
  }

  return { viewCheckout };
}
