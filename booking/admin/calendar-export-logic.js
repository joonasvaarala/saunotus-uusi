// Varauskalenterin tunnisteet. Sama muoto kuin booking._calendar_id_ok. Sulkukalenteri hylätään kannassa.
const EMAIL = /^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/;
const TOKEN = /^[A-Za-z0-9_-]{8,200}$/;

export function calendarIdError(id) {
  const v = String(id ?? '').trim();
  if (!v) return null;
  if (v.length < 8 || v.length > 200 || /[\s/\\]/.test(v)) return 'invalid_calendar';
  if (EMAIL.test(v) || TOKEN.test(v)) return null;
  return 'invalid_calendar';
}

export function collectCalendarSettings(input) {
  const resources = {};
  for (const [code, id] of Object.entries(input?.resource_calendars || {})) {
    const v = String(id ?? '').trim();
    if (v) resources[code] = v;
  }
  return {
    mode: input?.mode || 'off',
    timezone: String(input?.timezone ?? '').trim(),
    window_back_days: Number(input?.window_back_days),
    window_forward_days: Number(input?.window_forward_days),
    admin_base_url: String(input?.admin_base_url ?? '').trim(),
    shared_calendar_id: String(input?.shared_calendar_id ?? '').trim(),
    resource_calendars: resources,
    fast_nudge: input?.fast_nudge === true,
  };
}

export function firstCalendarError(payload) {
  if (calendarIdError(payload?.shared_calendar_id)) return 'invalid_calendar';
  for (const id of Object.values(payload?.resource_calendars || {})) {
    if (calendarIdError(id)) return 'invalid_calendar';
  }
  return null;
}
