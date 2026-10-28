// Optional, mobile-first upsell UI. All visible copy is loaded from ui.upsell.* site_texts.
import { createTexts, loadShopTexts } from './site-texts.js';
import { storageUrl } from './sb.js';
import { productImageElement, CARD_WIDTHS, SIZES, catalogImageUrl } from './product-image.js';
import { richHost } from './rich-view.js';
import { needsOption, optName, optLabel } from './options-logic.js';
import { candidates, visitDate, rankSlots, excerpt, productName, stripNameHeading, durationText, personsText, mergeFacts } from './upsell-logic.js';

const h = (tag, props = {}, ...children) => {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (value === undefined || value === null || value === false) continue;
    if (key === 'text') el.textContent = value;
    else if (key === 'class') el.className = value;
    else if (key.startsWith('on')) el.addEventListener(key.slice(2), value);
    else if (value === true) el.setAttribute(key, '');
    else el.setAttribute(key, String(value));
  }
  for (const kid of children.flat(Infinity)) if (kid != null && kid !== false) el.append(kid.nodeType ? kid : document.createTextNode(kid));
  return el;
};
let cachedTexts;
async function strings(S, L) {
  cachedTexts ||= loadShopTexts(S.siteTextsUrl);
  const tx = createTexts({ lang: L, rows: await cachedTexts });
  return (key) => tx.tx(`ui.upsell.${key}`) || '';
}
const money = (price, lang) => new Intl.NumberFormat(lang === 'en' ? 'en-GB' : 'fi-FI', { style: 'currency', currency: 'EUR' }).format(+price || 0);
const clock = (iso, lang) => new Intl.DateTimeFormat(lang === 'en' ? 'en-GB' : 'fi-FI', { timeZone: 'Europe/Helsinki', hour:'2-digit',minute:'2-digit',hourCycle:'h23' }).format(new Date(iso));
const uid = () => { try { return crypto.randomUUID(); } catch { return '00000000-0000-4000-8000-000000000001'; } };
const sourceSession = uid();
const track = (rpc, source, p, event) => rpc('public_upsell_event', { p_session_id:sourceSession, p_source:source, p_product_id:p.product_id, p_event:event, p_origin:p.origin || null }).catch(()=>{});
const trackAddon=(rpc,source,a,event)=>rpc('public_upsell_event',{p_session_id:sourceSession,p_source:source,p_product_id:a.origin,p_event:event,p_origin:a.origin,p_addon_id:a.addon_id}).catch(()=>{});

