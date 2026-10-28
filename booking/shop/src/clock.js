// Yksi kellonaikamuoto: minuutit aina mukana (16.30–18.30 suomeksi, 16:30–18:30 englanniksi).
const TZ = 'Europe/Helsinki';

export function clockText(hour, minute, lang) {
  const h = String(Number(hour));
  const m = String(minute).padStart(2, '0').slice(-2);
  return `${h}${lang === 'en' ? ':' : '.'}${m}`;
}

export function clockFromIso(iso, lang, timeZone = TZ) {
  const parts = new Intl.DateTimeFormat('en-GB', { timeZone, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(new Date(iso));
  const hour = parts.find((p) => p.type === 'hour')?.value;
  const minute = parts.find((p) => p.type === 'minute')?.value;
  return hour != null && minute != null ? clockText(hour, minute, lang) : '';
}

export function clockFromHm(hhmm, lang) {
  const [h, m] = String(hhmm ?? '').slice(0, 5).split(':');
  if (h == null || m == null || m === '') return '';
  return clockText(h, m, lang);
}

export function clockRange(startIso, endIso, lang) {
  const a = clockFromIso(startIso, lang);
  const b = endIso ? clockFromIso(endIso, lang) : '';
  return b ? `${a}–${b}` : a;
}
