// KAUPPA-KASSA-02: lomakevirheet kenttäkohtaisiksi (form-errors.js): tarkistukset, virhekoonti, pakollisuusmerkinnät, tekstit FI+EN (tuonti 164).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { emailOk, phoneOk, validateCustomer, createFormErrors, labelText } from '../shop/src/form-errors.js';
import { T } from '../shop/src/i18n.js';

const rd = (f) => readFileSync(new URL(`../../${f}`, import.meta.url), 'utf8');
const code = (f) => rd(f).replace(/^\s*\/\/.*$/gm, '');
const keys = (errs) => errs.map((e) => `${e.field}:${e.key}`);
const ok = { name: 'Testi Asiakas', email: 'testi@example.org', phone: '040 123 4567' };

test('sähköposti ja puhelin: omat tarkistukset', () => {
  for (const v of ['a@b.fi', 'etu.suku@posti.example.com']) assert.ok(emailOk(v), v);
  for (const v of ['', 'testi', 'testi@', '@b.fi', 'a b@c.fi', 'testi@example', 'a@b..fi']) assert.ok(!emailOk(v), v);
  for (const v of ['040 123 4567', '+358 40 123 4567', '(09) 123 456', '040-1234567', '0401234567']) assert.ok(phoneOk(v), v);
  for (const v of ['', 'abc', '12345', '040 abc 123', '+', '1234567890123456']) assert.ok(!phoneOk(v), v);
});

test('validateCustomer: tyhjä lomake antaa oman viestin kullekin kentälle, kelvollinen ei virheitä', () => {
  assert.deepEqual(validateCustomer(ok), []);
  assert.deepEqual(keys(validateCustomer({})), ['name:reqName', 'email:reqEmail', 'phone:reqPhone']);
  assert.deepEqual(keys(validateCustomer({ ...ok, email: 'testi@' })), ['email:invalidEmail']);   // väärä sähköposti ei enää anna "täytä kaikki"-viestiä
  assert.deepEqual(keys(validateCustomer({ ...ok, phone: 'abc' })), ['phone:invalidPhone']);
});

test('validateCustomer: yritys → y-tunnus, postinumero ja OVT omilla viesteillään; verkkolaskukentät vain verkkolaskulla', () => {
  const co = { ...ok, company_name: 'Testi Oy', business_id: '0112038-9', street: 'Testitie 1', zip: '00100', city: 'Helsinki', einvoice_address: '003701120389', einvoice_operator: 'TESTOP' };
  assert.deepEqual(validateCustomer(co, { kind: 'company' }), []);
  assert.deepEqual(keys(validateCustomer({}, { kind: 'company', invoiceMethod: 'pdf' })).slice(0, 5), ['company_name:reqCompanyName', 'business_id:reqBusinessId', 'street:reqStreet', 'zip:reqZip', 'city:reqCity']);
  assert.deepEqual(keys(validateCustomer({ ...co, business_id: '1234567-2' }, { kind: 'company', invoiceMethod: 'pdf' })), ['business_id:invalidBusinessId']);
  assert.deepEqual(keys(validateCustomer({ ...co, zip: '1234' }, { kind: 'company' })), ['zip:invalidZip']);
  assert.deepEqual(keys(validateCustomer({ ...co, einvoice_address: '1234' }, { kind: 'company' })), ['einvoice_address:invalidOvt']);
  assert.deepEqual(keys(validateCustomer({ ...co, einvoice_address: '', einvoice_operator: '' }, { kind: 'company' })), ['einvoice_address:reqOvt', 'einvoice_operator:reqOperator']);
  assert.deepEqual(keys(validateCustomer({ ...co, einvoice_operator: 'x!' }, { kind: 'company' })), ['einvoice_operator:invalidOperator']);
  assert.deepEqual(validateCustomer({ ...co, einvoice_address: '', einvoice_operator: '' }, { kind: 'company', invoiceMethod: 'online' }), []);
  assert.deepEqual(validateCustomer({ ...co, business_id: '' }, { kind: 'private' }), [], 'yrityskenttiä ei tarkisteta yksityisasiakkaalta');
});