function image(product, alt = '', preset = 'upsell') {
  const raw = product.image_url || (product.image_path ? storageUrl('product-images', product.image_path) : '');
  const src = raw ? catalogImageUrl(raw, { path: product.image_path, updated_at: product.updated_at || product.image_updated_at }) : '';
  if (!src) return null;
  const sizes = preset === 'sheet' ? SIZES.sheet : SIZES.upsell;
  const node = productImageElement(h, src, { widths: CARD_WIDTHS, sizes, alt, width: 900, height: 600, lazy: true });
  const im = node.querySelector('img');
  im.addEventListener('error', () => node.remove(), { once: true });
  return node;
}
function optionChoices(p) {
  return (Array.isArray(p?.options) ? p.options : []).filter((o) => o && o.active !== false && (o.id != null || o.code));
}
function optionExtra(o, L) {
  const n = +o?.price_delta;
  if (!Number.isFinite(n) || n === 0) return '';
  return ` ${n > 0 ? '+' : '−'}${money(Math.abs(n), L)}`;
}
function optionPicker(p, t, L, onPick) {
  if (!needsOption(p)) return null;
  const choices = optionChoices(p);
  const label = optLabel(p, L, t('choose_option'));
  let current = null;
  const buttons = [];
  const group = h('div', { class: 'bk-upsell-opts', role: 'group', 'aria-label': label || t('choose_option'), 'data-testid': `upsell-opts-${p.product_id}` });
  for (const o of choices) {
    const b = h('button', { type: 'button', class: 'bk-upsell-opt', 'aria-pressed': 'false', 'data-testid': `upsell-opt-${p.product_id}-${o.id ?? o.code}`, onclick: () => {
      current = o;
      buttons.forEach((x) => x.setAttribute('aria-pressed', x === b ? 'true' : 'false'));
      onPick(current);
    } }, `${optName(o, L)}${optionExtra(o, L)}`);
    buttons.push(b);
  }
  group.append(...buttons);
  const node = h('div', {}, label ? h('p', { class: 'bk-upsell-optlabel', text: label }) : null, group);
  return { node, get: () => current };
}
function moreButton(p, t, L, testid, onMore) {
  const label = t('read_more');
  if (!label) return null;
  const name = productName(p, L);
  return h('button', { type:'button', class:'bk-upsell-more', 'data-testid':testid, 'aria-haspopup':'dialog', 'aria-label': name ? `${label}: ${name}` : label, onclick:(e) => { e.preventDefault(); e.stopPropagation(); onMore(e.currentTarget); } }, label);
}
function card(p, t, L, onOpen, onMore) {
  const name = productName(p, L);
  const blurb = excerpt(p, L, 105, true);
  const price = `${t('from')} ${money(p.price_from ?? p.price, L)}`;
  const opener = h('button', { type:'button', class:'bk-upsell-open', 'data-testid':`upsell-card-${p.product_id}`, 'aria-label':`${name}. ${price}`, onclick:onOpen },
    image(p), h('strong', { text:name }));
  const priceBtn = h('button', { type:'button', class:'bk-upsell-open bk-upsell-price-hit', tabindex:'-1', 'aria-hidden':'true', onclick:onOpen }, h('span', { class:'bk-upsell-price', text:price }));
  const more = moreButton(p, t, L, `upsell-more-${p.product_id}`, onMore);
  return h('div', { class:'bk-upsell-card' }, opener,
    h('div', { class:'bk-upsell-info' },
      blurb || more ? h('p', { class:'bk-upsell-blurb' }, blurb ? h('span', { class:'bk-upsell-clamp', text:blurb }) : null, more) : null,
      priceBtn));
}

const layers = [];
let scrollLocks = 0;
let savedOverflow = '';
function lockScroll(on) {
  if (typeof document === 'undefined') return;
  if (on) { if (scrollLocks++ === 0) { savedOverflow = document.body.style.overflow; document.body.style.overflow = 'hidden'; } }
  else if (scrollLocks > 0 && --scrollLocks === 0) document.body.style.overflow = savedOverflow;
}
function focusables(panel) {
  return [...panel.querySelectorAll('button:not([disabled]), a[href], input:not([disabled]), select:not([disabled]), textarea:not([disabled])')]
    .filter((el) => !el.hasAttribute('disabled') && el.getAttribute('tabindex') !== '-1' && el.getAttribute('aria-hidden') !== 'true');
}
function bindLayer(overlay, panel, before) {
  const layer = { panel };
  const onKey = (e) => {
    if (layers.at(-1) !== layer) return;
    if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); exit(); return; }
    if (e.key !== 'Tab') return;
    const list = focusables(panel);
    if (!list.length) { e.preventDefault(); panel.focus({ focusVisible: false }); return; }
    const i = list.indexOf(document.activeElement);
    if (e.shiftKey) { if (i <= 0) { e.preventDefault(); list.at(-1).focus(); } }
    else if (i === -1 || i === list.length - 1) { e.preventDefault(); list[0].focus(); }
  };
  const exit = () => {
    const i = layers.indexOf(layer);
    if (i >= 0) layers.splice(i, 1);
    document.removeEventListener('keydown', onKey, true);
    overlay.remove();
    lockScroll(false);
    if (before && document.contains(before)) before.focus();
  };
  layers.push(layer);
  document.addEventListener('keydown', onKey, true);
  lockScroll(true);
  return exit;
}

