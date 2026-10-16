// Kalenterisulut (migraatio 18): sulkukalenterit, tulevat tapahtumat, konfliktit ja synkkaajot (admin_closure_overview, vain luku) sekä tapahtuman ohitus (admin_set_closure_override).
// Oikeus blocks.manage (sama kuin sulkujen hallinta; staff, manager, admin) – funktio tarkistaa oikeuden, näkymä piilottaa napit ilman sitä.
// Ohitus: Ohita (ignore: tapahtuma ei sulje) / Estä (block: sulkee, esim. karkea jakso) / Palauta automaattinen (tyhjä = säännöt päättävät). Synkka säilyttää ohituksen.
import { rpc } from '../sb.js';
import { h, badge, field, fmtDT, fmtDay, fmtTime, dialog, toast, run, errMsg, empty } from '../ui.js';
import { resName } from './legs.js';

const DAYS = [30, 60, 180, 365];
const day = (iso) => new Date(iso).toLocaleDateString('sv-SE', { timeZone: 'Europe/Helsinki' });
const OUTCOME = { ok: ['ok', 'Onnistui'], guard: ['warn', 'Suoja pysäytti'], error: ['err', 'Virhe'] };
const CLASS_FI = { closure: 'Sulku', rough: 'Karkea jakso' };

function stats(s) {
  if (!s) return '';
  const p = [];
  if (s.events_seen != null) p.push(`${s.events_seen} tapahtumaa`);
  if (s.candidates != null) p.push(`${s.candidates} sulkuehdokasta`);
  if (s.rough) p.push(`${s.rough} karkeaa jaksoa`);
  if (s.conflicting_reservations) p.push(`${s.conflicting_reservations} konfliktia`);
  if (s.guard) p.push(`massapoistosuoja (${s.would_delete} poistoa)`);
  return p.join(' · ');
}

