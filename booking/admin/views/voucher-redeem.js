// booking_173: kumppanilahjakortin lunastus hallinnassa. Sama rivi tilauksen/varauksen ikkunassa (orderVoucherBox) ja Tarkista-sivulla (unredeemedSection).
// Rivi: asiakkaan antama koodi + Kopioi, järjestelmän arvaus ja asiakkaan valinta erikseen nimettyinä, myyjän vaihto (audit; maksutapa ja Procountor-tili seuraavat),
// Lunasta (myyjän sivu uuteen välilehteen, osoite asetuksista) ja Merkitse lunastetuksi (kaksivaiheinen vahvistus, idempotentti palvelimella).
import { h, toast, run, badge, money, fmtDT, errMsg } from '../ui.js';
import { icon } from '../icons.js';
import { vcrText as vt, loadVcrTexts } from '../voucher-redeem-texts.js';
import { VCR_CHOICES, VCR_RPC, sellerLabel, safeRedeemUrl, guessDiffers, groupBySource, filterChips, orderHref, reservationHref, setSourceArgs, markArgs } from '../voucher-redeem-logic.js';

const errText = (e) => (e?.code && ['invalid_state', 'forbidden', 'unchanged'].includes(e.code) ? vt(`ui.admin.vcr.err_${e.code}`) : errMsg(e));
const conf = (c) => (['high', 'medium', 'low'].includes(c) ? vt(`ui.admin.vcr.conf_${c}`) : null);
const methodOf = (row) => String(row.payment_method_label || '').trim() || vt('ui.admin.vcr.method');
const amountOf = (row) => (row.unpaid != null && Number(row.unpaid) > 0 ? row.unpaid : row.voucher_value ?? row.amount ?? null);

async function copyCode(code, el) {
  try {
    await globalThis.navigator.clipboard.writeText(code);
    toast(vt('ui.admin.vcr.copied'));
  } catch {
    try { const r = globalThis.document.createRange(); r.selectNodeContents(el); const s = globalThis.getSelection(); s.removeAllRanges(); s.addRange(r); } catch { /* ei valintaa */ }
    toast(vt('ui.admin.vcr.copy_failed'), 'warn');
  }
}

