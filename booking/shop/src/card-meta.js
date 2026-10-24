// Tuotekortin alaosa (tuotelista "Selaa kategorioittain", vuoro- ja hoitotuotteet): ajankohta (päivät + kellonajat / kesto) omalla rivillään
// hinnan YLÄPUOLELLA, hinta omalla rivillään sen alla. Ei enää "29 € / hlö · la–su klo 14–19" samalla rivillä.
// Kääre työntyy kortin alaosaan (margin-top:auto), jolloin hinta + Valitse-painike asettuvat rivin korteissa samalle korkeudelle.

/** @param {Function} h DOM-apuri  @param {string} price näytettävä hinta  @param {string} [when] ajankohta/kesto ('' → ei riviä) */
// Kellonaikaväli ei katkea viivan kohdalta ("17–\n19"): sanaliitos (U+2060) numeroiden ja viivan väliin; "klo 17" / "at 17" sitova välilyönti.
export const keepTimes = (s) => String(s ?? '').trim().replace(/(\d)([–-])(\d)/g, '$1\u2060$2\u2060$3').replace(/\b(klo|at) (\d)/g, '$1\u00a0$2');

export function cardMeta(h, price, when) {
  const w = keepTimes(when);
  return h('div', { class: 'bk-card-meta', 'data-testid': 'card-meta' },
    w ? h('p', { class: 'bk-meta bk-card-when', 'data-testid': 'card-when', text: w }) : null,
    h('p', { class: 'bk-meta bk-card-price', 'data-testid': 'card-price' }, h('strong', { text: price })));
}
