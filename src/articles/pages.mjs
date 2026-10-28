// Sisältöosion sivut (esirenderöidyt): listaus (+tagisivut, sivutus), artikkeli, vanhan slugin ohjaussivu, sitemap-rivit.
// Kaikki osoitteet lasketaan repon asetuksista (content/articles.json) + SITE_URL:sta; RPC:n palauttamia ulkoisia osoitteiden isäntiä ei käytetä
// (tietokannan site_base_url / articles_path_* voivat poiketa ympäristöstä toiseen), paitsi artikkelin oma canonical-ohitus.
import { e, href, abs, site, pageHref, isTest } from '../lib.mjs';
import * as R from '../render.mjs';
import { cfg, t, label, listPath, articlePath, tagPath, listPagePath, articleUrl, tagSlug, dateFmt, isoDay, LANGS } from './config.mjs';
import { renderMarkdown } from './markdown.mjs';

const other = (l) => (l === 'fi' ? 'en' : 'fi');
const siteName = (lang) => site.ui[lang].siteName;
const pageHrefs = (lang) => ({ home: pageHref('home', lang), list: href(listPath(lang)), book: pageHref('book', lang), sauna: pageHref('sauna', lang) });

// ---- kuvat ----
export function imgHtml(im, variants, { sizes = '100vw', eager = false } = {}) {
  const v = variants?.get(im.url);
  const attrs = `width="${im.width}" height="${im.height}" alt="${e(im.alt || '')}"${eager ? ' fetchpriority="high" decoding="async"' : ' loading="lazy" decoding="async"'}`;
  if (im.pair?.jpg && im.pair?.webp) {
    const jpg = href(`/img/articles/${im.pair.jpg}`);
    const webp = href(`/img/articles/${im.pair.webp}`);
    const webpParts = [];
    if (v?.widths?.length && im.width > 0) {
      for (const w of v.widths) if (w < im.width) webpParts.push(`${href(`/img/articles/${v.id}-${w}.webp`)} ${w}w`);
    }
    webpParts.push(webpParts.length ? `${webp} ${im.width}w` : webp);
    return `<picture><source type="image/webp" srcset="${webpParts.join(', ')}" sizes="${sizes}"><img src="${jpg}" ${attrs}></picture>`;
  }
  if (!v) return `<img src="${e(im.url)}" ${attrs}>`;
  const set = (ext) => v.widths.map((w) => `${href(`/img/articles/${v.id}-${w}.${ext}`)} ${w}w`).join(', ');
  const last = v.widths[v.widths.length - 1];
  return `<picture><source type="image/avif" srcset="${set('avif')}" sizes="${sizes}"><source type="image/webp" srcset="${set('webp')}" sizes="${sizes}"><img src="${href(`/img/articles/${v.id}-${last}.webp`)}" ${attrs}></picture>`;
}

// Paikallinen kuvapari (content/article-images): og:image ja Article.image osoittavat toimitettuun webp-tiedostoon.
function localArticleImage(im) {
  if (!im?.pair?.webp) return im;
  return { ...im, url: abs(`/img/articles/${im.pair.webp}`) };
}

/** Välikuva tekstin puoliväliin, ennen "Lue myös" / Usein kysyttyä / kirjoittajaa. */
function injectAtMiddle(html, fig) {
  const stop = html.search(/<p>Lue myös|<h2\b[^>]*\bid="usein-kysyttya"|<aside class="article-(?:author|cta)"/);
  const head = stop >= 0 ? html.slice(0, stop) : html;
  const tail = stop >= 0 ? html.slice(stop) : '';
  const blocks = [...head.matchAll(/<(p|h2|h3|ul|ol|blockquote|figure)\b[^>]*>[\s\S]*?<\/\1>/g)];
  if (blocks.length < 2) return fig + html;
  const b = blocks[Math.floor(blocks.length / 2) - 1];
  const at = b.index + b[0].length;
  return `${head.slice(0, at)}\n${fig}\n${head.slice(at)}${tail}`;
}

