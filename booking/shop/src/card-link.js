// Tuotekortti on yksi linkki. Kuvauksen sisäiset linkit puretaan, jotta kortissa ei ole sisäkkäisiä linkkejä.
export function cardAnchor(h, href, ...kids) {
  const a = h('a', { class: 'bk-card-link', href }, ...kids);
  if (typeof a.querySelectorAll !== 'function') return a;
  const doc = a.ownerDocument;
  if (!doc?.createElement) return a;
  for (const n of [...a.querySelectorAll('a')]) {
    if (n === a) continue;
    const span = doc.createElement('span');
    while (n.firstChild) span.append(n.firstChild);
    n.replaceWith(span);
  }
  return a;
}
