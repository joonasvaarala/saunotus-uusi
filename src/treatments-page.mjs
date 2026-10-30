// Hoidot ja rituaalit -sivu. Tuotekortti on sama rakenne kuin kaupan listalla
// (booking/shop/src/shop.js + treatment-ui.js): kuva, nimi, lyhyt kuvaus, kesto, hinta, painike.
// Hinta, kesto, slug ja savusauna-lippu tulevat tuotteesta (liveProduct = public_catalog tai kb).
// Uudet tekstit: ui.site.treatments_* (content/site-texts.pending-import-95.json) ja yhdistelmäkortti
// ui.site.care_pair_* (content/site-texts.pending-import-107.json); puuttuu kannasta → tämä varateksti.
import { tx } from './site-texts.mjs';
import { alts, cards, pageDoc } from './content-texts.mjs';
import { site, e, pageHref, money, picture, icon } from './lib.mjs';
import { liveProduct } from './catalog-live.mjs';
import { productCardInner } from './product-card-image.mjs';
import { SIZES } from '../booking/shop/src/product-image.js';
import { shopHash } from './event-cards.mjs';
import { shortRaw, derivedExcerpt } from '../booking/shop/src/short-desc.js';
import { visibleText } from '../booking/shop/src/rich-view.js';
import { keepTimes } from '../booking/shop/src/card-meta.js';
import { T } from '../booking/shop/src/i18n.js';
import { isPackage, timelineMinutes } from '../booking/shop/src/timeline.js';
import { fmtMinutes } from '../booking/shop/src/site-texts-logic.js';

