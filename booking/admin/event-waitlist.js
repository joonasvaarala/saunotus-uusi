// booking_210: tapahtumakerran jono. Erillinen pala, jotta hallinnan tapahtumanäkymän uudistus voi ottaa sen mukaan yhdellä kutsulla.
// Tekstit: varalla tässä, sama sisältö content/site-texts.pending-import-99.json (ui.admin.events.queue_*). Ei hintaa, ei maksuvälittäjää.

export const EVENT_QUEUE_TEXTS = {
  fi: {
    open: 'Jono',
    title: 'Jono',
    empty: 'Ei jonottajia.',
    loading: 'Ladataan jonoa…',
    error: 'Jonon lataus epäonnistui.',
    persons: '{{var:n}} hlö',
    waiting: 'Jonossa',
    notified: 'Ilmoitettu',
    booked: 'Varannut',
    cancelled: 'Poistunut',
    expired: 'Vanhentunut',
    privacy: 'Tietosuoja hyväksytty',
  },
  en: {
    open: 'Waitlist',
    title: 'Waitlist',
    empty: 'No one is waiting.',
    loading: 'Loading the waitlist…',
    error: 'Could not load the waitlist.',
    persons: '{{var:n}} guests',
    waiting: 'Waiting',
    notified: 'Notified',
    booked: 'Booked',
    cancelled: 'Left',
    expired: 'Expired',
    privacy: 'Privacy accepted',
  },
};

const fill = (s, vars) => String(s).replace(/\{\{var:([a-z_]+)\}\}/g, (_, n) => (vars?.[n] == null ? '' : String(vars[n])));
export const eventQueueText = (lang, key, vars) => fill(EVENT_QUEUE_TEXTS[lang === 'en' ? 'en' : 'fi'][key] || EVENT_QUEUE_TEXTS.fi[key] || key, vars);

const when = (iso) => {
  const t = Date.parse(iso || '');
  if (!Number.isFinite(t)) return '';
  return new Intl.DateTimeFormat('fi-FI', { timeZone: 'Europe/Helsinki', day: 'numeric', month: 'numeric', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(new Date(t));
};

/** Painike + paneeli. events.js lisää ne kerran korttiin. */
export function eventQueueParts(h, { lang = 'fi', ruleId, rpc }) {
  const host = h('div', { class: 'ev-queue', hidden: true, 'data-testid': 'event-queue' });
  const button = h('button', {
    type: 'button', class: 'btn sm ghost', 'data-testid': 'event-occ-queue',
    onclick: () => {
      host.hidden = !host.hidden;
      if (!host.hidden && host.dataset.loaded !== '1') {
        host.dataset.loaded = '1';
        mountEventWaitlist(host, { h, rpc, ruleId, lang });
      }
    },
  }, eventQueueText(lang, 'open'));
  return { button, host };
}

export function mountEventWaitlist(host, { h, rpc, ruleId, lang = 'fi' }) {
  host.replaceChildren(h('p', { class: 'muted', text: eventQueueText(lang, 'loading') }));
  Promise.resolve(rpc('admin_event_waitlist', { p_rule_id: ruleId })).then((rows) => {
    if (!host.isConnected) return;
    const list = Array.isArray(rows) ? rows : [];
    if (!list.length) { host.replaceChildren(h('p', { class: 'muted', 'data-testid': 'event-queue-empty', text: eventQueueText(lang, 'empty') })); return; }
    host.replaceChildren(h('h3', { text: eventQueueText(lang, 'title') }), h('ul', { class: 'ev-queue-list', 'data-testid': 'event-queue-list' }, list.map((w) => h('li', {},
      h('strong', { text: w.customer_name || '' }),
      ' ',
      h('span', { class: 'muted', text: eventQueueText(lang, 'persons', { n: w.persons }) }),
      h('div', { class: 'muted', text: [w.customer_email, w.customer_phone].filter(Boolean).join(' · ') }),
      h('div', { class: 'muted', text: `${eventQueueText(lang, w.status || 'waiting')} · ${when(w.created_at)}${w.notified_at ? ` · ${when(w.notified_at)}` : ''}${w.privacy_consent_at ? ` · ${eventQueueText(lang, 'privacy')}` : ''}` })))));
  }).catch(() => {
    if (host.isConnected) host.replaceChildren(h('p', { class: 'err', role: 'alert', text: eventQueueText(lang, 'error') }));
  });
}
