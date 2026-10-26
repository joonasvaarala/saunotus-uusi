// Varausdialogi 04: maksulinkin valinnainen takaraja (1–60 päivää).
export const LINK_DEADLINE = Object.freeze({ min: 1, max: 60, initial: 14 });

export function linkExpiresDays({ enabled, days } = {}) {
  if (!enabled) return { ok: true, expiresDays: undefined };
  if ((typeof days !== 'string' && typeof days !== 'number') || String(days).trim() === '')
    return { ok: false, error: 'link_deadline_bad' };
  const n = Number(days);
  if (!Number.isInteger(n) || n < LINK_DEADLINE.min || n > LINK_DEADLINE.max)
    return { ok: false, error: 'link_deadline_bad' };
  return { ok: true, expiresDays: n };
}

export function linkValidityText(result, tx, fmtDate) {
  const expires = result?.expires_at ?? result?.link_expires_at ?? result?.expires_date;
  return expires ? tx('ui.admin.orders.link_valid_until', { date: fmtDate(expires) })
    : tx('ui.admin.orders.link_no_deadline');
}
