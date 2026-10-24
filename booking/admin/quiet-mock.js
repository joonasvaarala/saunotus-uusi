// booking_162: Hiljaiset ajat -näkymän mock-RPC:t (options-mock.js / ?mock=1). Samat oikeudet ja rajat pääpiirteissään kuin palvelimella.
// Esimerkkidata ei sisällä asiakastietoja. Esikatselu: keksitty tyhjä vuoro huomiselle (−30 %) ja ylihuomiselle (−20 %) tuotteelle 26.
import { validateQuietRule } from './quiet-logic.js';

export function quietMockHandlers({ st, need, needAny, err, today }) {
  st.quiet = st.quiet || {
    enabled: false, seq: 3,
    rules: [
      { id: 1, label: 'Jälkilöyly 72 h', label_en: 'After-sauna 72 h', product_ids: [26], hours_before: 72, percent: 20, condition: 'empty_slot', channel: 'shop', valid_from: null, valid_to: null, active: true },
      { id: 2, label: 'Jälkilöyly 36 h', label_en: 'After-sauna 36 h', product_ids: [26], hours_before: 36, percent: 30, condition: 'empty_slot', channel: 'shop', valid_from: null, valid_to: null, active: true },
    ],
  };
  const q = st.quiet;
  const products = [{ id: 25, name: 'Yksityisvuoro (esimerkki)' }, { id: 26, name: 'Jälkilöyly (esimerkki)' }, { id: 49, name: 'Yksityistilaisuus (esimerkki)' }];
  const addDay = (n) => { const d = new Date(`${today}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
  return {
    admin_quiet_rules_list: () => ({ enabled: q.enabled, can_edit: st.perms.includes('catalog.edit'), can_toggle: st.perms.includes('settings.edit'),
      rules: q.rules.map((r) => ({ ...r, product_ids: [...r.product_ids] })), products }),
    admin_quiet_rule_upsert: (a) => {
      need('catalog.edit');
      const old = a.p_id != null ? q.rules.find((r) => r.id === a.p_id) : null;
      if (a.p_id != null && !old) throw err('not_found', 'Sääntöä ei löydy');
      const chk = validateQuietRule({ ...(old || { active: true }), ...(a.p_patch || {}), id: a.p_id }, q.rules);
      if (!chk.ok) throw err(chk.errors.includes('overlap') ? 'quiet_overlap' : 'invalid_value', chk.errors.join(','));
      const row = { ...(old || { id: q.seq++, condition: 'empty_slot', channel: 'shop' }), ...chk.patch, percent: Number(chk.patch.percent) };
      if (old) Object.assign(old, row); else q.rules.push(row);
      return { ok: true, rule: { ...row } };
    },
    admin_quiet_rule_delete: (a) => {
      need('catalog.edit');
      const i = q.rules.findIndex((r) => r.id === a.p_id);
      if (i < 0) throw err('not_found', 'Sääntöä ei löydy');
      q.rules.splice(i, 1);
      return { ok: true };
    },
    admin_quiet_set_enabled: (a) => {
      need('settings.edit');
      if (typeof a.p_enabled !== 'boolean') throw err('invalid_value', 'Valitse päällä / pois');
      q.enabled = a.p_enabled;
      return { ok: true, enabled: q.enabled };
    },
    admin_quiet_preview: () => {
      needAny('catalog.edit', 'settings.edit', 'bookings.view', 'bookings.create');
      const mk = (day, pct, hours) => ({ product_id: 26, rule_id: hours === 36 ? 2 : 1, session_date: addDay(day), starts_at: `${addDay(day)}T17:00:00+03:00`,
        ends_at: `${addDay(day)}T19:00:00+03:00`, percent: pct, hours_before: hours, base_price: 200, discount_amount: 200 * pct / 100, discounted_price: 200 - 200 * pct / 100 });
      return { enabled: q.enabled, from: today, to: addDay(6), offers: q.rules.some((r) => r.active) ? [mk(1, 30, 36), mk(2, 20, 72)] : [] };
    },
  };
}
