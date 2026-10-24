// Hiljaiset ajat (booking_162): hallinnan portaan puhdas, DOM-riippumaton validointi. Samat rajat kuin palvelimella
// (admin_quiet_rule_upsert): nimi 1–80, tunnit 1–336 kokonaislukuna, ale > 0 ja ≤ 90 (2 desimaalia), 1–20 tuotetta, loppu ≥ alku,
// aktiivinen porras ei saa jakaa tuotetta ja tuntimäärää toisen aktiivisen kanssa (quiet_overlap). Palvelin tarkistaa silti aina.
// Pohja: GPT-paketin quiet-logic.js; muutos: päällekkäisyys on virhe (palvelin hylkää), ei varoitus.
export function validateQuietRule(rule, others = []) {
  const errors = [];
  const label = String(rule?.label ?? '').trim(), labelEn = String(rule?.label_en ?? '').trim();
  const percent = String(rule?.percent ?? '').trim().replace(',', '.');
  const pct = Number(percent), hours = Number(String(rule?.hours_before ?? '').trim() || NaN);
  if (!label || label.length > 80 || labelEn.length > 80) errors.push('name');
  if (!/^\d+(?:\.\d{1,2})?$/.test(percent) || !(pct > 0 && pct <= 90)) errors.push('percent');
  if (!Number.isInteger(hours) || hours < 1 || hours > 336) errors.push('hours');
  const products = [...new Set((rule?.product_ids || []).map(Number).filter(Number.isInteger))];
  if (!products.length || products.length > 20) errors.push('products');
  const from = rule?.valid_from || null, to = rule?.valid_to || null;
  if (from && to && to < from) errors.push('dates');
  const active = rule?.active !== false;
  if (active && !errors.includes('hours') && (others || []).some((o) => o.active !== false && String(o.id) !== String(rule?.id ?? '') && +o.hours_before === hours
    && (o.product_ids || []).some((id) => products.includes(+id)))) errors.push('overlap');
  return { ok: !errors.length, errors, patch: { label, label_en: labelEn || null, product_ids: products, hours_before: hours, percent, valid_from: from, valid_to: to, active } };
}
