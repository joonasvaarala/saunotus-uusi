// Ehto-/tietosuojatekstin kieliversio (kb.policies title/body, EN: title_en/body_en).
// EN-tietosuojasivu (/en/privacy/) julkaistaan vain, kun kaikilla sivun kohdilla on title_en JA body_en.
// Muuten sivua ei rakenneta, sitemap/hreflang/kielivalitsin eivät viittaa siihen ja alatunnisteen linkki osoittaa suomenkieliseen sivuun.
export function policyText(p, lang) {
  if (!p) return null;
  if (lang === 'en') return p.title_en && p.body_en ? { title: p.title_en, body: p.body_en } : null;
  return { title: p.title, body: p.body };
}

export function policiesReady(policies, ids, lang) {
  if (!Array.isArray(ids) || !ids.length) return false;
  return ids.every((id) => { const p = (policies || []).find((x) => x.id === id); return !!p && !p.internal && !!policyText(p, lang); });
}

// Palauttaa site.pages-olion, jossa privacy.en = null, jos EN-tekstit puuttuvat (alkuperäistä ei muuteta).
export function resolvePrivacyPages(pages, policies, enIds) {
  if (!pages?.privacy?.en || policiesReady(policies, enIds, 'en')) return pages;
  return { ...pages, privacy: { ...pages.privacy, en: null } };
}

// EN-sivun meta/hero johdetaan kb:n EN-tekstistä + FI-sivun kuvista (ei uusia kovakoodattuja tekstejä eikä tekstiavaimia):
// otsikko = title_en (+ FI-otsikon " | <nimi>"-pääte), kuvaus = body_en:n ensimmäinen rivi (≤ 160 merkkiä).
export function privacyDocFor(fiDoc, policies, lang) {
  if (lang !== 'en') return fiDoc;
  const first = policyText((policies || []).find((p) => p.id === fiDoc.policies[0]), 'en');
  if (!first) return null;
  const suffix = String(fiDoc.meta.title).split(' | ').slice(1).join(' | ');
  const line = String(first.body).split(/\n+/).map((s) => s.trim()).find(Boolean) || first.title;
  return {
    meta: { title: suffix ? `${first.title} | ${suffix}` : first.title, description: line.length > 160 ? `${line.slice(0, 157).trimEnd()}…` : line, og: fiDoc.meta.og },
    hero: { title: first.title, text: '', img: fiDoc.hero.img },
    policies: fiDoc.policies,
  };
}