export const TREATMENTS_TEXTS = Object.freeze({
  'ui.site.treatments_hero_book': { fi: 'Varaa saunotus', en: 'Book a saunotus' },
  'ui.site.treatments_hero_gift': { fi: 'Anna lahjaksi', en: 'Give as a gift' },
  'ui.site.treatments_smoke': { fi: 'Sisältää savusaunan', en: 'Includes the smoke sauna' },
  'ui.site.treatments_ask': { fi: 'Kysy ajankohtaa', en: 'Ask for a time' },
  'ui.site.treatments_start_title': { fi: 'Mistä aloittaa?', en: 'Where to start?' },
  'ui.site.treatments_start_first_title': { fi: 'Ensimmäinen kerta', en: 'A first time' },
  'ui.site.treatments_start_first_text': {
    fi: 'Avoin rituaali tutustuttaa saunotukseen yhdessä muiden kanssa, saunahoito kiireettömästi omassa rauhassa.',
    en: 'An open ritual introduces you to saunotus together with others; a sauna treatment does so unhurriedly, in your own peace.',
  },
  'ui.site.treatments_start_own_title': { fi: 'Oma syvä kokemus', en: 'A deep experience of your own' },
  'ui.site.treatments_start_own_text': {
    fi: 'Ohjattu saunaelämys hoitosauna Raunissa yhdelle tai kahdelle.',
    en: 'A guided sauna experience in the Rauni treatment sauna for one or two people.',
  },
  'ui.site.treatments_start_group_title': { fi: 'Porukalla', en: 'With a group' },
  'ui.site.treatments_start_group_text': {
    fi: 'Yhteinen ohjattu saunaelämys omalle ryhmälle.',
    en: 'A shared, guided sauna experience for your own group.',
  },
  'ui.site.treatments_steps_title': { fi: 'Näin saunotus etenee', en: 'How a saunotus goes' },
  'ui.site.treatments_step_arrive_title': { fi: 'Saapuminen', en: 'Arrival' },
  'ui.site.treatments_step_arrive_text': {
    fi: 'Saunotus tehdään hoitosauna Raunissa. Hoitoasiakkaiden käytössä ovat pukukoppi, suihku ja huussi.',
    en: 'Saunotus takes place in the Rauni treatment sauna. Treatment guests have a changing cubicle, a shower and an outdoor toilet.',
  },
  'ui.site.treatments_step_loyly_title': { fi: 'Löylyntervehdys', en: 'The löyly greeting' },
  'ui.site.treatments_step_loyly_text': {
    fi: 'Hoito alkaa rauhoittavalla löylyntervehdysrituaalilla.',
    en: 'The treatment begins with a calming löyly greeting.',
  },
  'ui.site.treatments_step_care_title': { fi: 'Hoito', en: 'The treatment' },
  'ui.site.treatments_step_care_text': {
    fi: 'Saunottaja johdattaa kokemusta lämmöllä, ilmalla, vedellä sekä vihdoilla, yrteillä, suolalla ja hunajalla. Halutessa mukaan voi tulla turvehoito. Voimakkuus mukautuu asiakkaan kokemuksen, toiveiden ja jaksamisen mukaan.',
    en: 'The sauna practitioner guides the experience using heat, air, water, whisks, herbs, salt and honey. If you wish, a peat treatment can also be included. The intensity of the löyly, the heat and the treatment is adapted to your experience, wishes and energy.',
  },
  'ui.site.treatments_step_tea_title': { fi: 'Rauhoittuminen ja yrttitee', en: 'Settling and herbal tea' },
  'ui.site.treatments_step_tea_text': {
    fi: 'Saunotukseen kuuluu lämmittävä yrttitee. Syväsaunotukseen kuuluu myös pientä purtavaa.',
    en: 'Saunotus includes a warming herbal tea. Deep saunotus also includes a light snack.',
  },
  'ui.site.treatments_fit_title': { fi: 'Sopiiko tämä minulle?', en: 'Is this for me?' },
  'ui.site.treatments_fit_intensity': {
    fi: 'Saunottaja mukauttaa löylyn, lämmön ja hoidon voimakkuuden aina asiakkaan kokemuksen, toiveiden ja jaksamisen mukaan.',
    en: 'The sauna practitioner always adapts the intensity of the löyly, the heat and the treatment to your experience, wishes and energy.',
  },
  'ui.site.treatments_fit_dress': {
    fi: 'Hoitoon voi osallistua alasti, osittain uima-asussa tai kokonaan uima-asussa. Kehon peittämiseen voidaan käyttää esimerkiksi vihtoja tai pyyhkeitä.',
    en: 'You can take part in the treatment naked, partly in swimwear or fully in swimwear. Birch whisks or towels can be used to cover the body.',
  },
  'ui.site.treatments_fit_new': {
    fi: 'Myös löylyyn vähemmän tottunut asiakas voi saada saunotuksesta syvästi rentouttavan ja turvallisen kokemuksen.',
    en: 'Even a guest less used to löyly can find the session a deeply relaxing and safe experience.',
  },
  'ui.site.treatments_session_link': { fi: 'Varaa saunavuoro', en: 'Book a sauna session' },
  'ui.site.treatments_faq_dress_q': { fi: 'Voinko osallistua uima-asussa tai alasti?', en: 'Can I take part in swimwear or naked?' },
  'ui.site.treatments_faq_new_q': { fi: 'Tarvitaanko aiempaa kokemusta?', en: 'Do I need previous experience?' },
  'ui.site.treatments_faq_where_q': { fi: 'Missä hoidot ja saunotukset tehdään?', en: 'Where do the treatments and saunotus take place?' },
});

// Yhdistelmäkortin otsikko ja ingressi. Hinnat, kestot ja nimet tulevat tuotteista, eivät tästä.
export const CARE_TEXTS = Object.freeze({
  'ui.site.care_pair_title': { fi: 'Saunahoito ja saunotus', en: 'Sauna Treatment and Saunotus' },
  'ui.site.care_pair_text': {
    fi: 'Lempeä saunahoito tai pidempi saunotus hoitosauna Raunissa. Valitse vaihtoehto ja varaa oma aikasi.',
    en: 'A gentle sauna treatment or a longer saunotus in the Rauni treatment sauna. Choose an option and book your own time.',
  },
});