// Pieni DOM-valekäyttöliittymä: riittää createFormErrors-apurin tarkistamiseen ilman selainta.
function fakeDom() {
  let seq = 0;
  const mk = (tag, attrs = {}, kids = []) => {
    const n = { tag, attrs: { ...attrs }, children: [], parent: null, cls: new Set(String(attrs.class || '').split(' ').filter(Boolean)), listeners: {}, id: attrs.id || '', _order: ++seq, focused: false,
      getAttribute(k) { return this.attrs[k] ?? null; }, setAttribute(k, v) { this.attrs[k] = String(v); }, removeAttribute(k) { delete this.attrs[k]; },
      addEventListener(e, f) { (this.listeners[e] ||= []).push(f); }, removeEventListener(e, f) { this.listeners[e] = (this.listeners[e] || []).filter((x) => x !== f); },
      fire(e) { for (const f of this.listeners[e] || []) f({}); },
      append(...c) { for (const x of c) { x.parent = this; this.children.push(x); } }, prepend(...c) { for (const x of c) x.parent = this; this.children.unshift(...c); },
      remove() { if (this.parent) this.parent.children = this.parent.children.filter((x) => x !== this); this.parent = null; },
      closest(sel) { const want = sel.split(',').map((s) => s.trim().replace('.', '')); for (let x = this; x; x = x.parent) if (want.some((c) => x.cls.has(c))) return x; return null; },
      get parentElement() { return this.parent; }, classList: null, focus() { this.focused = true; }, scrollIntoView() {}, getBoundingClientRect() { return { top: 0, bottom: 10 }; },
      compareDocumentPosition(o) { return o._order > this._order ? 4 : 2; } };
    n.classList = { add: (c) => n.cls.add(c), remove: (c) => n.cls.delete(c), contains: (c) => n.cls.has(c) };
    n.append(...kids); return n;
  };
  const h = (tag, attrs, ...kids) => { const a = { ...(attrs || {}) }; const n = mk(tag, a, kids.flat()); if (a.onclick) n.addEventListener('click', a.onclick); if (a.text) n.text = a.text; return n; };
  return { h, mk };
}
const allNodes = (n, out = []) => { out.push(n); n.children.forEach((c) => allNodes(c, out)); return out; };

test('createFormErrors: kenttävirhe + aria + koonti lomakkeen alussa + fokus ensimmäiseen; korjaus poistaa virheen', () => {
  const { h, mk } = fakeDom();
  const fEmail = mk('div', { class: 'bk-field' }), fName = mk('div', { class: 'bk-field' });
  const name = mk('input', { id: 'name', 'aria-describedby': 'name-hint' }), email = mk('input', { id: 'email' });
  fName.append(name); fEmail.append(email);
  const form = mk('form'); form.append(fName, fEmail);
  const fe = createFormErrors(form, { h, title: 'Tarkista nämä tiedot', win: {} });
  // tarkoituksella käänteisessä järjestyksessä: koonnin pitää seurata lomakkeen kenttäjärjestystä
  const first = fe.show([{ el: email, msg: 'Tarkista sähköpostiosoite.', label: 'Sähköposti' }, { el: name, msg: 'Kirjoita nimi.', label: 'Nimi' }]);
  assert.equal(first, name); assert.ok(name.focused && !email.focused);
  assert.equal(name.getAttribute('aria-invalid'), 'true'); assert.equal(email.getAttribute('aria-invalid'), 'true');
  assert.equal(name.getAttribute('aria-describedby'), 'name-hint name-err');
  assert.equal(email.getAttribute('aria-describedby'), 'email-err');
  const errs = allNodes(form).filter((n) => n.attrs['data-testid'] === 'field-error');
  assert.deepEqual(errs.map((e) => [e.parent, e.id, e.text]), [[fName, 'name-err', 'Kirjoita nimi.'], [fEmail, 'email-err', 'Tarkista sähköpostiosoite.']]);
  assert.ok(fName.cls.has('bad'));
  assert.equal(form.children[0].attrs['data-testid'], 'error-summary', 'koonti on lomakkeen ensimmäinen lapsi');
  const links = allNodes(form.children[0]).filter((n) => n.tag === 'a');
  assert.deepEqual(links.map((a) => [a.attrs.href, a.text]), [['#name', 'Nimi: Kirjoita nimi.'], ['#email', 'Sähköposti: Tarkista sähköpostiosoite.']]);
  // korjaus
  name.fire('input');
  assert.equal(name.getAttribute('aria-invalid'), null); assert.equal(name.getAttribute('aria-describedby'), 'name-hint'); assert.ok(!fName.cls.has('bad'));
  assert.equal(allNodes(form).filter((n) => n.tag === 'a').length, 1);
  email.fire('input');
  assert.ok(!allNodes(form).some((n) => n.attrs['data-testid'] === 'error-summary'), 'koonti poistuu kun viimeinen virhe korjataan');
  assert.equal(email.getAttribute('aria-describedby'), null);
});