// ---- yhteiset palaset ----
const timeTag = (iso, lang) => `<time datetime="${e(iso)}">${e(dateFmt(iso, lang))}</time>`;
const crumbs = (lang, trail) => {
  const h = pageHrefs(lang);
  const items = [[t(lang, 'home'), h.home], [label(lang), trail.length ? h.list : null], ...trail];
  return `<nav class="crumbs" aria-label="${e(t(lang, 'breadcrumb'))}"><ol>${items.map(([n, u], i) => (u ? `<li><a href="${e(u)}">${e(n)}</a></li>` : `<li aria-current="page">${e(n)}</li>`)).join('')}</ol></nav>`;
};
const band = (inner, cls = '') => `<section class="art-band${cls ? ' ' + cls : ''}"><div class="wrap">${inner}</div></section>`;
const defaultCta = (lang) => `<aside class="article-cta"><p class="cta-title">${e(t(lang, 'ctaTitle'))}</p><p>${e(t(lang, 'ctaText'))}</p><p><a class="btn gold" href="${e(pageHref('book', lang))}">${e(t(lang, 'ctaButton'))}</a></p></aside>`;

function card(it, lang, variants) {
  const c = it.card, im = c.image;
  const meta = [c.category && `<li>${e(c.category)}</li>`, c.published_at && `<li>${timeTag(c.published_at, lang)}</li>`, c.reading_minutes && `<li>${e(t(lang, 'readMin', { n: Math.max(1, c.reading_minutes) }))}</li>`].filter(Boolean).join('');
  return `<li class="card art-card"><div class="im">${im ? imgHtml({ ...im, alt: '' }, variants, { sizes: '(min-width:1100px) 380px, (min-width:640px) 45vw, 100vw' }) : ''}</div>
<div class="bd"><h2><a href="${e(href(articlePath(lang, c.slug)))}">${e(c.title)}</a></h2><p>${e(c.summary)}</p>${meta ? `<ul class="meta">${meta}</ul>` : ''}</div>
<div class="cta" aria-hidden="true">${e(t(lang, 'readArticle'))} →</div></li>`;
}

// ---- etusivun osio (Saunatietoa: uusimmat artikkelit) ----
/** Etusivulle valittavat artikkelit: uusin julkaisu ensin (published_at), ei noindex-artikkeleita (ei nosteta etusivulle), enintään cfg.home.limit. */
export function pickHomeItems(items, limit = cfg.home?.limit ?? 3) {
  return items.filter((it) => it?.card?.slug && it.card.title && !it.card.noindex)
    .map((it, i) => ({ it, i, ts: Date.parse(it.card.published_at) || 0 }))
    .sort((a, b) => b.ts - a.ts || a.i - b.i).slice(0, limit).map((o) => o.it);
}
const homeCard = (it, lang, variants, n, linkFor) => {
  const c = it.card, im = c.image?.url && variants?.has(c.image.url) ? c.image : null;   // vain jos pieni versio (srcset) on valmistettu: alkuperäistä (jopa 5 Mt) ei ladata pieneen korttiin
  const date = c.published_at && dateFmt(c.published_at, lang) ? `<ul class="meta"><li>${timeTag(c.published_at, lang)}</li></ul>` : '';
  // Kuva on koristeellinen (alt=""): kortin linkin nimi on otsikko. Pieni versio: srcset 480/800 w, sizes ~ kortin leveys.
  const img = im ? `<div class="im">${imgHtml({ ...im, alt: '' }, variants, { sizes: '(min-width:760px) 380px, 100vw' })}</div>` : '';
  return `<li class="card hart${im ? '' : ' noimg'}">${img}<div class="bd"><h3><a href="${e(linkFor(lang, c.slug))}">${e(c.title)}</a></h3>${c.summary ? `<p>${e(c.summary)}</p>` : ''}${date}</div><div class="cta" aria-hidden="true">${e(t(lang, 'readMore'))}</div></li>`;
};
/** Etusivun osio (<section>) tai '' kun ei ole artikkeleita. linkFor(lang, slug) → href (esikatselussa korvataan). */
export function homeSectionHtml(items, lang, variants, { linkFor = (l, slug) => href(articlePath(l, slug)) } = {}) {
  const pick = pickHomeItems(items);
  if (!pick.length) return '';
  const title = label(lang), hid = `home-art-${lang}`;
  return `<section class="section home-art" id="saunatietoa" aria-labelledby="${hid}"><div class="wrap"><div class="week-head"><header><h2 class="sec-title" id="${hid}">${e(title)}</h2></header><a class="btn light sm more-all" href="${e(href(listPath(lang)))}">${e(t(lang, 'homeAll'))}</a></div>`
    + `<ul class="cards hart-list">${pick.map((it, n) => homeCard(it, lang, variants, n, linkFor)).join('')}</ul></div></section>`;
}