// Kaupan kategoriachippi (catalog-kind.js): k=hoito esivalitsee Hoidot ja rituaalit, jos chippi on listalla; muuten kauppa näyttää kaiken.
export const TREATMENT_SHOP_HASH = '/?k=hoito';
const ASK_SLUG = 'morsiussauna';

export const TREATMENT_GROUPS = Object.freeze([
  { id: 'saunotukset', key: 's1', note: true, slugs: ['saunahoito-2', 'saunotus-2', 'syvasaunotus', 'perinnesaunotus-ryhmalle'] },
  { id: 'avoimet', key: 's2', slugs: ['saunarituaali-ja-savusaunavuoro', 'turvetorstai', 'perinnesaunotusilta'] },
  { id: 'yksityiset', key: 's3', mail: true, slugs: ['morsiussauna', 'turvesauna', 'synttarisauna'] },
]);

export const START_PATHS = Object.freeze([
  { title: 'ui.site.treatments_start_first_title', text: 'ui.site.treatments_start_first_text', slugs: ['saunarituaali-ja-savusaunavuoro', 'saunahoito-2'] },
  { title: 'ui.site.treatments_start_own_title', text: 'ui.site.treatments_start_own_text', slugs: ['saunotus-2', 'syvasaunotus'] },
  { title: 'ui.site.treatments_start_group_title', text: 'ui.site.treatments_start_group_text', slugs: ['perinnesaunotus-ryhmalle', 'morsiussauna'] },
]);

const STEPS = Object.freeze([
  { title: 'ui.site.treatments_step_arrive_title', text: 'ui.site.treatments_step_arrive_text', img: 'ovi-kaiverrus' },
  { title: 'ui.site.treatments_step_loyly_title', text: 'ui.site.treatments_step_loyly_text', img: 'rituaali' },
  { title: 'ui.site.treatments_step_care_title', text: 'ui.site.treatments_step_care_text', img: 'saunotus-selka' },
  { title: 'ui.site.treatments_step_tea_title', text: 'ui.site.treatments_step_tea_text', img: 'syvasaunotus' },
]);

// Toimituksellinen kuva, jos tuotteella ei ole public_product_images-riviä. Kuvat ovat jo content/images.jsonissa.
const FALLBACK_IMG = Object.freeze({
  'saunahoito-2': 'hunaja',
  'saunotus-2': 'saunotus-selka',
  'syvasaunotus': 'syvasaunotus',
  'perinnesaunotus-ryhmalle': 'j-ryhma',
  'saunarituaali-ja-savusaunavuoro': 'rituaali',
  'turvetorstai': 'j-turvetorstai',
  'perinnesaunotusilta': 'j-perinnesaunotusilta',
  'morsiussauna': 'j-morsiussauna',
  'turvesauna': 'j-turvesauna',
  'synttarisauna': 'j-synttarisauna',
});

const quiet = { warn() {} };
const tt = (key, lang) => tx(key, lang, { fallback: (CARE_TEXTS[key] || TREATMENTS_TEXTS[key])[lang], log: quiet });
export const careText = (key, lang) => tt(key, lang);

/** cards.json treatments.saunahoito + treatments.saunotus = yksi kortti. Tuotteet ja tuotesivut pysyvät erillään. */
export function carePairSpec() {
  const a = cards.treatments?.saunahoito;
  const b = cards.treatments?.saunotus;
  if (!a || !b || a.pairWith !== 'saunotus' || b.pairWith !== 'saunahoito') {
    throw new Error('treatments.saunahoito ja treatments.saunotus pitää yhdistää (pairWith)');
  }
  if (typeof a.kb !== 'string' || typeof b.kb !== 'string') throw new Error('yhdistelmäkortin slug puuttuu');
  return { slugs: [a.kb, b.kb], imageSlug: a.kb, fallbackImg: a.img || 'hunaja' };
}
const pic = (id, lang, o = {}) => picture(id, { alt: o.alt ?? alts[id]?.[lang] ?? '', ...o });
const sec = (cls, inner, id) => `<section class="section ${cls || ''}"${id ? ` id="${id}"` : ''}><div class="wrap">${inner}</div></section>`;
const head = (title, lead, orn) => `<header class="center"><h2 class="sec-title">${e(title)}</h2>${orn ? `<div class="divider">${icon('ikoni-ornamentti', 34)}</div>` : ''}${lead ? `<p class="lead">${e(lead)}</p>` : ''}</header>`;
const pname = (p, lang) => (lang === 'en' && p.name_en) || p.name || p.slug;
const shopT = (lang) => T[lang] || T.fi;

