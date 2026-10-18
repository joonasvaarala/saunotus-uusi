// Markdown-osajoukon renderöijä (sopimus §16.2): sallittu syntaksi, XSS-esimerkit, img:-viitteet, :::cta
import test from 'node:test';
import assert from 'node:assert/strict';
import { renderMarkdown, inline, isSafeHref } from '../../src/articles/markdown.mjs';

const r = (md, o = {}) => renderMarkdown(md, { resolveHref: (u) => '/base' + u, ...o });

test('otsikot: ## ja ### sellaisenaan, # muuttuu H2:ksi, #### tulostuu tekstinä', () => {
  const { html, headings } = r('# Yksi\n\n## Kaksi\n\n### Kolme\n\n#### Neljä');
  assert.match(html, /<h2 id="yksi">Yksi<\/h2>/);
  assert.match(html, /<h2 id="kaksi">Kaksi<\/h2>/);
  assert.match(html, /<h3 id="kolme">Kolme<\/h3>/);
  assert.doesNotMatch(html, /<h4/);
  assert.match(html, /<p>#### Neljä<\/p>/);
  assert.deepEqual(headings.map((h) => h.level), [2, 2, 3]);
});
test('otsikoiden ankkurit ovat yksilöllisiä ja ASCII', () => {
  const { html } = r('## Löyly ja lepo\n\n## Löyly ja lepo');
  assert.match(html, /id="loyly-ja-lepo"/);
  assert.match(html, /id="loyly-ja-lepo-2"/);
});
test('kappaleet, rivinvaihto <br>, lihavointi ja kursivointi', () => {
  const { html } = r('**Kysymys?**\nVastaus *tässä*.\n\nToinen kappale');
  assert.equal(html, '<p><strong>Kysymys?</strong><br>Vastaus <em>tässä</em>.</p>\n<p>Toinen kappale</p>');
});
test('luettelot, lainaus ja vaakaviiva', () => {
  const { html } = r('- a\n- b\n\n1. yksi\n2. kaksi\n\n> lainaus\n> toinen rivi\n\n---');
  assert.match(html, /<ul><li>a<\/li><li>b<\/li><\/ul>/);
  assert.match(html, /<ol><li>yksi<\/li><li>kaksi<\/li><\/ol>/);
  assert.match(html, /<blockquote><p>lainaus<br>toinen rivi<\/p><\/blockquote>/);
  assert.match(html, /<hr>/);
});
test('linkit: ulkoinen rel=noopener ilman nofollow, sisäinen saa BASE-etuliitteen, ankkuri ja mailto sellaisenaan', () => {
  const { html } = r('[a](https://example.com/x?a=1&b=2) [b](/varaa/) [c](#osio) [d](mailto:a@b.fi)');
  assert.match(html, /<a href="https:\/\/example\.com\/x\?a=1&amp;b=2" rel="noopener">a<\/a>/);
  assert.doesNotMatch(html, /nofollow/);
  assert.match(html, /<a href="\/base\/varaa\/">b<\/a>/);
  assert.match(html, /<a href="#osio">c<\/a>/);
  assert.match(html, /<a href="mailto:a@b\.fi">d<\/a>/);
});

// ---- XSS ----
const BAD = [
  '<script>alert(1)</script>', '<img src=x onerror=alert(1)>', '<b onclick="x()">t</b>', '</p><iframe src="//e"></iframe>',
  '[x](javascript:alert(1))', '[x](JaVaScRiPt:alert(1))', '[x](data:text/html;base64,PHNjcmlwdD4=)', '[x](file:///etc/passwd)', '[x](vbscript:x)',
  '[x](//evil.example/x)', '[x]( javascript:alert(1))', '![x](https://evil.example/p.png)', '![x](javascript:alert(1))',
];
test('XSS-esimerkit: mikään ei tuota aktiivista HTML:ää tai vaarallista osoitetta', () => {
  for (const bad of BAD) {
    const { html } = r(`Teksti ${bad} loppu\n\n${bad}`);
    assert.doesNotMatch(html, /<script|<iframe|<img|<[^>]*\son\w+=|href="\s*javascript:|href="\s*data:|href="file:|href="\/\/|src="https?:\/\/evil/i, `vuoto: ${bad}\n${html}`);
    assert.doesNotMatch(html.replace(/<\/?(p|br|strong|em|a|h2|h3|ul|ol|li|blockquote|hr)\b[^>]*>/g, ''), /</, `ylimääräisiä tageja: ${bad}\n${html}`);
  }
});
test('lainausmerkki tai hakasulku osoitteessa ei riko attribuuttia', () => {
  const { html } = r('[x](https://a.fi/"onmouseover="alert(1))');
  assert.doesNotMatch(html, /onmouseover="alert/);
  assert.match(html, /&quot;/);
});
test('isSafeHref hylkää protokollattoman // ja vaaralliset skeemat', () => {
  for (const u of ['https://a.fi', 'http://a.fi', 'mailto:a@b.fi', '/polku/', '#a']) assert.equal(isSafeHref(u), true, u);
  for (const u of ['//a.fi', 'javascript:x', 'data:x', 'ftp://a.fi', 'tel:123', 'img:4', 'a.fi']) assert.equal(isSafeHref(u), false, u);
});
test('alt-tekstin HTML ei pääse läpi kuvalohkossa (alt tulee tietokannasta ja escapataan)', () => {
  const images = new Map([[7, { id: 7, url: 'https://s/x.jpg', alt: 'a"><script>x</script>', width: 10, height: 10 }]]);
  const { html } = r('![jotain](img:7)', { images, imageHtml: (im) => `<figure><img src="${im.url}" alt="${inline(im.alt)}"></figure>` });
  assert.doesNotMatch(html, /<script/);
});

// ---- kuvat ----
test('img:ID omalla rivillään → imageHtml; tuntematon id jää pois varoituksella', () => {
  const images = new Map([[42, { id: 42, url: 'u', alt: 'A', width: 1, height: 1 }]]);
  const out = r('Alku\n\n![x](img:42)\n\n![y](img:99)\n\nLoppu', { images, imageHtml: (im) => `<figure data-id="${im.id}"></figure>` });
  assert.match(out.html, /<figure data-id="42"><\/figure>/);
  assert.doesNotMatch(out.html, /99/);
  assert.deepEqual(out.warnings, ['img:99 puuttuu artikkelin kuvista']);
});
test('kuva rivin keskellä tai ulkoinen kuva tulostuu tekstinä (ei img-elementtiä)', () => {
  const { html } = r('Teksti ![x](img:1) jatkuu');
  assert.doesNotMatch(html, /<img|<figure/);
  assert.match(html, /!\[x\]\(img:1\)/);
});

// ---- CTA ----
test(':::cta → aside.article-cta, otsikko, teksti ja painikelinkki', () => {
  const { html, ctaCount } = r('Alku\n\n:::cta\n**Varaa oma saunahetkesi**\nValitse aika ja varaa.\n[Varaa aika](/varaa/)\n:::\n\nLoppu');
  assert.equal(ctaCount, 1);
  assert.match(html, /<aside class="article-cta"><p class="cta-title">Varaa oma saunahetkesi<\/p><p>Valitse aika ja varaa\.<\/p><p><a class="btn gold" href="\/base\/varaa\/">Varaa aika<\/a><\/p><\/aside>/);
  assert.match(html, /<p>Loppu<\/p>/);
});
test('CTA: vaarallinen linkki ei muutu painikkeeksi; sulkematon :::cta on tavallista tekstiä', () => {
  const a = r(':::cta\n**T**\n[x](javascript:alert(1))\n:::');
  assert.doesNotMatch(a.html, /class="btn/);
  assert.doesNotMatch(a.html, /href="javascript/);
  const b = r(':::cta\n**T**\nteksti');
  assert.equal(b.ctaCount, 0);
  assert.match(b.html, /:::cta/);
});
test('CTA: HTML escapataan lohkon sisällä', () => {
  const { html } = r(':::cta\n**<b>x</b>**\n<i>y</i>\n[a](https://e.fi)\n:::');
  assert.doesNotMatch(html, /<b>|<i>/);
});