export async function render({ ctx, refs, query, reload }) {
  const days = DAYS.includes(+query.get('days')) ? +query.get('days') : 60;
  let v;
  try { v = await rpc('admin_closure_overview', { p_days: days }); } catch (e) {
    return [h('h1', { text: 'Kalenterisulut' }), h('p', { class: 'err', role: 'alert', text: `Kalenterisulkujen yleiskuvaa ei saatu haettua: ${errMsg(e)}` })];
  }
  v = v && !Array.isArray(v) ? v : {};
  const cals = Array.isArray(v.calendars) ? v.calendars : [], events = Array.isArray(v.events) ? v.events : [], conflicts = Array.isArray(v.conflicts) ? v.conflicts : [], runs = Array.isArray(v.runs) ? v.runs : [];
  const calName = (c) => cals.find((x) => x.code === c)?.name || c;
  const canEdit = ctx.can('blocks.manage');
  const anyActive = cals.some((c) => c.active);

  const periodSw = h('fieldset', { class: 'srcset typeset', 'data-testid': 'closure-days' }, h('legend', { text: 'Näytä tapahtumat' }),
    DAYS.map((n) => h('label', { class: 'srcopt' }, h('input', { type: 'radio', name: 'cdays', value: n, checked: n === days || null, onchange: () => { location.hash = `#/sulkukalenterit${n === 60 ? '' : `?days=${n}`}`; } }), h('span', { text: `${n} pv` }))));

  const calCard = (c) => h('li', { class: `card calcard${c.active ? '' : ' off'}`, 'data-testid': 'closure-calendar', 'data-code': c.code },
    h('div', { class: 'calhead' }, h('strong', { text: c.name }), c.active ? badge('ok', 'Käytössä') : badge('muted', 'Ei käytössä'), c.consecutive_failures > 0 ? badge('err', `${c.consecutive_failures} virhettä peräkkäin`) : null),
    h('p', { class: 'muted', text: `Sulkee: ${resName(refs, c.resource_code)}${c.configured ? '' : ' · kalenteria ei ole vielä liitetty'}` }),
    h('p', { class: 'muted', text: c.last_success_at ? `Viimeksi synkattu ${fmtDT(c.last_success_at)}${stats(c.last_stats) ? ` (${stats(c.last_stats)})` : ''}` : 'Ei synkattu vielä' }),
    c.last_error ? h('p', { class: 'err', role: 'status', text: `Viimeisin virhe: ${c.last_error}` }) : null);

  const confList = conflicts.length
    ? h('ul', { class: 'reslist' }, conflicts.map((x) => h('li', { class: 'resrow' }, h('span', {}, h('a', { class: 'rv-link', href: `#/?d=${day(x.starts_at)}` }, h('strong', { text: `varaus #${x.reservation_id}` }), ` · ${fmtDay(x.starts_at)} ${fmtTime(x.starts_at)}`),
        x.resource_id ? ` · ${resName(refs, refs?.resources?.find((r) => r.id === x.resource_id)?.code)}` : ''))))
    : empty('Ei konflikteja: yksikään varaus ei osu kalenterisulkuun.');

  const override = (ev, value) => {
    const note = h('textarea', { name: 'note', rows: 3, maxlength: 300, placeholder: 'Esim. hoitaja löytyi, sovittu erikseen' });
    const msg = { ignore: ['Ohita tapahtuma', 'Tapahtuma ei sulje mitään (sulku poistetaan). Synkka säilyttää ohituksen.'], block: ['Estä: tapahtuma sulkee', 'Tapahtuma sulkee kohteen, vaikka säännöt eivät sulkisi (esim. karkea jakso).'], null: ['Palauta automaattinen', 'Säännöt päättävät taas, sulkeeko tapahtuma.'] }[String(value)];
    const err = h('p', { class: 'err', role: 'alert', hidden: true });
    const f = h('form', { class: 'stack' }, h('p', {}, h('strong', { text: ev.reason || '(ei otsikkoa)' }), ` · ${calName(ev.calendar_code)} · ${fmtDT(ev.starts_at)}`), h('p', { class: 'muted', text: msg[1] }),
      field('Muistiinpano (valinnainen)', note), err, h('div', { class: 'row wrap' }, h('button', { class: 'btn primary', type: 'submit', text: msg[0] }), h('button', { class: 'btn ghost', type: 'button', text: 'Peruuta', onclick: () => d.close() })));
    const d = dialog(msg[0], f);
    f.addEventListener('submit', (e2) => { e2.preventDefault(); run(f.querySelector('button[type=submit]'), async () => {
      err.hidden = true;
      let r; try { r = await rpc('admin_set_closure_override', { p_event_id: ev.id, p_override: value, p_note: note.value.trim() || null }); } catch (e) { err.textContent = errMsg(e); err.hidden = false; return; }
      toast(`Tallennettu · sulkuja lisätty ${r.blocks_inserted ?? 0}, päivitetty ${r.blocks_updated ?? 0}, poistettu ${r.blocks_deleted ?? 0}`); d.close(); reload();
    }); });
  };

  const evRow = (e) => h('li', { class: `resrow ev${e.override ? ' has-ovr' : ''}`, 'data-testid': 'closure-event' },
    h('div', { class: 'evmain' },
      h('strong', { text: e.reason || '(ei otsikkoa)' }),
      h('span', { class: 'muted', text: ` · ${calName(e.calendar_code)}` }), h('br'),
      h('span', { text: e.all_day ? `${fmtDay(e.starts_at)} – ${fmtDay(new Date(new Date(e.ends_at).getTime() - 1).toISOString())} (koko päivä)` : `${fmtDT(e.starts_at)} – ${fmtDT(e.ends_at)}` }), h('br'),
      h('span', { class: 'evbadges' }, badge('muted', CLASS_FI[e.class] || e.class), e.effective_block ? badge('warn eff', 'Sulkee') : badge('ok eff', 'Ei sulje'),
        e.override === 'ignore' ? badge('muted ovr-i', 'Ohitettu') : e.override === 'block' ? badge('warn ovr-b', 'Pakotettu estoksi') : null,
        e.class === 'rough' && !e.override ? h('small', { class: 'muted', text: 'Yli 36 h kellonaikatapahtuma; ei sulje oletuksena' }) : null),
      e.override_note ? h('small', { class: 'evnote', text: `Muistiinpano: ${e.override_note}` }) : null),
    canEdit ? h('div', { class: 'evact row wrap' },
      e.override !== 'ignore' && e.effective_block ? h('button', { type: 'button', class: 'btn sm', 'data-act': 'ignore', text: 'Ohita', onclick: () => override(e, 'ignore') }) : null,
      e.override !== 'block' && !e.effective_block ? h('button', { type: 'button', class: 'btn sm', 'data-act': 'block', text: 'Estä', onclick: () => override(e, 'block') }) : null,
      e.override ? h('button', { type: 'button', class: 'btn ghost sm', 'data-act': 'reset', text: 'Palauta automaattinen', onclick: () => override(e, null) }) : null) : null);

  const runRow = (r) => { const [k, label] = OUTCOME[r.outcome] || ['muted', r.outcome]; return h('li', { class: 'resrow' }, h('span', {}, h('strong', { text: calName(r.calendar_code) }), ` · ${fmtDT(r.started_at)} `, badge(k, label),
    r.error ? h('small', { class: 'err', text: ` ${r.error}` }) : null, stats(r.stats) ? h('small', { class: 'muted', text: ` ${stats(r.stats)}` }) : null)); };

  return [h('h1', { text: 'Kalenterisulut' }),
    h('p', { class: 'muted', text: 'Sulut tulevat Google-kalentereista (hoidot, Rauni, perinnesaunotus, savusauna). Kalenterista tulevaa sulkua ei muokata hallinnassa: ohita tapahtuma tai muuta sitä kalenterissa. Käsin tehdyt sulut (esim. Lauran koulutus) lisätään päivänäkymässä tai Resurssit-sivulla.' }),
    anyActive ? null : h('p', { class: 'notice', role: 'status', 'data-testid': 'sync-off', text: 'Synkronointi ei ole käynnissä: yhtään kalenteria ei ole otettu käyttöön, joten kalenterisulkuja ei synny.' }),
    h('section', { class: 'card' }, h('h2', { text: 'Kalenterit' }), h('ul', { class: 'calgrid' }, cals.map(calCard))),
    h('section', { class: `card review-sec${conflicts.length ? ' has' : ''}`, 'data-testid': 'closure-conflicts' }, h('h2', {}, 'Konfliktit ', badge(conflicts.length ? 'warn' : 'ok', String(conflicts.length))),
      h('p', { class: 'muted', text: 'Varaukset, jotka osuvat kalenterisulkuun (varaus on tehty ennen sulkua). Siirrä tai peru varaus, tai ohita sulku.' }), confList),
    h('section', { class: 'card', 'data-testid': 'closure-events' }, h('h2', {}, 'Tulevat tapahtumat ', badge('muted', String(events.length))), periodSw,
      events.length ? h('ul', { class: 'reslist evlist' }, events.map(evRow)) : empty(`Ei sulkuehdokkaita seuraavan ${days} päivän aikana.`)),
    h('section', { class: 'card', 'data-testid': 'closure-runs' }, h('h2', { text: 'Viimeisimmät synkkaajot' }), runs.length ? h('ul', { class: 'reslist' }, runs.map(runRow)) : empty('Ei ajoja: synkronointia ei ole ajettu.')),
    h('p', {}, h('button', { type: 'button', class: 'btn ghost sm', text: 'Päivitä', onclick: () => reload() }))];
}
