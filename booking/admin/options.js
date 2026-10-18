// Hallinta: tuotevalinta (booking_50, Saunahoidon hoito). Yhteiset apurit: tekstit (FI/EN), nimi, merkki "valitsematta", valitsin (radio-painikkeet),
// vaihtoehtojen haku uusille varauksille. Kieli: talous-i18n (Talous-sivun FI/EN-valitsin ja ?lang=en); muu hallinta on suomeksi.
import { rpc } from './sb.js';
import { h, badge, errMsg } from './ui.js';
import { getLang } from './talous-i18n.js';

import { OPT_TEXTS, otFor, optNameFor, optionOfFor } from './options-logic.js';
import { loadOptionTexts, optionText } from './options-texts.js';
import { UNASSIGNED_HREF } from './reservation-query.js';
export { OPT_TEXTS };
export const ot = (k, vars) => otFor(getLang(), k, vars);
export const optName = (o) => optNameFor(o, getLang());
export const optionOf = (r) => optionOfFor(r, getLang());
// Virheteksti: option-koodit omalla tekstillä (FI/EN), muut errMsg:llä.
export const optErr = (e) => { const k = `err_${e?.code}`; return OPT_TEXTS.fi[k] ? ot(k) : errMsg(e); };
// Merkki varauslistan riville: valittu hoito (hiekka) tai varoitus "valitsematta"; null jos tuotteella ei ole valintaa.
export function optionBadge(r) {
  const { name, missing } = optionOf(r);
  if (name) return h('span', { class: 'badge opt', 'data-testid': 'opt-badge', title: ot('label'), text: name });
  if (missing) return h('span', { class: 'badge warn opt-missing', 'data-testid': 'opt-badge', title: ot('missingBadgeTitle'), text: ot('notChosen') });
  return null;
}
// Valitsin: radio-painikkeet (.srcset/.srcopt, 44 px). choices = [{code,name,name_en}], value = valittu koodi tai ''. onChange(code).
export function optionPicker({ choices, value = '', label, required = false, name = `opt-${Math.random().toString(36).slice(2, 7)}`, onChange }) {
  const set = h('fieldset', { class: 'srcset optset', 'data-testid': 'admin-option-picker', 'aria-required': required ? 'true' : null },
    h('legend', { text: `${label || (required ? ot('choose') : ot('optional'))}${required ? ' *' : ''}` }),
    choices.map((c) => h('label', { class: 'srcopt' }, h('input', { type: 'radio', name, value: c.code, checked: c.code === value || null, onchange: () => onChange?.(c.code) }), h('span', { text: optName(c) }))));
  return { node: set, get value() { return set.querySelector('input:checked')?.value || ''; }, focus: () => (set.querySelector('input:checked') || set.querySelector('input'))?.focus() };
}
// Tuotteiden vaihtoehdot uusia varauksia varten (admin_list_product_options, staff). Epäonnistuminen (esim. ennen migraatiota 50) → tyhjä: valitsinta ei näytetä.
let cache = null;
export const clearOptionConfig = () => { cache = null; };
export async function loadOptionConfig(force = false) {
  if (cache && !force) return cache;
  let rows = []; try { rows = (await rpc('admin_list_product_options')) || []; } catch { rows = []; }
  cache = new Map(rows.map((p) => [p.product_id, { required: !!p.option_required && (p.options || []).some((o) => o.active), label: p.option_label, label_en: p.option_label_en, options: (p.options || []).filter((o) => o.active) }]));
  return cache;
}
export const configLabel = (cfg) => (getLang() === 'en' ? cfg.label_en || cfg.label : cfg.label || cfg.label_en) || (cfg.required ? ot('choose') : ot('optional'));
// Etusivun muistutus: tulevat hoitovaraukset ilman valittua hoitoa (admin_list_product_options.reservations_without_option). Ei koskaan heitä; null jos ei muistutettavaa.
// Linkki avaa varauslistan suodatettuna (Hoito valitsematta + Tulevat). Tekstit: ui.admin.options.*, sanakirja varalla.
export async function optionReminder() {
  let rows; try { rows = (await rpc('admin_list_product_options')) || []; } catch { return null; }
  const n = rows.reduce((a, p) => a + (+p.reservations_without_option || 0), 0);
  if (!n) return null;
  await loadOptionTexts(rpc);
  return h('p', { class: 'opt-reminder', role: 'status', 'data-testid': 'opt-reminder' }, h('span', { class: 'badge warn', text: optionText('ui.admin.options.not_chosen') }), ` ${optionText('ui.admin.options.reminder', { n })} `, h('a', { href: UNASSIGNED_HREF, 'data-testid': 'opt-reminder-link', text: optionText('ui.admin.options.reminder_link') }));
}
