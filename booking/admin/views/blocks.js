// Sulut (space_blocks): yhteinen lista ja lisäysikkuna päivänäkymälle ja Resurssit-näkymälle.
// Migraatio 18: kalenterista tulevalla sululla on closure_event_id → merkki "Kalenterisulku", vain luettava (ei Poista-nappia; palvelin estää muokkauksen koodilla closure_managed).
// Käsin tehdyt sulut (closure_event_id null) voi poistaa kuten ennen; uusi sulkukohde Laura (koulutus yms.) valitaan lisäysikkunassa.
import { rpc } from '../sb.js';
import { h, badge, fmtDT, toast, run, dialog, field, helsinkiIso } from '../ui.js';
import { resName } from './legs.js';

const resCode = (b, refs) => b.resource_code || refs?.resources?.find((r) => r.id === b.space_id)?.code || null;
export const isCalendarBlock = (b) => b.closure_event_id != null;

export function blockList(blocks, refs, reload, emptyText) {
  if (!blocks?.length) return h('p', { class: 'muted', text: emptyText });
  return h('ul', { class: 'reslist blocklist' }, blocks.map((b) => {
    const code = resCode(b, refs), cal = isCalendarBlock(b);
    return h('li', { class: `resrow block${cal ? ' calblock' : ''}`, 'data-testid': cal ? 'calendar-block' : 'manual-block' },
      h('span', { class: 'blk' },
        h('span', { class: 'blk-time', text: `${fmtDT(b.starts_at)} – ${fmtDT(b.ends_at)}` }),
        h('span', { class: 'blk-meta' }, code && code !== 'savusauna' ? badge('space', resName(refs, code)) : null, cal ? badge('muted cal', 'Kalenterisulku') : null),
        b.reason ? h('span', { class: 'blk-reason', text: b.reason }) : null,
        cal ? h('small', { class: 'muted' }, 'Tulee sulkukalenterista, vain luettava. ', h('a', { href: '#/sulkukalenterit', text: 'Kalenterisulut' }), ' (ohitus ja tapahtumat).') : null),
      cal ? null : h('button', { type: 'button', class: 'btn danger sm', onclick: (e) => run(e.target, async () => { await rpc('admin_delete_block', { p_id: b.id }); toast('Sulku poistettu'); reload(); }) }, 'Poista'));
  }));
}

// Lisäysikkuna: kohde (tila tai Laura), aika, syy. date = oletuspäivä (päivänäkymä) tai null
export function blockDialog(date, refs, reload) {
  const targets = (refs.resources || []).filter((r) => r.kind === 'space' || r.code === 'laura');
  const sel = h('select', { name: 't', 'aria-label': 'Sulun kohde' }, targets.map((r) => h('option', { value: r.id, text: r.code === 'laura' ? 'Laura (koulutus, poissaolo)' : r.name, selected: r.code === 'savusauna' || null })));
  const hint = h('small', { class: 'muted', hidden: true, text: 'Estää Lauran taitoa vaativat tuotteet (esim. hoidot, joissa saunottajaksi vaaditaan Laura). Koulutus-kalenteritapahtumat eivät sulje mitään, joten koulutus kirjataan tähän käsin.' });
  const f = h('form', { class: 'stack' },
    field('Kohde', sel), hint,
    field('Alkaa', h('input', { type: 'datetime-local', name: 's', value: date ? `${date}T08:00` : '', required: true })),
    field('Päättyy', h('input', { type: 'datetime-local', name: 'e', value: date ? `${date}T22:00` : '', required: true })),
    field('Syy', h('input', { name: 'r', placeholder: 'esim. huolto, koulutus, yksityistilaisuus', maxlength: 200 })),
    h('button', { class: 'btn primary', type: 'submit', text: 'Lisää sulku' }));
  const upd = () => { hint.hidden = refs.resources.find((r) => r.id === +sel.value)?.code !== 'laura'; };
  sel.addEventListener('change', upd); upd();
  const d = dialog('Lisää sulku', f);
  f.addEventListener('submit', (ev) => { ev.preventDefault(); run(f.querySelector('button[type=submit]'), async () => {
    await rpc('admin_create_block', { p_space_id: +sel.value, p_starts_at: helsinkiIso(f.s.value), p_ends_at: helsinkiIso(f.e.value), p_reason: f.r.value || null });
    toast('Sulku lisätty'); d.close(); reload();
  }); });
}