/** Yksi lahjakorttirivi. opts: { rpc, canManage, showOrder, onChanged } */
export function claimRow(row, { rpc, canManage = false, showOrder = true, onChanged = () => {} } = {}) {
  const code = String(row.code || row.code_masked || '');
  const codeEl = h('code', { class: 'vcr-code', 'data-testid': 'vcr-code', text: code });
  const copy = h('button', { type: 'button', class: 'btn sm', 'data-testid': 'vcr-copy', 'aria-label': `${vt('ui.admin.vcr.copy')} ${code}`, onclick: () => copyCode(code, codeEl) }, icon('copy', 16), h('span', { text: vt('ui.admin.vcr.copy') }));
  const guessTxt = row.source_suggested ? [sellerLabel(row.source_suggested, row.source_suggested_label), conf(row.suggestion_confidence)].filter(Boolean).join(' · ') : vt('ui.admin.vcr.no_guess');
  const guess = h('span', { class: 'vcr-kv', 'data-testid': 'vcr-guess' }, h('span', { class: 'vcr-k', text: `${vt('ui.admin.vcr.guess')}:` }), ' ', h('strong', { text: guessTxt }));
  const open = ['open', 'processing', 'problem'].includes(row.status);
  const editable = canManage && open && row.can_change_source !== false;
  let choice;
  if (editable) {
    const opts = [...VCR_CHOICES];
    if (row.source && !opts.includes(row.source)) opts.push(row.source);
    const sel = h('select', { class: 'vcr-sel', 'data-testid': 'vcr-source', 'aria-label': `${vt('ui.admin.vcr.change_seller')} ${code}` },
      opts.map((s) => h('option', { value: s, text: VCR_CHOICES.includes(s) ? sellerLabel(s) : `${sellerLabel(s, s === row.source ? row.source_label : null)} (${vt('ui.admin.vcr.legacy')})` })));
    sel.value = row.source || '';
    sel.addEventListener('change', () => run(sel, async () => {
      const want = sel.value;
      try {
        await rpc(VCR_RPC.setSource, setSourceArgs(row, want));
        toast(vt('ui.admin.vcr.seller_saved', { source: sellerLabel(want) }));
        onChanged();
      } catch (e) { sel.value = row.source || ''; toast(errText(e), 'err'); }
    }));
    choice = h('label', { class: 'vcr-kv', 'data-testid': 'vcr-choice' }, h('span', { class: 'vcr-k', text: `${vt('ui.admin.vcr.choice')}:` }), ' ', sel);
  } else {
    choice = h('span', { class: 'vcr-kv', 'data-testid': 'vcr-choice' }, h('span', { class: 'vcr-k', text: `${vt('ui.admin.vcr.choice')}:` }), ' ', h('strong', { text: sellerLabel(row.source, row.source_label) }));
  }
  const differs = guessDiffers(row) ? h('p', { class: 'vcr-warn', role: 'note', 'data-testid': 'vcr-differs', text: vt('ui.admin.vcr.differs') }) : null;
  const amt = amountOf(row);
  const meta = h('p', { class: 'vcr-meta muted' }, ...[
    showOrder && row.order_no ? h('a', { href: orderHref(row.order_no), 'data-testid': 'vcr-order-link', text: vt('ui.admin.vcr.order', { no: row.order_no }) }) : null,
    showOrder && row.starts_at ? h('a', { href: reservationHref(row), 'data-testid': 'vcr-res-link', text: vt('ui.admin.vcr.reservation', { when: fmtDT(row.starts_at) }) }) : null,
    showOrder && row.product_name ? h('span', { text: String(row.product_name) }) : null,
    showOrder && row.customer_name ? h('span', { text: String(row.customer_name) }) : null,
    amt != null ? h('span', { 'data-testid': 'vcr-amount', text: `${vt('ui.admin.vcr.amount')} ${money(amt)}` }) : null,
    h('span', { 'data-testid': 'vcr-method', text: `${vt('ui.admin.vcr.method')}: ${methodOf(row)}` }),
  ].filter(Boolean).flatMap((x, i) => (i ? [' · ', x] : [x])));
  const actions = h('div', { class: 'vcr-actions' });
  const confirmBox = h('div', { class: 'vcr-confirm', hidden: true, 'data-testid': 'vcr-confirm' });
  if (open) {
    const url = safeRedeemUrl(row.redeem_url);
    actions.append(url
      ? h('a', { class: 'btn sm', href: url, target: '_blank', rel: 'noopener noreferrer', title: vt('ui.admin.vcr.redeem_title'), 'data-testid': 'vcr-redeem' }, icon('external', 16), h('span', { text: vt('ui.admin.vcr.redeem', { source: sellerLabel(row.source, row.source_label) }) }))
      : h('span', { class: 'muted vcr-nourl', 'data-testid': 'vcr-no-url', text: vt('ui.admin.vcr.no_url') }));
    if (canManage && row.can_redeem !== false) {
      const mark = h('button', { type: 'button', class: 'btn sm primary', 'data-testid': 'vcr-mark' }, icon('check', 16), h('span', { text: vt('ui.admin.vcr.mark') }));
      mark.addEventListener('click', () => {
        const yes = h('button', { type: 'button', class: 'btn sm primary', 'data-testid': 'vcr-mark-yes', text: vt('ui.admin.vcr.mark_yes') });
        const no = h('button', { type: 'button', class: 'btn sm ghost', 'data-testid': 'vcr-mark-no', text: vt('ui.admin.vcr.cancel'), onclick: () => { confirmBox.hidden = true; mark.hidden = false; mark.focus(); } });
        yes.addEventListener('click', () => run(yes, async () => {
          try {
            const res = await rpc(VCR_RPC.markRedeemed, markArgs(row));
            toast(res?.already ? vt('ui.admin.vcr.already') : vt('ui.admin.vcr.marked', { method: String(res?.payment_method_label || methodOf(row)), amount: money(res?.amount ?? amt) }));
            onChanged();
          } catch (e) { toast(errText(e), 'err'); }
        }));
        confirmBox.replaceChildren(h('p', { text: vt('ui.admin.vcr.mark_confirm', { amount: money(amt), method: methodOf(row) }) }), h('div', { class: 'row wrap' }, yes, no));
        confirmBox.hidden = false; mark.hidden = true; yes.focus();
      });
      actions.append(mark);
    }
  } else if (row.status === 'redeemed') {
    const by = row.redeemed_via || row.resolved_by;
    actions.append(badge('pay-paid', [vt('ui.admin.vcr.redeemed', { when: row.resolved_at ? fmtDT(row.resolved_at) : '' }).trim(), ['staff', 'bot'].includes(by) ? `(${vt(`ui.admin.vcr.by_${by}`)})` : null].filter(Boolean).join(' ')));
  }
  return h('div', { class: 'vcr-row', 'data-testid': 'vcr-row', 'data-claim-id': String(row.id), 'data-source': String(row.source || ''), 'data-status': String(row.status || '') },
    h('div', { class: 'vcr-line' }, codeEl, copy),
    h('div', { class: 'vcr-line vcr-src' }, guess, choice),
    differs, meta, actions, confirmBox);
}

