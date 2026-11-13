// Tilausnäkymä v3 (PR 4): asiakkaiden yhdistämisen ja anonymisoinnin puhdas logiikka (ei DOMia, ei kantakutsuja). Testit: booking/tests/asiakas-yhdistaminen-285.test.mjs
// Palvelin päättää aina oikeudet ja kytkimet (customers.admin, customer_merge_enabled, customer_anonymize_enabled); tämä vain päättää, mitä näytetään.

/** Näytetäänkö osiot. status = admin_customer_admin_status(); null/virhe → ei mitään (vanha palvelin, ei migraatiota). */
export function panelAccess({ canAdmin, status, anonymized = false, mergedInto = null } = {}) {
  const can = !!canAdmin && status?.can_admin !== false;
  const mergeOn = !!status?.merge_enabled;
  const anonOn = !!status?.anonymize_enabled;
  const live = !anonymized && !mergedInto;
  return {
    merge: can && mergeOn && live,
    anonymize: can && anonOn && live,
    // Vihje vain, jos jokin toiminto on palvelimella käytössä mutta käyttäjällä ei ole oikeutta.
    hint: !can && (mergeOn || anonOn),
  };
}

/** Palvelimen varoitus 'koodi' tai 'koodi:arvo' → { code, arg }. */
export function splitWarning(w) {
  const s = String(w ?? '');
  const i = s.indexOf(':');
  return i < 0 ? { code: s, arg: null } : { code: s.slice(0, i), arg: s.slice(i + 1) };
}

/** Tekstiavain (ilman ui.admin.-etuliitettä) koodille: customer_view.merge.blocker.kind_mismatch. */
export const mergeKey = (group, code) => `customer_view.merge.${group}.${code}`;
export const anonKey = (group, code) => `customer_view.anonymize.${group}.${code}`;

const MERGE_COUNTS = ['orders', 'gift_cards', 'annual_cards', 'marketing_consent_events', 'marketing_segment_members', 'campaign_sends', 'invoice_customers'];
const ANON_COUNTS = ['orders', 'reservations', 'payments', 'receipts', 'gift_cards_bought', 'voucher_claims', 'campaign_sends', 'consent_events'];

/** Siirrettävät määrät riveinä: tunnetuille oma teksti, tuntemattomille (palvelimen löytämät muut taulut) yleinen. Nollat jätetään pois. */
export function mergeCountRows(counts) {
  const out = [];
  const c = counts && typeof counts === 'object' ? counts : {};
  for (const k of MERGE_COUNTS) if (Number(c[k]) > 0) out.push({ key: `customer_view.merge.count.${k}`, vars: { n: Number(c[k]) } });
  for (const k of Object.keys(c).sort()) if (!MERGE_COUNTS.includes(k) && Number(c[k]) > 0) out.push({ key: 'customer_view.merge.count.other', vars: { table: k, n: Number(c[k]) } });
  return out;
}
export function anonCountRows(counts) {
  const c = counts && typeof counts === 'object' ? counts : {};
  return ANON_COUNTS.filter((k) => Number(c[k]) > 0).map((k) => ({ key: `customer_view.anonymize.count.${k}`, vars: { n: Number(c[k]) } }));
}

/** Suunta: oletuksena nykyinen asiakas säilytetään ja valittu yhdistetään siihen; swap kääntää. */
export function mergeDirection(currentId, otherId, swapped = false) {
  const cur = Number(currentId), oth = Number(otherId);
  return swapped ? { keep: oth, merge: cur } : { keep: cur, merge: oth };
}

/** Tekstit varoituksille: { key, vars }. */
export function warningRows(plan, group) {
  const mk = group === 'merge' ? mergeKey : anonKey;
  return (plan?.warnings || []).map((w) => {
    const { code, arg } = splitWarning(w);
    return { key: mk('warning', code), vars: code === 'unknown_customer_triggers' ? { names: arg || '' } : {} };
  });
}
export const blockerRows = (plan, group) => (plan?.blockers || []).map((code) => ({ key: (group === 'merge' ? mergeKey : anonKey)('blocker', code) }));

export function canConfirmMerge({ plan, checked, busy = false }) {
  return !!plan && plan.ok === true && !plan.already_merged && !!checked && !busy;
}
export function canConfirmAnonymize({ plan, checked, reason, busy = false }) {
  return !!plan && plan.ok === true && !plan.already_anonymized && !!checked && String(reason ?? '').trim().length >= 3 && !busy;
}