function factRow(label, value) {
  if (!label || !value) return null;
  return h('div', {}, h('dt', { text:label }), h('dd', { text:value }));
}
// Information only. Time buttons stay on the page; this dialog never books.
function productInfo({ p, t, L, before, choice }) {
  const name = productName(p, L);
  const headingId = `upsell-info-${p.product_id}`;
  const overlay = h('div', { class:'bk-upsell-backdrop bk-upsell-detail-backdrop', 'data-testid':'upsell-info-backdrop' });
  const closeBtn = h('button', { type:'button', class:'bk-upsell-x', 'aria-label':t('close') || '×', 'data-testid':'upsell-info-close', text:'×' });
  const panel = h('section', { class:'bk-upsell-sheet bk-upsell-detail', role:'dialog', 'aria-modal':'true', 'aria-labelledby':headingId, tabindex:'-1', 'data-testid':'upsell-info' });
  const exit = bindLayer(overlay, panel, before || document.activeElement);
  closeBtn.addEventListener('click', exit);
  overlay.addEventListener('click', (e) => { if (e.target === overlay) exit(); });
  const price = (p.price_from ?? p.price) != null && Number.isFinite(+(p.price_from ?? p.price)) ? money(p.price_from ?? p.price, L) : '';
  const optionNames = optionChoices(p).map((o) => optName(o, L)).filter(Boolean).join(', ');
  const facts = h('dl', { class:'bk-upsell-facts' },
    factRow(t('duration'), durationText(p, L)),
    factRow(t('from'), price),
    factRow(t('persons'), personsText(p)),
    factRow(t('option'), choice ? optName(choice, L) : (needsOption(p) ? optionNames : '')));
  if (!facts.childElementCount) facts.remove();
  const html = stripNameHeading((L === 'en' && p.description_en) || p.description || '', name);
  const body = html.trim()
    ? richHost(h, html, 'bk-upsell-desc')
    : (excerpt(p, L, 4000, true) ? h('p', { class:'bk-upsell-desc', text:excerpt(p, L, 4000, true) }) : null);
  const photo = image(p, p.image_alt || '', 'sheet');
  if (photo) photo.classList.add('bk-upsell-photo');
  panel.append(...[photo, h('header', { class:'bk-upsell-sheet-head' }, h('h3', { id:headingId, text:name }), closeBtn), facts.childElementCount ? facts : null, body ? h('div', { class:'bk-upsell-body' }, body) : null].filter(Boolean));
  overlay.append(panel);
  document.body.append(overlay);
  closeBtn.focus();
}

let staticCache;
function staticMap(S) {
  if (!S?.staticProductsUrl || typeof fetch !== 'function') return Promise.resolve(null);
  staticCache ||= fetch(S.staticProductsUrl).then((r) => r.ok ? r.json() : null).catch(() => null);
  return staticCache;
}
function staticRow(map, p) {
  if (!map || typeof map !== 'object') return null;
  if (p.slug && map[p.slug]) return map[p.slug];
  return Object.values(map).find((x) => x && +x.id === +p.product_id) || null;
}
let catalogCache;
function catalogRows(rpc) {
  if (!rpc) return Promise.resolve([]);
  catalogCache ||= Promise.resolve(rpc('public_catalog', {})).then((rows) => Array.isArray(rows) ? rows : []).catch(() => []);
  return catalogCache;
}
function factComplete(p) {
  return !!(durationText(p, 'fi') || p.duration_minutes) && !!personsText(p) && !!(p.description || p.description_en || p.short_description || p.short_description_en);
}
function withProductOptions(full, source) {
  const options = optionChoices(full).length ? full.options : source?.options;
  return { ...full, options, option_required: full.option_required ?? source?.option_required, option_label: full.option_label || source?.option_label || null, option_label_en: full.option_label_en || source?.option_label_en || null };
}
async function resolveProduct(p, { S, rpc, details }) {
  let merged = mergeFacts(p, typeof details === 'function' ? details(p.product_id) : null);
  if (factComplete(merged)) return merged;
  merged = mergeFacts(merged, staticRow(await staticMap(S), merged));
  if (factComplete(merged)) return merged;
  const rows = await catalogRows(rpc);
  return mergeFacts(merged, rows.find((r) => +r.id === +merged.product_id));
}