// ---- tagit ----
function tagIndex(items) {
  const m = new Map();   // slug → {label, items}
  for (const it of items) {
    for (const lab of new Set([...(it.card.tags || []), ...(it.card.category ? [it.card.category.toLowerCase()] : [])])) {
      const s = tagSlug(lab);
      if (!m.has(s)) m.set(s, { slug: s, label: lab, items: [] });
      const g = m.get(s); if (!g.items.includes(it)) g.items.push(it);
    }
  }
  return m;
}

// ---- listaus / tagisivu ----
function listingPages({ lang, items, tags, tag, variants, hasOther }) {
  const size = cfg.pageSize, total = Math.max(1, Math.ceil(items.length / size));
  const pathOf = (p) => (tag ? tagPath(lang, tag.slug, p) : listPagePath(lang, p));
  const out = [];
  for (let p = 1; p <= total; p++) {
    const chunk = items.slice((p - 1) * size, p * size);
    const title0 = tag ? t(lang, 'tagTitle', { tag: tag.label }) : label(lang);
    const h1 = tag ? title0 : label(lang);
    const lead = tag ? t(lang, 'tagDescription', { tag: tag.label }) : t(lang, 'listLead');
    const tagbar = tags.length ? `<nav class="tagbar" aria-label="${e(t(lang, 'tagsLabel'))}"><ul><li><a href="${e(href(listPath(lang)))}"${!tag ? ' aria-current="page"' : ''}>${e(t(lang, 'allTags'))}</a></li>${tags.map((g) => `<li><a href="${e(href(tagPath(lang, g.slug)))}"${tag?.slug === g.slug ? ' aria-current="page"' : ''}>${e(g.label)}</a></li>`).join('')}</ul></nav>` : '';
    const pager = total > 1 ? `<nav class="pager" aria-label="${e(t(lang, 'pagination'))}">${p > 1 ? `<a rel="prev" href="${e(href(pathOf(p - 1)))}">${e(t(lang, 'prev'))}</a>` : '<span></span>'}<span class="pg" aria-current="page">${e(t(lang, 'page', { n: p }))} / ${total}</span>${p < total ? `<a rel="next" href="${e(href(pathOf(p + 1)))}">${e(t(lang, 'next'))}</a>` : '<span></span>'}</nav>` : '';
    const empty = `<div class="art-empty"><p>${e(t(lang, 'empty'))}</p><p><a class="btn light" href="${e(pageHref('sauna', lang))}">${e(t(lang, 'emptyLink'))}</a></p></div>`;
    const body = band(`${crumbs(lang, tag ? [[title0, null]] : [])}<p class="kicker">${e(t(lang, 'kicker'))}</p><h1>${e(h1)}</h1><p class="lead">${e(lead)}</p>`, 'list')
      + `<section class="section art-list"><div class="wrap">${tagbar}${chunk.length ? `<ul class="cards art-cards">${chunk.map((it) => card(it, lang, variants)).join('')}</ul>` : empty}${pager}</div></section>`;
    const url = abs(pathOf(p));
    const noindex = !items.length || !!tag;   // tyhjä listaus ja tagisivut: noindex,follow
    const title = [tag ? t(lang, 'tagTitle', { tag: tag.label }) : t(lang, 'listMeta', { label: label(lang) }), p > 1 ? t(lang, 'page', { n: p }) : null].filter(Boolean).join(', ');
    const meta = { title: `${title} | ${siteName(lang)}`, description: tag ? t(lang, 'tagDescription', { tag: tag.label }) : t(lang, 'listDescription'), og: 'hero-ovi-uusi' };
    const hreflangs = !tag && p === 1 && hasOther && items.length ? [...LANGS.map((l) => ({ hreflang: l, href: abs(listPagePath(l, 1)) })), { hreflang: 'x-default', href: abs(listPagePath('fi', 1)) }] : [];
    const html = R.layout({ lang, key: null, meta, body, seo: { url, hreflangs, robots: noindex ? 'noindex,follow' : 'index,follow', extraCss: R.articlesCss, navCurrent: 'articles', switchHref: hasOther ? href(listPath(other(lang))) : pageHref('home', other(lang)) } });
    out.push({ path: pathOf(p), html, kind: tag ? 'tag' : 'list', lang, indexable: !noindex && p === 1, page: p });
  }
  return out;
}

