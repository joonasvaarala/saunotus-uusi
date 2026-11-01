// Testiympäristön banneri. Julkaistavaan HTML:ään vain kun buildin lippu on päällä.
// Ei osoitearvailua: TEST_ENV_BANNER (config/env/*.env) ja SITE_ENV päättävät. Tuotantotulosteeseen ei kirjoiteta elementtiä eikä tekstiä.
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';

export const TEST_BANNER_BG = '#9a3412';
export const TEST_BANNER_FG = '#ffffff';
export const TEST_BANNER_ID = 'test-env-banner';

export const TEST_BANNER_COPY = {
  fi: {
    title: 'Testiympäristö',
    text: 'Tämä on testiversio. Varaukset ja muutokset eivät näy oikeassa järjestelmässä.',
  },
  en: {
    title: 'Test environment',
    text: 'This is a test version. Bookings and changes do not appear in the real system.',
  },
};

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

/**
 * Banneri kirjoitetaan vain SITE_ENV=test -buildiin. Tuotannossa ja tyhjässä ympäristössä aina false,
 * myös jos TEST_ENV_BANNER jäisi vahingossa päälle. Julkaistun buildin ristiriidan kaataa assertTestBannerFlag.
 * @param {NodeJS.ProcessEnv} [env]
 */
export function testBannerEnabled(env = process.env) {
  const siteEnv = String(env.SITE_ENV || '').trim();
  const flag = String(env.TEST_ENV_BANNER ?? '').trim();
  if (siteEnv !== 'test') return false;
  if (flag === 'off' || (flag !== '' && flag !== 'on')) return false;
  return true;
}

/** Julkaistu koonti: lippu on pakollinen ja sen pitää täsmätä SITE_ENV:n kanssa. */
export function assertTestBannerFlag(env = process.env) {
  const siteEnv = String(env.SITE_ENV || '').trim();
  const flag = String(env.TEST_ENV_BANNER ?? '').trim();
  if (flag !== 'on' && flag !== 'off') throw new Error('TEST_ENV_BANNER on on tai off');
  if (siteEnv === 'prod' && flag !== 'off') throw new Error('tuotantobuild vaatii TEST_ENV_BANNER=off');
  if (siteEnv === 'test' && flag !== 'on') throw new Error('testibuild vaatii TEST_ENV_BANNER=on');
  if (siteEnv !== 'test' && siteEnv !== 'prod') throw new Error('SITE_ENV on oltava test tai prod');
  return testBannerEnabled(env);
}

export function testBannerHtml(lang = 'fi') {
  const copy = TEST_BANNER_COPY[lang] || TEST_BANNER_COPY.fi;
  const code = lang === 'en' ? 'en' : 'fi';
  return `<div id="${TEST_BANNER_ID}" class="test-env-banner" role="note" lang="${code}"><strong>${esc(copy.title)}</strong><p>${esc(copy.text)}</p></div>`;
}

const BANNER_LOOK = `#test-env-banner{position:sticky;top:0;z-index:80;background:${TEST_BANNER_BG};color:${TEST_BANNER_FG};text-align:center;padding:calc(8px + env(safe-area-inset-top,0px)) 14px 8px;font:600 15px/1.35 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;box-shadow:0 1px 0 rgba(0,0,0,.22)}
#test-env-banner strong{display:block;font-size:16px;letter-spacing:.01em}
#test-env-banner p{margin:2px 0 0;font-weight:500;font-size:13.5px;line-height:1.35}`;

/** @param {'public'|'hallinta'|'offline'|'plain'} kind */
export function bannerCss(kind) {
  if (kind === 'public') {
    return `${BANNER_LOOK}
.site-sticky{position:sticky;top:0;z-index:60}
.site-sticky .site-header{position:relative;top:auto}
.site-sticky #test-env-banner{position:static}
body:has(.site-sticky) .skip:focus{top:8px;z-index:70}
body:has(.site-sticky) :is(#valitse-aika,#bk-day-h,.bk-pc,.bk-review,.bk-checkout,#mista-aloittaa,#saunotukset,#avoimet,#yksityiset,#nain-saunotus-etenee,#sopiiko-minulle,#ukk,.vc-choose,.ord-card,.art-body h2,.art-body h3){scroll-margin-top:160px}`;
  }
  if (kind === 'hallinta') {
    return `html:has(#test-env-banner){--test-banner-h:64px;scroll-padding-top:var(--test-banner-h)}
${BANNER_LOOK}
body:has(#test-env-banner) .top{top:var(--test-banner-h)}
body:has(#test-env-banner) #login-screen,body:has(#test-env-banner) #setpw-screen{min-height:calc(100vh - var(--test-banner-h));min-height:calc(100dvh - var(--test-banner-h))}
@media(min-width:900px){
body:has(#test-env-banner) #shell{min-height:calc(100vh - var(--test-banner-h));min-height:calc(100dvh - var(--test-banner-h))}
body:has(#test-env-banner) .nav{top:calc(56px + var(--test-banner-h));height:calc(100vh - 56px - var(--test-banner-h));height:calc(100dvh - 56px - var(--test-banner-h))}
}
@media(max-width:899px){
body:has(#test-env-banner) #shell .nav-rail{top:calc(56px + var(--test-banner-h));height:calc(100dvh - 56px - var(--test-banner-h));max-height:calc(100dvh - 56px - var(--test-banner-h))}
}
body.shot:has(#test-env-banner) .top{top:auto}
body.shot:has(#test-env-banner) .nav{position:static;top:auto;height:auto}`;
  }
  if (kind === 'offline') {
    return `${BANNER_LOOK}
#test-env-banner{width:100%;align-self:stretch}
body:has(#test-env-banner){display:flex;flex-direction:column;align-items:stretch;justify-content:flex-start;min-height:100dvh;min-height:100vh;place-items:stretch;padding:0}
body:has(#test-env-banner) main{margin-block:auto;width:min(28rem,100%);padding:24px;box-sizing:border-box}`;
  }
  return BANNER_LOOK;
}