function bottomSheet({ p, t, L, slots, onChoose, onMore }) {
  const before = document.activeElement;
  const overlay = h('div', { class:'bk-upsell-backdrop' });
  const headingId = `upsell-heading-${p.product_id}`;
  const closeBtn = h('button', { type:'button', class:'btn light', 'aria-label':t('close'), text:t('close') });
  const panel = h('section', { class:'bk-upsell-sheet', role:'dialog', 'aria-modal':'true', 'aria-labelledby':headingId, tabindex:'-1' });
  const exit = bindLayer(overlay, panel, before);
  closeBtn.addEventListener('click', exit);
  overlay.addEventListener('click', (e) => { if (e.target === overlay) exit(); });
  const desc = excerpt(p, L, 350, false);
  const required = needsOption(p);
  const picker = optionPicker(p, t, L, () => { chips.querySelectorAll('button').forEach((b) => { b.disabled = false; }); });
  const chips = h('div', { class:'bk-upsell-chips', role:'group', 'aria-label':t('choose_time') }, slots.map((slot) => {
    const hint = slot.fit ? t(slot.fit === 'before' ? 'before' : 'after') : '';
    const b = h('button', { type:'button', class:'bk-upsell-chip', 'aria-label':`${clock(slot.start, L)} ${hint}`, disabled: required || undefined, onclick:async () => {
      if (required && !picker?.get()) return;
      b.disabled = true;
      const ok = await onChoose(slot, picker?.get() || null);
      if (ok) exit(); else b.disabled = false;
    } }, h('strong', { text:clock(slot.start, L) }), hint ? h('small', { text:hint }) : null);
    return b;
  }));
  const more = moreButton(p, t, L, `upsell-sheet-more-${p.product_id}`, (from) => onMore(from, picker?.get() || null));
  panel.append(...[h('header', { class:'bk-upsell-sheet-head' }, h('h3', { id:headingId, text:productName(p, L) }), closeBtn),
    h('p', { class:'bk-upsell-desc' }, desc ? h('span', { text:desc }) : null, desc && more ? ' ' : null, more),
    picker?.node || null, h('h4', { text:t('choose_time') }), chips].filter(Boolean));
  overlay.append(panel);
  document.body.append(overlay);
  closeBtn.focus();
}