test('createFormErrors: uusi näyttö korvaa vanhat virheet eikä kasaa; inline-rivi ei lisää toista virhetekstiä', () => {
  const { h, mk } = fakeDom();
  const f = mk('div', { class: 'bk-field' }), sel = mk('select', { id: 'bk-rit-time', 'aria-describedby': 'bk-rit-err' }), a = mk('input', { id: 'a' });
  const fa = mk('div', { class: 'bk-field' }); fa.append(a);
  const form = mk('form'); f.append(sel); form.append(f, fa);
  const fe = createFormErrors(form, { h, title: 'T', win: {} });
  fe.show([{ el: a, msg: 'x' }]); fe.show([{ el: a, msg: 'y' }, { el: sel, msg: 'Valitse aika', inline: true }]);
  assert.equal(allNodes(form).filter((n) => n.attrs['data-testid'] === 'error-summary').length, 1);
  assert.equal(allNodes(form).filter((n) => n.attrs['data-testid'] === 'field-error').length, 1, 'vain kentän a virheteksti; valikolla on oma');
  assert.equal(sel.getAttribute('aria-describedby'), 'bk-rit-err');
  fe.clear();
  assert.equal(allNodes(form).filter((n) => n.attrs['data-testid']).length, 0); assert.equal(a.getAttribute('aria-invalid'), null);
});

test('labelText poistaa pakollisuusmerkin', () => {
  const doc = { querySelector: () => ({ textContent: 'Sähköposti *' }) };
  assert.equal(labelText({ id: 'email' }, doc), 'Sähköposti');
});

test('kaikki kaupan lomakkeet käyttävät samaa apuria (form-errors.js), ei yleisviestiä "Täytä kaikki pakolliset kentät"', () => {
  const files = { 'booking/shop/src/shop.js': /errorsFor\(form\)/, 'booking/shop/src/treatment-ui.js': /cf\.read\(form, msg, /, 'booking/shop/src/waitlist-ui.js': /createFormErrors\(form/,
    'booking/shop/src/training-signup.js': /createFormErrors\(form/, 'booking/shop/src/gift.js': /createFormErrors\(form/ };
  for (const [f, re] of Object.entries(files)) {
    const s = code(f);
    assert.match(s, re, f);
    assert.doesNotMatch(s, /errorBox\(t\.required\)/, `${f}: ei geneeristä virhettä`);
    assert.doesNotMatch(s, /errorBox\(t\.acceptTermsErr/, `${f}: ehdot-virhe kenttävirheenä`);
  }
});

test('y-tunnuskenttä: inputmode=text (iOS:n numeronäppäimistössä ei ole viivaa), postinumero numeric', () => {
  const s = code('booking/shop/src/shop.js');
  assert.match(s, /field\('business_id', t\.businessId, \{[^}]*inputmode: 'text'/);
  assert.doesNotMatch(s, /business_id[^\n]*inputmode: 'numeric'/);
  assert.match(s, /field\('zip', t\.zip, \{[^}]*inputmode: 'numeric'/);
});

test('pakolliset kentät on merkitty (* aria-hidden; required-määre säilyy), valinnainen viite ei', () => {
  const s = code('booking/shop/src/shop.js');
  assert.match(s, /const reqMark = \(\) => h\('span', \{ class: 'bk-req', 'aria-hidden': 'true'/);
  assert.match(s, /attrs\.required === false \? null : reqMark\(\)/);
  assert.match(s, /h\('label', \{ for: 'name' \}, nameText, reqMark\(\)\)/);
  assert.match(s, /text: t\.requiredNote/);
});

test('tekstit FI+EN: uudet avaimet sanakirjassa = tuontitiedosto 164 (ui.shop.*), ei täytettä', () => {
  const rows = JSON.parse(rd('content/site-texts.pending-import-164.json'));
  const names = ['errSummaryTitle', 'requiredNote', 'reqName', 'reqEmail', 'invalidEmail', 'reqPhone', 'invalidPhone', 'reqCompanyName', 'reqBusinessId', 'reqStreet', 'reqZip', 'reqCity', 'reqOvt', 'reqOperator', 'invalidOperator'];
  assert.equal(rows.length, names.length * 2);
  const snake = (s) => s.replace(/([a-z0-9])([A-Z])/g, '$1_$2').toLowerCase();
  for (const n of names) for (const lang of ['fi', 'en']) {
    const r = rows.find((x) => x.key === `ui.shop.${snake(n)}` && x.lang === lang);
    assert.ok(r, `${n} ${lang}`); assert.equal(r.text, T[lang][n]); assert.ok(r.text.length <= r.max_len); assert.ok(!/[<>]/.test(r.text));
  }
  assert.ok(!JSON.stringify(rows).includes('REDACTED'));
});

test('tyylit: virhekoonti ja kenttävirhe, kosketuskohde ≥ 44 px, ei sinistä', () => {
  const css = rd('booking/shop/src/shop.css'), i = css.indexOf('/* booking_ux2_kassa02');
  const part = css.slice(i, css.indexOf('/* booking_', i + 5));
  assert.match(part, /\.bk-fielderr\{/); assert.match(part, /\.bk-errsum\{[^}]*scroll-margin-top:84px/); assert.match(part, /\.bk-errsum-list a\{[^}]*min-height:44px/);
  assert.doesNotMatch(part, /blue|#00f|#1d6fd8/i);
});