// ---- artikkeli ----
const ldBreadcrumb = (lang, a, url) => ({ '@context': 'https://schema.org', '@type': 'BreadcrumbList', itemListElement: [[t(lang, 'home'), abs(site.pages.home[lang])], [label(lang), abs(listPath(lang))], [a.title, url]].map(([name, item], i) => ({ '@type': 'ListItem', position: i + 1, name, item })) });

function articlePage(it, ctx) {
  const { lang, slug, article: a, seo } = it, { variants, data, live } = ctx;
  const own = articleUrl(lang, slug);
  let canonical = seo.canonical || own;
  try { const p = new URL(canonical).pathname; if (p.endsWith(articlePath(lang, slug)) || p.endsWith(`${data.lang[lang].dbPath ?? ''}${slug}/`)) canonical = own; } catch { canonical = own; }
  const isOwn = canonical === own;

  // hreflang: vain kun molemmat kieliversiot ovat sivustolla; itseviittaus + x-default (=fi). Canonical-ohituksella ei hreflangeja.
  const alts = Object.fromEntries((a.alternates || []).filter((x) => live[x.lang]?.has(x.slug)).map((x) => [x.lang, x.slug]));
  const both = LANGS.every((l) => alts[l]);
  const hreflangs = isOwn && both ? [...LANGS.map((l) => ({ hreflang: l, href: articleUrl(l, alts[l]) })), { hreflang: 'x-default', href: articleUrl('fi', alts.fi) }] : [];

  const imgs = new Map((a.images || []).map((i) => [i.id, i]));
  const hero = a.image || seo.og_image;
  const md = renderMarkdown(a.content_md, {
    images: imgs, resolveHref: href,
    imageHtml: (im) => `<figure class="art-fig">${imgHtml(im, variants, { sizes: '(min-width:800px) 720px, 100vw' })}${im.caption ? `<figcaption>${e(im.caption)}</figcaption>` : ''}</figure>`,
  });
  if (it.localInline) {
    const fig = `<figure class="art-fig">${imgHtml(it.localInline, variants, { sizes: '(min-width:800px) 720px, 100vw' })}</figure>`;
    md.html = injectAtMiddle(md.html, fig);
  }
  for (const w of md.warnings) ctx.warn(`${lang}/${slug}: ${w}`);

  // JSON-LD: tietokannan Article sellaisenaan, URL:t korjattu tämän ympäristön osoitteiksi
  const ld = structuredClone(seo.json_ld || {});
  ld['@context'] ||= 'https://schema.org'; ld['@type'] ||= 'Article';
  ld.mainEntityOfPage = { '@type': 'WebPage', '@id': canonical };
  ld.url = canonical;
  ld.inLanguage ||= lang;
  ld.headline ||= a.title; ld.description ||= seo.description;
  ld.datePublished ||= a.published_at; ld.dateModified ||= a.updated_at || a.published_at;
  ld.publisher = { ...(ld.publisher || { '@type': 'Organization', name: siteName(lang) }), url: abs('/') };
  if (!ld.author) ld.author = { '@type': 'Organization', name: siteName(lang) };
  if (a.author === 'Otto Kronqvist') {
    ld.author = { '@type': 'Person', name: 'Otto Kronqvist' };
    ld.publisher = { ...ld.publisher, '@type': 'Organization', name: 'Sipoonjoen perinnesauna' };
  }
  const ogBase = seo.og_image || hero;
  const ogShown = localArticleImage(ogBase);
  if (ogShown?.url && ogShown !== ogBase) ld.image = [ogShown.url];
  else if (!ld.image?.length && ogBase?.url) ld.image = [ogBase.url];

  const tags = (a.tags || []).map((x) => ({ slug: tagSlug(x), label: x }));
  const related = ctx.related(it);
  const show = a.updated_at && isoDay(a.updated_at) > isoDay(a.published_at);
  const metaLine = [
    a.author && `<li><span class="sr">${e(t(lang, 'by'))}: </span>${e(a.author)}</li>`,
    `<li><span class="sr">${e(t(lang, 'published'))}: </span>${timeTag(a.published_at, lang)}</li>`,
    show && `<li>${e(t(lang, 'updated'))} ${timeTag(a.updated_at, lang)}</li>`,
    a.reading_minutes && `<li>${e(t(lang, 'readMin', { n: Math.max(1, a.reading_minutes) }))}</li>`,
  ].filter(Boolean).join('');
  const otherSlug = alts[other(lang)];
  const mailto = `mailto:?subject=${encodeURIComponent(t(lang, 'shareSubject', { title: a.title }))}&body=${encodeURIComponent(canonical)}`;
  const body = band(`${crumbs(lang, [[a.title, null]])}${a.category ? `<p class="kicker"><a href="${e(href(tagPath(lang, tagSlug(a.category))))}">${e(a.category)}</a></p>` : ''}<h1>${e(a.title)}</h1><p class="lead">${e(a.summary)}</p><ul class="art-meta">${metaLine}</ul>`)
    + `<div class="wrap art-wrap">${hero?.url ? `<figure class="art-hero">${imgHtml({ ...hero, alt: hero.alt || '' }, variants, { sizes: '(min-width:1000px) 960px, 100vw', eager: true })}${hero.caption ? `<figcaption>${e(hero.caption)}</figcaption>` : ''}</figure>` : ''}`
    + `<article class="art-body">${md.html}${md.ctaCount ? '' : defaultCta(lang)}</article>`
    + `<footer class="art-foot">${tags.length ? `<nav aria-label="${e(t(lang, 'tags'))}"><p class="lbl">${e(t(lang, 'tags'))}</p><ul class="tagbar">${tags.map((g) => `<li><a href="${e(href(tagPath(lang, g.slug)))}">${e(g.label)}</a></li>`).join('')}</ul></nav>` : ''}`
    + `<p class="lbl">${e(t(lang, 'share'))}</p><ul class="tagbar"><li><a href="${e(mailto)}">${e(t(lang, 'shareMail'))}</a></li>${otherSlug ? `<li><a href="${e(href(articlePath(other(lang), otherSlug)))}" hreflang="${other(lang)}" lang="${other(lang)}">${e(t(lang, 'otherLang'))}</a></li>` : ''}<li><a href="${e(href(listPath(lang)))}">${e(t(lang, 'back'))}</a></li></ul></footer></div>`
    + (related.length ? `<section class="section tint art-related" aria-labelledby="rel-h"><div class="wrap"><h2 class="sec-title" id="rel-h">${e(t(lang, 'related'))}</h2><ul class="cards art-cards">${related.map((r) => card(r, lang, variants)).join('')}</ul></div></section>` : '');

  const ogExtra = `<meta property="article:published_time" content="${e(a.published_at)}"><meta property="article:modified_time" content="${e(a.updated_at || a.published_at)}">${a.category ? `<meta property="article:section" content="${e(a.category)}">` : ''}${(a.tags || []).map((x) => `<meta property="article:tag" content="${e(x)}">`).join('')}`;
  const og = ogShown?.url ? ogShown : ogBase;
  const jsonLd = [ld, ldBreadcrumb(lang, a, canonical)];
  if (md.faqs.length) jsonLd.push({ '@context': 'https://schema.org', '@type': 'FAQPage', '@id': `${canonical}#usein-kysyttya`, mainEntity: md.faqs.map((f) => ({ '@type': 'Question', name: f.question, acceptedAnswer: { '@type': 'Answer', text: f.answer } })) });
  const html = R.layout({
    lang, key: null, meta: { title: seo.title || a.title, description: seo.description || a.summary }, body,
    seo: {
      url: canonical, hreflangs, robots: seo.robots || (a.noindex ? 'noindex,follow' : 'index,follow'), ogType: seo.og_type || 'article',
      ogImage: og?.url ? { url: og.url, width: og.width, height: og.height, alt: og.alt } : null, ogExtra, extraCss: R.articlesCss, navCurrent: 'articles',
      jsonLd,
      switchHref: otherSlug ? href(articlePath(other(lang), otherSlug)) : (ctx.hasList[other(lang)] ? href(listPath(other(lang))) : pageHref('home', other(lang))),
    },
  });
  return { path: articlePath(lang, slug), html, kind: 'article', lang, slug, indexable: isOwn && !a.noindex, alts, canonical };
}

