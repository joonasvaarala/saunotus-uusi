// Tarkista-lista (admin_review_list): ei saunottajaa (migraatio 22; poikkeuksen myöntö oikeudella bookings.override), saunottajakonfliktit, sulkukonfliktit, ylitykset ja orvot lisäpalvelut.
// Tyhjä lista on hyvä uutinen; rivistä pääsee päivänäkymään tai varauksen tietoihin.
import { rpc } from '../sb.js';
import { h, fmtDay, fmtTime, errMsg, empty, badge, sourceBadge } from '../ui.js';
import { resName, SKILL_FI } from './legs.js';
import { grantButton } from './therapist.js';

const day = (iso) => new Date(iso).toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' });
const when = (iso) => `${fmtDay(iso)} ${fmtTime(iso)}`;

export async function render({ ctx, refs, reload }) {
  let v;
  try { v = await rpc('admin_review_list'); } catch (e) {
    return [h('h1', { text: 'Tarkista' }), h('p', { class: 'err', role: 'alert', text: `Tarkista-listaa ei saatu haettua: ${errMsg(e)}` })];
  }
  v = v && !Array.isArray(v) ? v : {};
  const link = (id, iso, label) => h('a', { class: 'rv-link', href: `#/?d=${day(iso)}` }, h('strong', { text: `varaus #${id}` }), ` · ${label || when(iso)}`);
  const days = (n) => (n === 0 ? 'tänään' : n === 1 ? 'huomenna' : n > 1 ? `${n} pv päästä` : n < 0 ? 'käynnissä/mennyt' : '');
  const SECTIONS = [
    ['missing_therapist', 'Ei saunottajaa', 'Varaus on tehty, mutta työvuoroissa ei ole vapaata saunottajaa. Lisää saunottaja työvuoroon (merkintä purkautuu tuonnissa) tai myönnä poikkeus perustelulla.',
      (x) => [link(x.reservation_id, x.starts_at), ` · ${x.product_name || ''}${x.persons ? ` · ${x.persons} hlö` : ''}${x.order_no ? ` · tilaus #${x.order_no}` : ''}`, sourceBadge(x) ? [' ', sourceBadge(x)] : null,
        x.days_to_start != null ? [' ', badge(x.days_to_start <= 2 ? 'warn' : 'muted', days(x.days_to_start))] : null, ' ',
        grantButton({ ...x, therapist_missing: true }, { ctx, onDone: () => reload() })]],
    ['therapist_conflicts', 'Saunottajakonfliktit', 'Varaus tarvitsee saunottajan, mutta vuoroja tai taitoa ei ole riittävästi (esim. vuoro muuttui varauksen jälkeen).',
      (x) => [link(x.reservation_id, x.starts_at), x.skill ? ` · taito: ${SKILL_FI[x.skill] || x.skill}` : '']],
    ['block_conflicts', 'Sulkukonfliktit', 'Varaus osuu myöhemmin lisättyyn sulkuun. Siirrä tai peru varaus.',
      (x) => [link(x.reservation_id, x.starts_at), x.resource_id ? ` · ${resName(refs, refs?.resources?.find((r) => r.id === x.resource_id)?.code)}` : '']],
    ['overrides', 'Ylitykset', 'Varaukset, jotka on tehty ohittamalla sulku- tai saunottajatarkistus (oikeus bookings.override).',
      (x) => [link(x.reservation_id, x.starts_at), h('br'), h('small', { text: `Syy: ${x.reason || '–'}` })]],
    ['orphan_addons', 'Orvot lisäpalvelut', 'Lisäpalvelun vanhempi (jälkilöyly / yksityisvuoro) on peruttu tai puuttuu.',
      (x) => [link(x.reservation_id, x.starts_at)]],
  ];
  const total = SECTIONS.reduce((a, [k]) => a + (Array.isArray(v[k]) ? v[k].length : 0), 0);
  const sec = ([k, title, hint, row]) => { const rows = Array.isArray(v[k]) ? v[k] : [];
    return h('section', { class: `card review-sec${rows.length ? ' has' : ''}`, 'data-testid': `review-${k}` },
      h('h2', {}, title, ' ', badge(rows.length ? 'warn' : 'ok', String(rows.length))), h('p', { class: 'muted', text: hint }),
      rows.length ? h('ul', { class: 'reslist' }, rows.map((x) => h('li', { class: 'resrow' }, h('span', {}, ...[].concat(row(x)))))) : empty('Ei tarkistettavaa.')); };
  return [h('h1', { text: 'Tarkista' }),
    h('p', { class: 'muted', role: 'status', text: total ? `${total} tarkistettavaa. Lista päivittyy tietokannasta joka kerta kun avaat sivun.` : 'Ei tarkistettavaa – kaikki tulevat varaukset ovat kunnossa.' }),
    h('button', { type: 'button', class: 'btn ghost sm', text: 'Päivitä', onclick: () => reload() }),
    ...SECTIONS.map(sec)];
}
