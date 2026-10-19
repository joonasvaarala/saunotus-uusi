// Avoin YTJ/PRH v3 (https://avoindata.prh.fi/opendata-ytj-api/v3). Ei avainta.
// GET vastaa access-control-allow-origin: *, joten hallinta kutsuu selaimesta suoraan.
// Verkkolaskuosoitetta rajapinta ei palauta.
import { normBusinessId, validBusinessId } from '../shop/src/invoice-validate.js';

export const YTJ_COMPANIES = 'https://avoindata.prh.fi/opendata-ytj-api/v3/companies';

export function ytjSearchUrl(term) {
  const t = String(term ?? '').trim().replace(/\s+/g, ' ');
  if (t.length < 2) return '';
  const u = new URL(YTJ_COMPANIES);
  const bid = normBusinessId(t);
  if (validBusinessId(bid)) u.searchParams.set('businessId', bid);
  else u.searchParams.set('name', t);
  return u.toString();
}

export function titleFi(s) {
  const t = String(s ?? '').trim();
  if (!t) return '';
  return t.toLocaleLowerCase('fi-FI').replace(/(^|[\s-])(\p{L})/gu, (_, a, b) => a + b.toLocaleUpperCase('fi-FI'));
}

function currentName(company) {
  const names = Array.isArray(company?.names) ? company.names : [];
  const official = names.filter((n) => String(n?.type) === '1' && !n.endDate);
  const list = official.length ? official : names.filter((n) => !n?.endDate);
  const pool = list.length ? list : names;
  pool.sort((a, b) => String(b?.registrationDate || '').localeCompare(String(a?.registrationDate || '')));
  return String(pool[0]?.name || '').trim();
}

function currentAddress(company) {
  const addrs = Array.isArray(company?.addresses) ? company.addresses : [];
  const open = addrs.filter((a) => !a?.endDate);
  const pool = open.length ? open : addrs;
  const pick = pool.find((a) => String(a?.type) === '2') || pool.find((a) => String(a?.type) === '1') || pool[0];
  if (!pick) return { street: '', zip: '', city: '' };
  const line = [pick.street, pick.buildingNumber].map((x) => String(x || '').trim()).filter(Boolean).join(' ');
  const co = String(pick.co || '').trim();
  const street = co ? (line ? `${co}, ${line}` : co) : line;
  const offices = Array.isArray(pick.postOffices) ? pick.postOffices : [];
  const city = (offices.find((o) => String(o?.languageCode) === '1') || offices[0])?.city || '';
  return { street, zip: String(pick.postCode || '').trim(), city: titleFi(city) };
}

export function mapYtjCompany(company) {
  const addr = currentAddress(company);
  return {
    source: 'ytj',
    company_name: currentName(company),
    business_id: String(company?.businessId?.value || '').trim(),
    street: addr.street,
    zip: addr.zip,
    city: addr.city,
  };
}

export function mapYtjResponse(json) {
  const list = Array.isArray(json?.companies) ? json.companies : [];
  return list.map(mapYtjCompany).filter((c) => c.company_name || c.business_id).slice(0, 8);
}

export async function fetchYtj(term, fetchImpl = globalThis.fetch) {
  const url = ytjSearchUrl(term);
  if (!url) return [];
  const r = await fetchImpl(url, { headers: { Accept: 'application/json' } });
  if (!r.ok) throw Object.assign(new Error('ytj_http'), { status: r.status });
  return mapYtjResponse(await r.json());
}