/** Sama hintarivi kuin kaupan kortilla: per henkilö, alk., tai perushinta + lisähenkilö. Ei kovakoodattua summaa. */
export function treatmentCardPrice(p, lang) {
  const t = shopT(lang);
  const v = money(p.price, lang);
  if (p.price_type === 'per_person') return `${v} ${t.perPerson}`;
  if (p.price_type === 'base_plus_extra_person' && p.extra_person_price && (p.capacity_max || 1) > 1) {
    return `${v} (${t.included(p.included_persons || 1)}, ${t.extra(money(p.extra_person_price, lang))})`;
  }
  if (p.price_type === 'from' || p.price_type === 'variable') return `${t.from} ${v}`;
  return v;
}

/** Yhdistelmäkortin vaihtoehto: sama hintakaava kuin muilla hoitokorteilla, alk.-etuliite kun kaava ei jo ala sillä. */
export function careOptionPrice(p, lang) {
  const t = shopT(lang);
  const full = treatmentCardPrice(p, lang);
  if (p.price_type === 'from' || p.price_type === 'variable') return full;
  return `${t.from} ${full}`;
}

/** Sama kesto kuin kaupan kortilla: paketin minuutit, muuten tuotteen duration_text(_en). */
export function treatmentCardWhen(p, lang) {
  if (isPackage(p)) return keepTimes(fmtMinutes(timelineMinutes(p)));
  const raw = (lang === 'en' && p.duration_text_en) || p.duration_text || '';
  return keepTimes(raw);
}

function blurb(p, lang) {
  const raw = shortRaw(p, lang);
  const text = raw ? visibleText(raw) : derivedExcerpt((lang === 'en' && p.description_en) || p.description || '');
  return String(text).replace(/\s+/g, ' ').trim();
}

function cardImage(p, lang, name) {
  const id = FALLBACK_IMG[p.slug];
  const fallbackHtml = id ? pic(id, lang, { sizes: SIZES.shop, alt: alts[id]?.[lang] || name }) : '';
  const im = productCardInner({ slug: p.slug, alt: name, fallbackHtml, sizes: SIZES.shop });
  if (!im.has) return '';
  return `<span class="bk-img card-img"${im.attrs}>${im.html}</span>`;
}

export function treatmentCard(p, lang) {
  if (!p?.slug) throw new Error('tuotekortilta puuttuu tuote');
  const name = pname(p, lang);
  const cta = p.slug === ASK_SLUG ? tt('ui.site.treatments_ask', lang) : site.ui[lang].reserve;
  const when = treatmentCardWhen(p, lang);
  const text = blurb(p, lang);
  const smoke = p.includes_smoke_sauna === true ? `<p class="tr-smoke">${e(tt('ui.site.treatments_smoke', lang))}</p>` : '';
  const href = pageHref('book', lang, shopHash(p.slug));
  return `<li class="bk-card"><a class="bk-card-link" href="${e(href)}">${cardImage(p, lang, name)}<h3>${e(name)}</h3>${smoke}${text ? `<p class="bk-desc">${e(text)}</p>` : ''}<div class="bk-card-meta" data-testid="card-meta">${when ? `<p class="bk-meta bk-card-when" data-testid="card-when">${e(when)}</p>` : ''}<p class="bk-meta bk-card-price" data-testid="card-price"><strong>${e(treatmentCardPrice(p, lang))}</strong></p></div><span class="btn sm">${e(cta)}<span class="sr"> – ${e(name)}</span></span></a></li>`;
}