export function bannerMeasureScript() {
  return '<script>(function(){var el=document.getElementById("test-env-banner");if(!el)return;function a(){document.documentElement.style.setProperty("--test-banner-h",el.offsetHeight+"px")}a();if(window.ResizeObserver)new ResizeObserver(a).observe(el);window.addEventListener("resize",a)})();</script>';
}

export function testBannerStyleTag(kind) {
  return `<style id="test-env-banner-css">${bannerCss(kind)}</style>`;
}

/** Lisää bannerin heti body-tunnisteen jälkeen. Toista kertaa ei lisätä. */
export function injectTestBanner(html, { lang = 'fi', kind = 'plain' } = {}) {
  if (typeof html !== 'string' || !/<body(\s|>)/i.test(html)) throw new Error('test-banner: body puuttuu');
  if (html.includes(`id="${TEST_BANNER_ID}"`)) return html;
  const extra = kind === 'hallinta' ? `\n${bannerMeasureScript()}` : '';
  const block = `${testBannerStyleTag(kind)}\n${testBannerHtml(lang)}${extra}`;
  let out = html.replace(/<body(\s[^>]*)?>/i, (m) => `${m}\n${block}`);
  if (kind === 'hallinta' || kind === 'offline') {
    out = out.replace(/(<meta\s+name="viewport"\s+content=")([^"]*)(")/i, (full, a, v, c) => (v.includes('viewport-fit=cover') ? full : `${a}${v},viewport-fit=cover${c}`));
  }
  return out;
}

const TEXT_EXT = /\.(html|js|mjs|css|json|txt|svg|webmanifest)$/i;
const REQUIRED_WHEN_ON = [
  'hallinta/index.html',
  'hallinta/offline.html',
  'index.html',
  'en/index.html',
  'varaa/index.html',
  'en/book/index.html',
  'juomat/index.html',
  'en/drinks/index.html',
  'vuoro/index.html',
  'vuoro/oma/index.html',
];

function walkTextFiles(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) { walkTextFiles(path, out); continue; }
    if (TEXT_EXT.test(name)) out.push(path);
  }
  return out;
}

/** enabled=false: tuotantotulosteessa ei saa olla banneria päällä. enabled=true: hallinta ja julkiset sivut sisältävät sen. */
export function testBannerProblems(root, { enabled }) {
  const problems = [];
  const marker = `id="${TEST_BANNER_ID}"`;
  const sentences = [TEST_BANNER_COPY.fi.text, TEST_BANNER_COPY.en.text];
  const files = walkTextFiles(root);
  const byRel = new Map();
  for (const path of files) {
    const rel = relative(root, path).split('\\').join('/');
    const text = readFileSync(path, 'utf8');
    byRel.set(rel, text);
    const hasMarker = text.includes(marker);
    const hasSentence = sentences.some((s) => text.includes(s));
    const flagOn = /"testBanner":\s*true/.test(text);
    if (!enabled && (hasMarker || hasSentence || flagOn)) {
      problems.push(`${rel}: testiympäristön banneri on mukana tuotantotulosteessa`);
    }
  }
  const config = byRel.get('hallinta/config.js') || '';
  if (enabled) {
    if (!/"testBanner":\s*true/.test(config)) problems.push('hallinta/config.js: testBanner ei ole true');
    for (const rel of REQUIRED_WHEN_ON) {
      const text = byRel.get(rel);
      if (!text || !text.includes(marker)) problems.push(`${rel}: banneri puuttuu`);
    }
    const fi = byRel.get('hallinta/index.html') || '';
    if (!fi.includes(TEST_BANNER_COPY.fi.text)) problems.push('hallinta/index.html: suomenkielinen teksti puuttuu');
    const appAt = fi.indexOf('id="app"');
    const bannerAt = fi.indexOf(marker);
    const loginAt = fi.indexOf('id="login-screen"');
    const setpwAt = fi.indexOf('id="setpw-screen"');
    if (!(bannerAt >= 0 && appAt > bannerAt && loginAt > bannerAt && setpwAt > bannerAt)) {
      problems.push('hallinta/index.html: banneri ei ole sivun kärjessä kirjautumisen ja salasanan asetuksen yläpuolella');
    }
    const en = byRel.get('en/index.html') || '';
    if (!en.includes(TEST_BANNER_COPY.en.text)) problems.push('en/index.html: englanninkielinen banneri puuttuu');
  } else if (!/"testBanner":\s*false/.test(config)) {
    problems.push('hallinta/config.js: testBanner ei ole false');
  }
  return problems;
}