const addonTaken = (order, id) => {
  if ((order.items || []).some(i => i.addon_id != null && +i.addon_id === +id)) return true;
  return (order.reservations || []).some(r => (r.addons || []).some(a => a.addon_id != null && +a.addon_id === +id));
};
export function confirmationUpsellOrder(b) {
  return {
    status: b?.status, payment_status: b?.payment_status,
    reservations: (b?.items || []).filter(x => x?.starts_at && x.product_id).map(x => ({
      product_id: x.product_id, starts_at: x.starts_at, ends_at: x.ends_at, status: x.status, reservation_id: x.reservation_id ?? null,
    })),
    items: (b?.addons || []).filter(a => a?.addon_id != null).map(a => ({ addon_id: a.addon_id })),
  };
}
export function orderUpsellSection({ S,L,token,order,rpc,onAdded,details }) {
  const section=h('section',{class:'ord-card bk-upsell','data-testid':'upsell-confirmation',hidden:true});
  const showInfo = (p, from, choice) => { resolveProduct(p, { S, rpc, details }).then((full) => productInfo({ p: withProductOptions(full, p), t, L, before:from, choice })); };
  let t = () => '';
  (async()=>{
    t=await strings(S,L);if(!t('title'))return;
    const data=await rpc('public_upsell_for_order',{p_token:token}).catch(()=>null); if(!data)return;
    const reservations=order?.reservations||[];
    const existing=reservations.filter(r=>r.status!=='cancelled').map(r=>r.product_id);
    const rows=candidates(data,existing,9);
    const day=visitDate(reservations.find(r=>r.status!=='cancelled')?.starts_at);
    const usable=rows.map(p=>({...p,slots:rankSlots(p.slots,reservations,day)})).filter(p=>p.slots.length);
    const addons=(data.addons||[]).filter(a=>a.addon_id&&!addonTaken(order,a.addon_id));
    if(!usable.length&&!addons.length)return;
    const feedback=h('p',{class:'bk-upsell-feedback',role:'status','aria-live':'polite'});
    const cards=usable.map(p=>card(p,t,L,()=>{
      track(rpc,'confirmation',p,'opened');
      bottomSheet({p,t,L,slots:p.slots,onMore:(from, choice)=>showInfo(p, from, choice),onChoose:async(slot, opt)=>{
        if(needsOption(p)&&!opt?.code){feedback.textContent=t('choose_option');return false;}
        const item={type:'reservation',product_id:p.product_id,persons:1,start:slot.start};
        if(opt?.code)item.option_code=String(opt.code);
        const result=await rpc('public_upsell_add',{p_token:token,p_item:item,p_session_id:sourceSession,p_origin:p.origin||null}).catch(()=>null);
        if(!result?.ok){feedback.textContent=result?.code==='option_required'||result?.code==='invalid_option'?t('choose_option'):t('no_longer_available');return false;}
        feedback.textContent=t('added');await onAdded();return true;
      }});
    }, (from)=>showInfo(p, from)));
    const addonButtons=addons.map(a=>h('button',{type:'button',class:'btn light bk-upsell-addon',onclick:async(e)=>{
      const res=(order.reservations||[]).find(r=>+r.product_id===+a.origin&&!['cancelled','expired'].includes(r.status));
      const item={type:'addon',addon_id:a.addon_id,quantity:1};
      if(res?.reservation_id)item.reservation_id=res.reservation_id;
      e.currentTarget.disabled=true;trackAddon(rpc,'confirmation',a,'opened');
      const out=await rpc('public_upsell_add',{p_token:token,p_item:item,p_session_id:sourceSession,p_origin:a.origin}).catch(()=>null);
      if(out?.ok){feedback.textContent=t('added');await onAdded();} else {feedback.textContent=t('no_longer_available');e.currentTarget.disabled=false;}
    }},`${(L==='en'&&a.name_en)||a.name} · ${money(a.price,L)}`));
    addons.forEach(a=>trackAddon(rpc,'confirmation',a,'shown'));
    section.append(...[h('h3',{text:t('title')}),h('p',{class:'bk-note',text:t('lead')}),
      h('div',{class:'bk-upsell-row'},cards),addonButtons.length?h('div',{class:'bk-upsell-addon-row'},addonButtons):null,
      order.payment_status==='paid'?null:h('p',{class:'bk-note',text:t('pay_separately')}),feedback].filter(Boolean));
    section.hidden=false;usable.slice(0,3).forEach(p=>track(rpc,'confirmation',p,'shown'));
  })().catch(()=>{});
  return section;
}