function pairOption(p, lang) {
  const name = pname(p, lang);
  const href = pageHref('book', lang, shopHash(p.slug));
  const when = treatmentCardWhen(p, lang);
  const cta = site.ui[lang].reserve;
  return `<li><a class="bk-pair-opt" data-testid="care-pair-option" data-slug="${e(p.slug)}" href="${e(href)}"><span class="bk-pair-name">${e(name)}</span>${when ? `<span class="bk-meta bk-card-when" data-testid="card-when">${e(when)}</span>` : ''}<span class="bk-meta bk-card-price" data-testid="card-price"><strong>${e(careOptionPrice(p, lang))}</strong></span><span class="btn sm">${e(cta)}<span class="sr"> – ${e(name)}</span></span></a></li>`;
}

/** Kaksi tuotetta, yksi kortti: omat linkit, kestot ja alk.-hinnat. Kuva ensimmäisen tuotteen kuva. */
export function treatmentPairCard(products, lang) {
  if (!products?.length) throw new Error('yhdistelmäkortilta puuttuu tuote');
  const title = tt('ui.site.care_pair_title', lang);
  const text = tt('ui.site.care_pair_text', lang);
  const image = cardImage(products[0], lang, title);
  const opts = products.map((p) => pairOption(p, lang)).join('');
  return `<li class="bk-card bk-card-pair" data-testid="care-pair"><div class="bk-pair-body">${image}<h3>${e(title)}</h3>${text ? `<p class="bk-desc">${e(text)}</p>` : ''}<ul class="bk-pair-opts">${opts}</ul></div></li>`;
}

function groupCards(g, lang) {
  const pair = carePairSpec();
  const inPair = new Set(pair.slugs);
  const showPair = pair.slugs.every((slug) => g.slugs.includes(slug));
  let pairDone = false;
  const parts = [];
  for (const slug of g.slugs) {
    if (showPair && inPair.has(slug)) {
      if (!pairDone) {
        parts.push(treatmentPairCard(pair.slugs.map(productOf), lang));
        pairDone = true;
      }
      continue;
    }
    parts.push(treatmentCard(productOf(slug), lang));
  }
  return parts.join('');
}

function productOf(slug) {
  const p = liveProduct(slug);
  if (!p) throw new Error('tuotetta ei löydy: ' + slug);
  return p;
}

function hero(d, lang) {
  const book = pageHref('book', lang, TREATMENT_SHOP_HASH);
  const gift = pageHref('gift', lang);
  return `<section class="hero page">${pic(d.hero.img, lang, { eager: true, sizes: '100vw' })}<div class="wrap in"><h1>${e(d.hero.title)}</h1><p>${e(d.hero.text)}</p><div class="actions"><a class="btn gold" href="${e(book)}">${e(tt('ui.site.treatments_hero_book', lang))}</a><a class="btn ghost" href="${e(gift)}">${e(tt('ui.site.treatments_hero_gift', lang))}</a></div></div></section>`;
}

function paths(lang) {
  const items = START_PATHS.map((path) => {
    const links = path.slugs.map((slug) => {
      const p = productOf(slug);
      return `<li><a href="${e(pageHref('book', lang, shopHash(p.slug)))}">${e(pname(p, lang))}</a></li>`;
    }).join('');
    return `<li class="tr-path"><h3>${e(tt(path.title, lang))}</h3><p>${e(tt(path.text, lang))}</p><ul class="tr-path-links">${links}</ul></li>`;
  }).join('');
  return sec('tint', `${head(tt('ui.site.treatments_start_title', lang))}<ul class="tr-paths">${items}</ul>`, 'mista-aloittaa');
}

