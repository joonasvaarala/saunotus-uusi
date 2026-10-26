// Varausdialogi 04: maksulinkin valinnainen takaraja (1–60 päivää).
export const LINK_DEADLINE = Object.freeze({ min: 1, max: 60, initial: 14 });

export function linkExpiresDays({ enabled, days } = {}) {
  if (!enabled) return { ok: true, expiresDays: undefined };
  let n;
  if (typeof days === 'number' && Number.isSafeInteger(days)) n = days;
  else if (typeof days === 'string' && /^[0-9]+$/.test(days.trim())) n = Number(days.trim());
  else return { ok: false, error: 'link_deadline_bad' };
  if (n < LINK_DEADLINE.min || n > LINK_DEADLINE.max) return { ok: false, error: 'link_deadline_bad' };
  return { ok: true, expiresDays: n };
}

export function linkValidityText(result, tx, fmtDate) {
  const raw = result?.expires_at ?? result?.link_expires_at ?? result?.expires_date;
  if (raw == null || raw === '' || raw === 'null') return tx('ui.admin.orders.link_no_deadline');
  const date = fmtDate(raw);
  if (date == null || date === '' || date === 'null' || date === 'Invalid Date') return tx('ui.admin.orders.link_no_deadline');
  return tx('ui.admin.orders.link_valid_until', { date });
}

/** Estää maksulinkin toisen lähetyksen. read() saa heittää ennen lukkoa; virhe lähetyksessä vapauttaa lukon. */
export function linkSubmitOnce(read, send) {
  let sent = false;
  return async (fd) => {
    if (sent) return;
    const expiresDays = read(fd);
    sent = true;
    try { return await send(expiresDays, fd); }
    catch (err) { sent = false; throw err; }
  };
}
