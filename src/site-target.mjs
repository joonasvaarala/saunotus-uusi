// Julkaistavan sivuston ympäristö. build-pages.mjs kieltäytyy sekoittamasta testiä ja tuotantoa.
// Fixture-build (scripts/build.mjs, SITE_URL=https://example.test) ei kulje tästä: se ei ole julkaistava sivusto.

export const PROD_REF = 'sxbofnuisemspgquoxyv';
export const DEV_REF = 'aoejjmfzulhkhxbehphs';
export const PROD_SUPABASE_URL = `https://${PROD_REF}.supabase.co`;
export const DEV_SUPABASE_URL = `https://${DEV_REF}.supabase.co`;
export const PROD_SITE = 'https://saunotus.fi';

const SUPABASE_URL = /^https:\/\/([a-z0-9-]+)\.supabase\.co$/;
const LOCAL_URL = /^http:\/\/localhost(:\d+)?$/;

export function supabaseRef(url) {
  const m = SUPABASE_URL.exec(String(url || '').trim().replace(/\/$/, ''));
  return m ? m[1] : '';
}

function siteHost(siteUrl) {
  try { return new URL(siteUrl).hostname; } catch { return ''; }
}

/**
 * Julkaistava koonti. SITE_ENV=prod vaatii tuotantoprojektin ja https://saunotus.fi.
 * SITE_ENV=test kieltäytyy tuotantoprojektista ja saunotus.fi-osoitteesta.
 */
export function assertBuildTarget({ siteEnv, siteUrl, supabaseUrl }) {
  const env = String(siteEnv || '').trim();
  const site = String(siteUrl || '').trim().replace(/\/$/, '');
  const supa = String(supabaseUrl || '').trim().replace(/\/$/, '');
  const host = siteHost(site);
  if (env === 'prod') {
    if (supa !== PROD_SUPABASE_URL) {
      throw new Error(`tuotantobuild vaatii Supabase-osoitteen ${PROD_SUPABASE_URL}`);
    }
    if (site !== PROD_SITE) {
      throw new Error(`tuotantobuild vaatii SITE_URL=${PROD_SITE}`);
    }
    return;
  }
  if (env === 'test') {
    if (!site) throw new Error('testibuild vaatii SITE_URL:n');
    if (supa.includes(PROD_REF) || supabaseRef(supa) === PROD_REF) {
      throw new Error(`testibuild ei saa käyttää tuotannon Supabase-projektia (${PROD_REF})`);
    }
    if (host === 'saunotus.fi' || host === 'www.saunotus.fi') {
      throw new Error('testibuild ei saa käyttää osoitetta saunotus.fi');
    }
    return;
  }
  throw new Error(`SITE_ENV on oltava test tai prod (saatiin ${env || 'tyhjä'})`);
}

/** Saunabot-widgetin osoite buildin Supabase-projektista. Ilman osoitetta tyhjä (ei kovakoodattua projektia). */
export function chatbotWidgetSrc(supabaseUrl) {
  const url = String(supabaseUrl || '').trim().replace(/\/$/, '');
  if (!SUPABASE_URL.test(url) && !LOCAL_URL.test(url)) return '';
  return `${url}/functions/v1/saunabot/widget.js`;
}

/** Tuotekuvabucketin julkinen juuri. Ilman kelvollista osoitetta tyhjä, jolloin kutsujan varapolku jää voimaan. */
export function productStorageBase(supabaseUrl) {
  const url = String(supabaseUrl || '').trim().replace(/\/$/, '');
  if (!SUPABASE_URL.test(url) && !LOCAL_URL.test(url)) return '';
  return `${url}/storage/v1/object/public/product-images`;
}