function groups(d, lang) {
  const mail = (subject) => `<a class="btn light sm" href="${e(`mailto:${site.contact.email}${subject ? '?subject=' + encodeURIComponent(subject) : ''}`)}">${e(site.contact.email)}</a>`;
  const session = `<a href="${e(pageHref('sauna', lang))}">${e(tt('ui.site.treatments_session_link', lang))}</a>`;
  return TREATMENT_GROUPS.map((g, i) => {
    const block = d[g.key];
    const cards = groupCards(g, lang);
    const note = g.note ? `<p class="center tr-note">${e(block.note)} ${session}</p>` : '';
    const more = g.mail ? `<p class="center" style="margin-top:22px">${e(block.note)} ${mail(block.title)}</p>` : '';
    return sec(i % 2 ? 'tint' : '', `${head(block.title, block.text, true)}<ul class="bk-cards">${cards}</ul>${note}${more}`, block.id || g.id);
  }).join('');
}

function steps(lang) {
  const items = STEPS.map((s) => `<li><div class="tr-step-img">${pic(s.img, lang, { sizes: '(min-width:1100px) 280px, (min-width:720px) 45vw, 100vw' })}</div><h3>${e(tt(s.title, lang))}</h3><p>${e(tt(s.text, lang))}</p></li>`).join('');
  return sec('tint', `${head(tt('ui.site.treatments_steps_title', lang))}<ol class="tr-steps">${items}</ol>`, 'nain-saunotus-etenee');
}

function fit(lang) {
  const points = ['ui.site.treatments_fit_intensity', 'ui.site.treatments_fit_dress', 'ui.site.treatments_fit_new']
    .map((k) => `<li><p>${e(tt(k, lang))}</p></li>`).join('');
  const photo = pic('vihta-hoito', lang, { sizes: '(min-width:900px) 520px, 100vw' });
  return sec('', `<div class="tr-fit"><div>${head(tt('ui.site.treatments_fit_title', lang))}<ul>${points}</ul></div><div class="tr-fit-photo">${photo}</div></div>`, 'sopiiko-minulle');
}

/** Näkyvät tuotteet JSON-LD:lle: nimi, lyhyt kuvaus ja hinta samasta tuotteesta kuin kortti. Alk.-hintaa ei merkitä kiinteäksi Offeriksi. */
export function treatmentOffers(lang) {
  return TREATMENT_GROUPS.flatMap((g) => g.slugs.map((slug) => {
    const p = productOf(slug);
    const name = pname(p, lang);
    return {
      id: p.id, slug: p.slug, name, description: blurb(p, lang) || name,
      price: +p.price, exact: p.price_type !== 'from' && p.price_type !== 'variable' && +p.price > 0,
    };
  }));
}

/** UKK: kysymys + vastaus, jotka näkyvät sivulla. Hinta huomautus on oma huomautus, ei kysymys. */
export function treatmentFaq(lang) {
  const d = pageDoc('treatments')[lang];
  return [
    { question: tt('ui.site.treatments_faq_dress_q', lang), answer: tt('ui.site.treatments_fit_dress', lang) },
    { question: tt('ui.site.treatments_faq_new_q', lang), answer: tt('ui.site.treatments_fit_new', lang) },
    { question: tt('ui.site.treatments_faq_where_q', lang), answer: d.intro.note },
  ];
}

function faq(d, lang) {
  const u = site.ui[lang];
  const session = `<a href="${e(pageHref('sauna', lang))}">${e(tt('ui.site.treatments_session_link', lang))}</a>`;
  const qs = treatmentFaq(lang).map((f) => `<details><summary>${e(f.question)}</summary><p>${e(f.answer)}</p></details>`).join('');
  return sec('tint', `<div class="narrow faq"><header class="center"><h2 class="sec-title">${e(u.faqKicker)}</h2></header>${qs}<div class="note-box"><p>${e(d.s1.note)} ${session}</p></div></div>`, 'ukk');
}

export function treatmentsBody(lang, { reviews = '' } = {}) {
  const d = pageDoc('treatments')[lang];
  const intro = sec('', `<div class="narrow center"><p class="kicker">${e(d.intro.kicker)}</p><h2 class="sec-title">${e(d.intro.title)}</h2><p class="lead">${e(d.intro.text)}</p></div>`);
  return hero(d, lang) + intro + paths(lang) + groups(d, lang) + steps(lang) + fit(lang) + reviews + faq(d, lang);
}
