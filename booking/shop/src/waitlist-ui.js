// Julkinen jonotuslista rakentuu samoista h(), bk-pick, bk-form ja bk-checkout -osista kuin viewCheckout.
import { waitlistParty } from './waitlist-logic.js';
export function createWaitlistView({ h, t, S, state, loadMonth, setHero, mount, focusTop, errorBox, phoneBox, bk, rpc, pname, dayLong, hm }) {
  const backFor = (p, ds, via) => via === 'day' ? bk(`/paiva/${ds}?tuote=${p.slug}`) : bk(`/tuote/${p.slug}/${ds}`);
  const err = (code, kind) => (code === 'invalid_persons' && kind === 'event' && t.waitlistInvalidPersonsEvent) || t.waitlistErrors?.[code] || t.errorGeneric;

  async function viewWaitlist(ruleId, ds, productId, via = null) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(ds || '')) {
      mount(errorBox(t.waitlistErrors.invalid_session)); return;
    }
    const p = state.catalog.find((x) => x.id === +productId);
    const [y, m] = ds.split('-').map(Number);
    const byDay = p ? await loadMonth(p.id, y, m - 1).catch(() => ({})) : {};
    const s = (byDay[ds] || []).find((x) => x.rule_id === +ruleId);
    setHero(p || null);
    if (!s || !p || s.status === 'unavailable' || s.status === 'closed') {
      mount(errorBox(t.waitlistErrors.invalid_session), h('a', { href: bk('/'), text: t.waitlistBack })); focusTop(); return;
    }
    const back = backFor(p, ds, via);
    const pick = h('section', { class: 'bk-pick', 'aria-label': t.pickedSlot },
      h('div', { class: 'bk-pick-main' }, h('strong', { class: 'bk-pick-name', text: pname(p) }),
        h('span', { class: 'bk-pick-when', text: `${dayLong(s.starts_at)}, ${hm(s.starts_at)}–${hm(s.ends_at)}` }),
        h('span', { class: 'bk-badge full', text: t.waitlistSessionSoldOut })),
      h('a', { class: 'bk-pick-change', href: back, text: t.changeSlot }));
    if (s.status === 'available') {
      mount(h('h2', { text: t.waitlistTitle }), pick, h('p', { class: 'bk-ok', role: 'status', text: t.waitlistNotFull }),
        h('a', { class: 'btn gold', href: bk(`/varaa/${s.rule_id}/${ds}/${p.id}`), text: t.waitlistBookNow })); focusTop(); return;
    }
    // booking_148: henkilömäärä palvelutyypin mukaan (palvelin tarkistaa saman): yleinen 1–6 (booking_134, vuoron oma min/max
    // rajaa lisäksi), tapahtuma 1..kapasiteetti, yksityisvuoro ilman henkilömäärää (koko vuoro vapautuu kerralla).
    const party = waitlistParty(s, p);
    const priv = party.kind === 'private';
    let n = priv ? 1 : party.min;
    const max = priv ? 1 : party.max;
    const num = h('input', { id: 'bk-wl-n', type: 'number', min: n, max, inputmode: 'numeric', value: n, 'aria-label': t.persons });
    const dec = h('button', { type: 'button', class: 'bk-step', 'aria-label': '−' }, '−');
    const inc = h('button', { type: 'button', class: 'bk-step', 'aria-label': '+' }, '+');
    const min = n;
    const update = () => { n = Math.min(max, Math.max(min, Math.trunc(Number(num.value) || min))); num.value = n; dec.disabled = n <= min; inc.disabled = n >= max; };
    // update() lukee arvon kentästä, joten painikkeet päivittävät kentän ensin (aiemmin n-- kumoutui ja määrä jäi 1:een).
    dec.addEventListener('click', () => { num.value = n - 1; update(); });
    inc.addEventListener('click', () => { num.value = n + 1; update(); });
    num.addEventListener('change', update); update();
    const input = (key, label, attrs = {}) => h('div', { class: 'bk-field' }, h('label', { for: `bk-wl-${key}`, text: label }),
      h('input', { id: `bk-wl-${key}`, name: key, ...attrs }),
      key === 'phone' ? h('small', { class: 'bk-hint', text: t.waitlistPhoneHint }) : null);
    const msg = h('div', { 'aria-live': 'polite' });
    const btn = h('button', { type: 'submit', class: 'btn gold', text: t.waitlistJoin });
    const isEvent = party.kind === 'event';
    const privacy = isEvent ? h('div', { class: 'bk-check' },
      h('input', { type: 'checkbox', id: 'bk-wl-privacy', name: 'privacy', required: true, 'data-testid': 'waitlist-privacy' }),
      h('label', { for: 'bk-wl-privacy' }, t.waitlistPrivacy + ' ', h('a', { href: S.privacyHref || (S.lang === 'en' ? '/en/privacy/' : '/tietosuoja/'), target: '_blank', rel: 'noopener', text: t.waitlistPrivacyLink }))) : null;
    const form = h('form', { class: 'bk-form', 'data-testid': 'waitlist-form', onsubmit: async (ev) => {
      ev.preventDefault(); msg.replaceChildren(); update();
      if (isEvent && !form.privacy.checked) { msg.append(errorBox(t.waitlistPrivacyRequired)); form.privacy.focus(); return; }
      if (!form.reportValidity()) return;
      btn.disabled = true; btn.textContent = t.waitlistSubmitting;
      const f = new FormData(form);
      try {
        const args = {
          p_rule_id: s.rule_id, p_date: ds, p_persons: priv ? null : n,
          p_name: String(f.get('name') || '').trim(), p_email: String(f.get('email') || '').trim(),
          p_phone: String(f.get('phone') || '').trim() || null, p_locale: S.lang, p_whatsapp_opt_in: false,
        };
        if (isEvent) args.p_privacy_consent = true;
        const r = await rpc('public_join_waitlist', args);
        if (!r?.ok) throw Object.assign(new Error(err(r?.code, party.kind)), { mapped: true });
        const done = h('section', { class: 'bk-conf', tabindex: '-1', role: 'status', 'data-testid': 'waitlist-done' },
          h('span', { class: 'bk-status', text: t.waitlistTitle }),
          h('h2', { text: isEvent ? t.waitlistEventDone : t.waitlistDone }),
          h('p', { text: `${pname(p)} · ${dayLong(s.starts_at)} · ${hm(s.starts_at)}–${hm(s.ends_at)}${priv || r.persons == null ? '' : ` · ${r.persons} ${t.person}`}` }),
          h('p', { class: 'bk-note', text: isEvent ? t.waitlistEventDoneText : t.waitlistDoneText }),
          h('div', { class: 'bk-actions' },
            h('button', { type: 'button', class: 'btn sm light', text: t.waitlistLeave, onclick: async (ev) => {
              const b = ev.currentTarget; b.disabled = true;
              try { const v = await rpc('public_leave_waitlist', { p_token: r.token }); if (!v?.ok) throw Error('leave');
                done.replaceChildren(h('p', { class: 'bk-ok', role: 'status', text: t.waitlistLeft }), h('a', { href: back, text: t.waitlistBack }));
              } catch { b.disabled = false; done.append(errorBox(t.errorGeneric)); }
            } }), h('a', { href: back, text: t.waitlistBack })));
        mount(done); done.scrollIntoView({ block: 'start', behavior: 'smooth' }); done.focus({ preventScroll: true });
      } catch (e) { msg.append(errorBox(e?.mapped ? e.message : t.errorGeneric)); btn.disabled = false; btn.textContent = t.waitlistJoin; }
    } },
      h('p', { class: 'bk-note', text: isEvent ? t.waitlistEventIntro : t.waitlistIntro }),
      priv ? h('p', { class: 'bk-note', 'data-testid': 'wl-private-note', text: t.waitlistPrivateNote })
        : h('fieldset', { class: 'bk-section' }, h('legend', { text: t.persons }), h('div', { class: 'bk-stepper' }, dec, num, inc),
          h('small', { class: 'bk-hint', text: party.kind === 'event' ? t.waitlistPersonsHintEvent : t.waitlistPersonsHint })),
      input('name', t.name, { required: true, maxlength: 120, autocomplete: 'name' }),
      input('email', t.email, { required: true, type: 'email', maxlength: 200, autocomplete: 'email' }),
      input('phone', t.phone, { type: 'tel', maxlength: 30, autocomplete: 'tel' }),
      privacy, msg, btn);
    const aside = h('aside', { class: 'bk-aside', 'aria-label': t.summary }, h('h3', { text: t.summary }),
      h('p', { text: pname(p) }), h('p', { text: `${dayLong(s.starts_at)} · ${hm(s.starts_at)}–${hm(s.ends_at)}` }),
      h('p', { class: 'bk-note', text: isEvent ? t.waitlistEventIntro : t.waitlistIntro }));
    mount(h('h2', { text: t.waitlistTitle }), h('p', {}, h('a', { href: back, text: t.back })),
      pick, h('div', { class: 'bk-checkout' }, form, aside));
    focusTop();
  }
  return { viewWaitlist };
}
