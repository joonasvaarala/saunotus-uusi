// Yrityksille-sivu: valinta (saunomaan / tarjouspyyntö) ja lomakkeen lähetys.
// Tekstit ovat sivulla valmiina (data-code). Palvelimen raakaa viestiä ei näytetä.
import { rpc } from '../booking/sb.js';
import { validateQuote } from './companies-form-logic.mjs';

const root = document.documentElement;

function modeFromHash(h) {
  if (h === '#tarjous') return 'day';
  if (h === '#yritysvuorot' || h.startsWith('#/')) return 'sauna';
  return null;
}

function applyMode(mode, { focus = false } = {}) {
  root.classList.toggle('co-show-sauna', mode === 'sauna');
  root.classList.toggle('co-show-day', mode === 'day');
  for (const a of document.querySelectorAll('[data-company-choice] a')) {
    const on = a.getAttribute('data-mode') === mode;
    if (on) a.setAttribute('aria-current', 'true'); else a.removeAttribute('aria-current');
  }
  if (focus && mode) {
    const h = document.querySelector(mode === 'sauna' ? '#yritysvuorot h2' : '#tarjous h2');
    if (h) { h.setAttribute('tabindex', '-1'); h.focus(); }
  }
}

function showCode(form, code) {
  let hit = null;
  for (const el of form.querySelectorAll('[data-code]')) {
    const on = el.getAttribute('data-code') === code;
    el.hidden = !on;
    if (on) hit = el;
  }
  if (!hit) {
    const generic = form.querySelector('[data-code="error_generic"]');
    if (generic) { generic.hidden = false; hit = generic; }
  }
  if (hit) { hit.setAttribute('tabindex', '-1'); hit.focus(); }
  return hit;
}

applyMode(modeFromHash(location.hash));
const syncMode = () => applyMode(modeFromHash(location.hash));
window.addEventListener('hashchange', syncMode);
window.addEventListener('popstate', syncMode);
document.querySelector('[data-company-choice]')?.addEventListener('click', (ev) => {
  const a = ev.target.closest('a[data-mode]');
  if (!a) return;
  ev.preventDefault();
  const mode = a.getAttribute('data-mode');
  history.pushState(null, '', mode === 'day' ? '#tarjous' : '#yritysvuorot');
  applyMode(mode, { focus: true });
});

const form = document.querySelector('#company-quote');
if (form) {
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    for (const el of form.querySelectorAll('[data-code]')) el.hidden = true;
    const fd = new FormData(form);
    const offerings = fd.getAll('offering').map(String);
    const result = validateQuote({
      company_name: fd.get('company_name'),
      contact_name: fd.get('contact_name'),
      email: fd.get('email'),
      phone: fd.get('phone'),
      preferred_when: fd.get('preferred_when'),
      persons: fd.get('persons'),
      offerings,
      offering_other: fd.get('offering_other'),
      message: fd.get('message'),
      locale: form.getAttribute('data-locale') || 'fi',
      privacy: fd.get('privacy') === '1',
    });
    if (!result.ok) { showCode(form, result.code); return; }
    const btn = form.querySelector('[type="submit"]');
    if (btn) btn.disabled = true;
    try {
      const cfg = window.BOOKING_CONFIG;
      if (!cfg?.url || !cfg?.anonKey) { showCode(form, 'error_generic'); return; }
      const v = result.value;
      const r = await rpc('public_create_business_quote', {
        p_company_name: v.company_name,
        p_contact_name: v.contact_name,
        p_email: v.email,
        p_phone: v.phone,
        p_preferred_when: v.preferred_when,
        p_persons: v.persons,
        p_offerings: v.offerings,
        p_offering_other: v.offering_other,
        p_message: v.message,
        p_locale: v.locale,
        p_privacy: true,
        p_company_website: String(fd.get('company_website') || ''),
      });
      if (!r?.ok) { showCode(form, r?.code || 'error_generic'); return; }
      form.querySelector('[data-quote-fields]')?.setAttribute('hidden', '');
      showCode(form, 'ok');
    } catch {
      showCode(form, 'error_generic');
    } finally {
      if (btn) btn.disabled = false;
    }
  });
}
