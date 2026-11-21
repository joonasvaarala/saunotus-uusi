// Asetukset › Maksut ja laskutus › SumUp-korttipääte (Joonas 21.11.2026, t1865u). Oikeus settings.edit.
// Lukijan valinta, oletus, poisto ja paritus siirretty Pikakassan maksuikkunasta tänne. Samat kutsut kuin ennen:
// admin_get_sumup_status, admin_sumup_reader_set_default, admin_sumup_reader_remove ja Edge sumup-pos { action: 'reader_pair' }.
// Pikakassa käyttää aina oletuslukijaa (is_default).
import { rpc, fn as edgeFn } from '../sb.js';
import { h, toast, errMsg } from '../ui.js';
import { loadPosTexts, posText } from '../pos-texts.js';
import { getLang } from '../talous-i18n.js';
import { suErrorKey, validPairingCode, normalizePairingCode } from '../sumup-pos.js';

const MOCK = () => { try { return new URLSearchParams(location.search).get('mock') === '1'; } catch { return false; } };

export function sumupSettingsCard({ ctx } = {}) {
  const t = (k) => posText(k, getLang());
  const callFn = MOCK() && typeof globalThis.__adminMock?.fn === 'function' ? globalThis.__adminMock.fn : edgeFn;
  const st = { readers: [], mode: null, simulated: false, selected: '', pairCode: '', pairName: '', busy: false, failed: false, loaded: false };
  const root = h('section', { class: 'card', id: 'sumup-asetukset', 'data-testid': 'set-sumup' });

  async function load() {
    try {
      const r = await rpc('admin_get_sumup_status');
      st.readers = Array.isArray(r?.readers) ? r.readers.filter((x) => x && x.active !== false) : [];
      st.mode = r?.mode || null; st.simulated = r?.simulated === true; st.failed = false;
      if (!st.readers.some((x) => x.reader_id === st.selected)) st.selected = (st.readers.find((x) => x.is_default) || st.readers[0])?.reader_id || '';
    } catch { st.failed = true; }
    st.loaded = true;
  }

  async function act(work) {
    if (st.busy) return;
    st.busy = true; draw();
    try { await work(); } catch (e) { toast(e?.code ? t(suErrorKey(e.code)) : errMsg(e), 'err'); }
    finally { st.busy = false; await load(); draw(); }
  }

  function draw() {
    const kids = [h('h2', { text: t('su_settings_title') }), h('p', { class: 'muted', text: t('su_settings_lead') })];
    if (!st.loaded) { root.replaceChildren(...kids, h('p', { class: 'muted', text: '…' })); return; }
    if (st.failed) { root.replaceChildren(...kids, h('p', { class: 'err', role: 'alert', 'data-testid': 'set-sumup-error', text: t('su_load_failed') })); return; }
    if (st.simulated) kids.push(h('p', { class: 'muted', 'data-testid': 'set-sumup-note', text: t('su_simulated') }));
    else if (st.mode === 'test') kids.push(h('p', { class: 'muted', 'data-testid': 'set-sumup-note', text: t('su_test_note') }));
    if (st.readers.length) {
      const sel = h('select', { 'data-testid': 'set-sumup-reader', 'aria-label': t('su_pick'), onchange: (e) => { st.selected = e.target.value; draw(); } },
        ...st.readers.map((x) => h('option', { value: x.reader_id, text: (x.name || x.reader_id) + (x.is_default ? ` (${t('su_default_badge')})` : ''), selected: st.selected === x.reader_id || null })));
      kids.push(h('label', { class: 'fld' }, h('span', { text: t('su_reader') }), sel));
      const cur = st.readers.find((x) => x.reader_id === st.selected);
      if (cur) {
        kids.push(h('div', { class: 'row-actions' },
          h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'set-sumup-default', text: t('su_default'), disabled: st.busy || cur.is_default || null,
            onclick: () => act(async () => { await rpc('admin_sumup_reader_set_default', { p_reader_id: cur.reader_id }); toast(t('su_default_set')); }) }),
          h('button', { type: 'button', class: 'btn ghost', 'data-testid': 'set-sumup-remove', text: t('su_remove'), disabled: st.busy || null,
            onclick: () => act(async () => { await rpc('admin_sumup_reader_remove', { p_reader_id: cur.reader_id }); toast(t('su_removed')); }) })));
      }
      if (!st.readers.some((x) => x.is_default)) kids.push(h('p', { class: 'err', role: 'alert', 'data-testid': 'set-sumup-no-default', text: t('su_no_default') }));
    } else kids.push(h('p', { 'data-testid': 'set-sumup-none', text: t('su_no_readers') }));
    const code = h('input', { type: 'text', maxlength: '12', autocomplete: 'off', autocapitalize: 'characters', value: st.pairCode, 'data-testid': 'set-sumup-pair-code' });
    code.addEventListener('input', () => { st.pairCode = String(code.value || ''); });
    const name = h('input', { type: 'text', maxlength: '60', value: st.pairName, 'data-testid': 'set-sumup-pair-name' });
    name.addEventListener('input', () => { st.pairName = String(name.value || ''); });
    kids.push(h('h3', { text: t('su_pair_title') }),
      h('label', { class: 'fld' }, h('span', { text: t('su_pair_code') }), code),
      h('label', { class: 'fld' }, h('span', { text: t('su_pair_name') }), name),
      h('button', { type: 'button', class: 'btn', 'data-testid': 'set-sumup-pair', text: t('su_pair'), disabled: st.busy || null, onclick: () => {
        if (!validPairingCode(st.pairCode)) { toast(t('su_pair_invalid'), 'err'); return; }
        act(async () => {
          const r = await callFn('sumup-pos', { action: 'reader_pair', pairing_code: normalizePairingCode(st.pairCode), name: st.pairName || t('su_reader') });
          st.pairCode = ''; st.pairName = '';
          if (r?.reader_id) st.selected = r.reader_id;
          toast(t('su_pair_done'));
        });
      } }));
    root.replaceChildren(...kids);
  }

  if (!ctx?.can?.('settings.edit')) return null;
  draw();
  loadPosTexts(rpc).catch(() => {}).then(load).then(draw);
  return root;
}