export function checkoutUpsellSection({S,L,productId,date,visitStart,persons,rpc,addons,onChange,details}) {
  const section=h('section',{class:'bk-section bk-upsell','data-testid':'upsell-checkout',hidden:true});
  const selected=new Map();const picked=new Map();let t=()=>'';let addonIds=new Set();
  const showInfo = (p, from) => { resolveProduct(p, { S, rpc, details }).then((full) => productInfo({ p: withProductOptions(full, p), t, L, before:from, choice: picked.get(p.product_id) || null })); };
  const reset=()=>{selected.clear();picked.clear();section.querySelectorAll('[aria-pressed]')?.forEach(b=>b.setAttribute('aria-pressed','false'));section.querySelectorAll('.bk-upsell-chip').forEach(b=>{if(b.dataset.needsOption==='1')b.disabled=true;});onChange?.();};
  (async()=>{
    t=await strings(S,L);if(!t('checkout_title'))return;
    const data=await rpc('public_upsell_suggestions',{p_product_ids:[productId],p_date:date,p_persons:1,p_visit_start:visitStart}).catch(()=>null);if(!data)return;
    const slots=(data.products||[]).filter(p=>p.suggested).map(p=>({...p,slots:rankSlots(p.slots,[],date)})).filter(p=>p.slots.length).slice(0,3);
    const addonOffers=(data.addons||[]).filter(a=>addons.some(x=>+x.id===+a.addon_id));addonIds=new Set(addonOffers.map(a=>+a.addon_id));
    if(!slots.length&&!addonOffers.length)return;
    const row=h('div',{class:'bk-upsell-row'});
    for(const p of slots){
      const pane=h('div',{class:'bk-upsell-inline',id:`upsell-pane-${p.product_id}`,hidden:true});
      const wrap=card(p,t,L,()=>{
        pane.hidden=!pane.hidden;
        opener.setAttribute('aria-expanded',String(!pane.hidden));
        track(rpc,'checkout',p,'opened');
      }, (from)=>showInfo(p, from));
      const opener=wrap.querySelector('.bk-upsell-open');
      opener.setAttribute('aria-expanded','false');
      opener.setAttribute('aria-controls', pane.id);
      const required=needsOption(p);
      const picker=optionPicker(p,t,L,(opt)=>{
        picked.set(p.product_id,opt);
        chipRow.querySelectorAll('button').forEach(b=>{b.disabled=false;});
        const cur=selected.get(p.product_id);
        if(cur&&opt?.id!=null){cur.option_id=+opt.id;onChange?.();}
      });
      const chipRow=h('div',{class:'bk-upsell-chips',role:'group','aria-label':t('choose_time')});
      for(const slot of p.slots){
        const b=h('button',{type:'button',class:'bk-upsell-chip','aria-pressed':'false','data-needs-option':required?'1':null,disabled:required||undefined,onclick:()=>{
          const opt=picked.get(p.product_id);
          if(required&&!opt)return;
          const cur=selected.get(p.product_id);
          if(cur&&cur.start===slot.start){selected.delete(p.product_id);b.setAttribute('aria-pressed','false');}
          else {
            selected.clear();section.querySelectorAll('.bk-upsell-chip').forEach(x=>x.setAttribute('aria-pressed','false'));
            const item={product_id:p.product_id,start:slot.start,persons:1,total:+slot.total||0};
            if(opt?.id!=null)item.option_id=+opt.id;
            selected.set(p.product_id,item);b.setAttribute('aria-pressed','true');
          }
          onChange?.();
        }},clock(slot.start,L));chipRow.append(b);
      }
      const lead=excerpt(p,L,180,false);
      pane.append(...[h('p',{class:'bk-upsell-lead'}, lead?h('span',{text:lead}):null, lead?' ':null, moreButton(p,t,L,`upsell-intro-more-${p.product_id}`,(from)=>showInfo(p, from))), picker?.node||null, chipRow].filter(Boolean));
      row.append(h('div',{class:'bk-upsell-cell'},wrap,pane));
      track(rpc,'checkout',p,'shown');
    }
    for(const a of addonOffers){
      const match=addons.find(x=>+x.id===+a.addon_id);
      if(!match)continue;
      trackAddon(rpc,'checkout',a,'shown');
      row.append(h('button',{type:'button',class:'bk-upsell-addon',onclick:()=>{trackAddon(rpc,'checkout',a,'opened');
        const qty=document.getElementById(`bk-a-${a.addon_id}`);
        if(qty){qty.value=Math.max(1,+qty.value||0);qty.dispatchEvent(new Event('change',{bubbles:true}));qty.focus();}
      }},`${(L==='en'&&a.name_en)||a.name} · ${money(a.price,L)}`));
    }
    section.append(h('h3',{text:t('checkout_title')}),row);section.hidden=false;
  })().catch(()=>{});
  return {node:section,items:()=>[...selected.values()].map(({total,...item})=>{if(item.option_id==null)delete item.option_id;return item;}),total:()=>[...selected.values()].reduce((sum,x)=>sum+x.total,0),hasSuggestedAddon:items=>(items||[]).some(x=>addonIds.has(+x.id)),session:sourceSession,reset,text:(key)=>t(key)};
}