/** Ohjaussivu (staattinen 301-vastine): meta refresh + canonical kohteeseen + näkyvä linkki. fromPath/toPath ilman BASE-etuliitettä. */
function redirectTo({ lang, fromPath, toPath, label }) {
  const target = abs(toPath);
  const body = `<section class="section"><div class="wrap narrow center"><h1 class="sec-title">${e(t(lang, 'movedTitle'))}</h1><p>${e(t(lang, 'movedText'))}</p><p><a class="btn" href="${e(href(toPath))}">${e(t(lang, 'movedLink'))}</a></p></div></section>`;
  const html = R.layout({
    lang, key: null, meta: { title: `${t(lang, 'movedTitle')}: ${label} | ${siteName(lang)}`, description: t(lang, 'movedText') }, body,
    seo: { url: target, hreflangs: [], extraHead: `<meta http-equiv="refresh" content="0; url=${e(href(toPath))}">`, robots: null, extraCss: R.articlesCss, navCurrent: 'articles', switchHref: href(listPath(other(lang))) },
  });
  return { path: fromPath, html, kind: 'redirect', lang, to: toPath };
}
const redirectPage = (r) => redirectTo({ lang: r.lang, fromPath: articlePath(r.lang, r.from), toPath: articlePath(r.toLang, r.toSlug), label: r.from });