/** Tilauksen/varauksen ikkunan laatikko. null jos tilauksella ei ole kumppanilahjakortteja tai rajapintaa ei ole. */
export async function orderVoucherBox({ rpc, orderId, onChanged = () => {} }) {
  if (!orderId) return null;
  await loadVcrTexts(rpc);
  let v; try { v = await rpc(VCR_RPC.order, { p_order_id: orderId }); } catch { return null; }
  const claims = Array.isArray(v?.claims) ? v.claims : [];
  if (!claims.length) return null;
  const canManage = v.can_manage === true;
  return h('div', { class: 'box vcr-box', 'data-testid': 'vcr-order-box' },
    h('h3', {}, icon('gift', 20), ' ', vt('ui.admin.vcr.box_title')),
    canManage ? null : h('p', { class: 'muted', text: vt('ui.admin.vcr.no_right') }),
    ...claims.map((c) => claimRow(c, { rpc, canManage, showOrder: false, onChanged })));
}

/** Tarkista-sivun osio: lunastamattomat, suodatus myyjän mukaan, ryhmittely myyjittäin. */
export async function unredeemedSection({ rpc }) {
  await loadVcrTexts(rpc);
  const st = { source: null };
  const body = h('div', { class: 'vcr-body', 'aria-live': 'polite' });
  const countBadge = badge('ok', '0');
  const chipsEl = h('div', { class: 'vcr-chips', role: 'group', 'aria-label': vt('ui.admin.vcr.filter_label'), 'data-testid': 'vcr-filter' });
  const sec = h('section', { class: 'card review-sec vcr-sec', 'data-testid': 'review-unredeemed_vouchers', 'data-count': '0' },
    h('h2', {}, vt('ui.admin.vcr.section_title'), ' ', countBadge), h('p', { class: 'muted', text: vt('ui.admin.vcr.section_hint') }), chipsEl, body);
  const load = async () => {
    let v;
    try { v = await rpc(VCR_RPC.unredeemed, st.source ? { p_source: st.source } : {}); } catch (e) {
      body.replaceChildren(h('p', { class: 'err', role: 'alert', text: vt('ui.admin.vcr.load_failed', { error: errMsg(e) }) }));
      return;
    }
    const claims = Array.isArray(v?.claims) ? v.claims : [];
    const total = Number(v?.total) || Object.values(v?.counts || {}).reduce((s, n) => s + (Number(n) || 0), 0);
    countBadge.textContent = String(total); countBadge.className = `badge ${total ? 'warn' : 'ok'}`;
    sec.dataset.count = String(total); sec.classList.toggle('has', total > 0);
    chipsEl.replaceChildren(...filterChips(v?.counts, st.source).map((c) => h('button', {
      type: 'button', class: `btn sm vcr-chip${c.active ? ' on' : ''}`, 'aria-pressed': c.active ? 'true' : 'false', 'data-testid': `vcr-chip-${c.source || 'all'}`,
      onclick: () => { st.source = c.source; load(); },
    }, `${c.source ? sellerLabel(c.source) : vt('ui.admin.vcr.filter_all')} (${c.n})`)));
    if (!claims.length) { body.replaceChildren(h('p', { class: 'empty', text: vt('ui.admin.vcr.empty') })); return; }
    const canManage = v.can_manage === true;
    const rowOpts = { rpc, canManage, showOrder: true, onChanged: load };
    body.replaceChildren(canManage ? '' : h('p', { class: 'muted', text: vt('ui.admin.vcr.no_right') }),
      ...groupBySource(claims).map((g) => h('div', { class: 'vcr-group', 'data-testid': `vcr-group-${g.source}` },
        h('h3', { text: `${sellerLabel(g.source, g.claims[0]?.source_label)} (${g.claims.length})` }),
        ...g.claims.map((c) => claimRow(c, rowOpts)))));
  };
  await load();
  return sec;
}