/**
 * Rakentaa kaikki sisältöosion sivut ja sitemap-rivit.
 * @returns {{pages:{path:string,html:string,kind:string}[], sitemap:{loc:string,lastmod:string,alternates:{hreflang:string,href:string}[]}[], counts:Record<string,number>, warnings:string[]}}
 */
export function buildArticleSite(data, variants) {
  const warnings = [];
  const warn = (m) => { warnings.push(m); console.warn(`articles: VAROITUS: ${m}`); };
  // tietokannan asetukset vs. repon asetukset
  for (const L of LANGS) {
    const d = data.lang[L];
    if (d.dbPath && d.dbPath !== cfg.path[L]) warn(`tietokannan articles_path_${L} (${d.dbPath}) poikkeaa repon asetuksesta (${cfg.path[L]}); käytetään repon arvoa. Päivitä booking.settings, jotta RPC:n palauttamat polut täsmäävät.`);
    if (d.dbLabel && d.dbLabel !== cfg.label[L]) warn(`tietokannan articles_label_${L} ("${d.dbLabel}") poikkeaa repon asetuksesta ("${cfg.label[L]}"); käytetään repon arvoa.`);
  }
  const live = Object.fromEntries(LANGS.map((L) => [L, new Set(data.lang[L].items.map((x) => x.slug))]));
  const hasList = Object.fromEntries(LANGS.map((L) => [L, data.lang[L].items.length > 0]));
  const hasOther = hasList.fi && hasList.en;
  const pages = [], sitemap = [];

  const ctx = {
    variants, data, live, hasList, warn,
    related: (it) => {
      const mine = new Set([...(it.card.tags || []), it.card.category].filter(Boolean));
      return data.lang[it.lang].items.filter((x) => x !== it)
        .map((x, i) => ({ x, i, s: [...(x.card.tags || []), x.card.category].filter((k) => mine.has(k)).length }))
        .sort((p, q) => q.s - p.s || p.i - q.i).slice(0, cfg.relatedCount).map((o) => o.x);
    },
  };

  for (const L of LANGS) {
    const items = data.lang[L].items;
    const tagMap = tagIndex(items);
    const tags = [...tagMap.values()].sort((a, b) => b.items.length - a.items.length || a.label.localeCompare(b.label, L));
    pages.push(...listingPages({ lang: L, items, tags, tag: null, variants, hasOther }));
    for (const g of tags) pages.push(...listingPages({ lang: L, items: g.items, tags, tag: g, variants, hasOther }));
    for (const it of items) pages.push(articlePage(it, ctx));
  }

  // uudelleenohjaukset (vanhat slugit)
  const taken = new Set(pages.map((p) => p.path));
  for (const r of data.redirects || []) {
    if (!live[r.toLang]?.has(r.toSlug)) { warn(`ohjaus ${r.lang}/${r.from} → ${r.toLang}/${r.toSlug}: kohdeartikkeli ei ole julkaistu; ohjaussivua ei luoda (404)`); continue; }
    const p = redirectPage(r);
    if (taken.has(p.path)) { warn(`ohjaus ${p.path}: osoitteessa on jo sivu; ohitetaan`); continue; }
    taken.add(p.path); pages.push(p);
  }

  // vanhat osion polut (cfg.legacyPaths, esim. /en/sauna-guide/): listaus ja jokainen julkaistu artikkeli (+ vanhat slugit suoraan nykyiseen) ohjataan nykyiseen osoitteeseen
  for (const L of LANGS) for (const base of cfg.legacyPaths?.[L] || []) {
    if (base === cfg.path[L]) continue;
    const add = (fromPath, toPath, label) => { if (taken.has(fromPath)) return; taken.add(fromPath); pages.push(redirectTo({ lang: L, fromPath, toPath, label })); };
    add(base, listPath(L), base);
    for (const slug of live[L]) add(`${base}${slug}/`, articlePath(L, slug), slug);
    for (const r of data.redirects || []) if (r.lang === L && r.toLang === L && live[L].has(r.toSlug)) add(`${base}${r.from}/`, articlePath(L, r.toSlug), r.from);
  }

  // sitemap: artikkelit RPC:n public_articles_sitemap-listan mukaan (vain indeksoitavat), listaukset kun niillä on artikkeleita
  const byKey = new Map(pages.filter((p) => p.kind === 'article').map((p) => [`${p.lang}/${p.slug}`, p]));
  for (const s of data.sitemap || []) {
    const p = byKey.get(`${s.lang}/${s.slug}`);
    if (!p) { warn(`sitemap-rivi ${s.lang}/${s.slug}: artikkelisivua ei ole; ohitetaan`); continue; }
    if (!p.indexable) continue;
    const both = LANGS.every((l) => p.alts[l]);
    sitemap.push({ loc: abs(p.path), lastmod: isoDay(s.updated_at || s.published_at), alternates: both ? [...LANGS.map((l) => ({ hreflang: l, href: articleUrl(l, p.alts[l]) })), { hreflang: 'x-default', href: articleUrl('fi', p.alts.fi) }] : [] });
  }
  for (const L of LANGS) {
    if (!hasList[L]) continue;
    const last = data.lang[L].items.map((x) => x.card.updated_at || x.card.published_at).sort().pop();
    sitemap.unshift({ loc: abs(listPagePath(L, 1)), lastmod: isoDay(last), alternates: hasOther ? [...LANGS.map((l) => ({ hreflang: l, href: abs(listPagePath(l, 1)) })), { hreflang: 'x-default', href: abs(listPagePath('fi', 1)) }] : [] });
  }
  const counts = { fi: data.lang.fi.items.length, en: data.lang.en.items.length, redirects: pages.filter((p) => p.kind === 'redirect').length, pages: pages.length };
  return { pages, sitemap, counts, warnings };
}
