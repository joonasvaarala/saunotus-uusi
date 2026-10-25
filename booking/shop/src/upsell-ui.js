// Optional, mobile-first upsell UI. All visible copy is loaded from ui.upsell.* site_texts.
import { createTexts, loadShopTexts } from './site-texts.js';
import { storageUrl } from './sb.js';
import { candidates, visitDate, rankSlots, shortPlain, safeSlug } from './upsell-logic.js';

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
const urlFor = (S, slug) => {
  const s = safeSlug(slug); if (!s || !S.shopHref) return '';
  const u = new URL(S.shopHref, location.href); u.hash = `#/tuote/${s}`; return u.href;
};
function image(product) {
  if (!product.image_path) return null;
  const img = h('img', { src:storageUrl('product-images',product.image_path), alt:'', loading:'lazy', decoding:'async' });
  img.addEventListener('error',()=>img.remove(),{once:true});
  return img;
}
function card(p,t,L,onOpen) {
  return h('button',{type:'button',class:'bk-upsell-card','data-testid':`upsell-card-${p.product_id}`,onclick:onOpen},
    image(p),h('span',{class:'bk-upsell-info'},h('strong',{text:(L==='en'&&p.name_en)||p.name}),
      h('small',{text:shortPlain((L==='en'&&p.short_description_en)||p.short_description||(L==='en'&&p.description_en)||p.description,105)}),
      h('span',{class:'bk-upsell-price',text:`${t('from')} ${money(p.price_from,L)}`})));
}
function bottomSheet({p,t,L,S,slots,openBy,onChoose}) {
  let before=document.activeElement;
  const overlay=h('div',{class:'bk-upsell-backdrop'});
  const headingId=`upsell-heading-${p.product_id}`;
  const closeBtn=h('button',{type:'button',class:'btn light','aria-label':t('close'),text:t('close')});
  const panel=h('section',{class:'bk-upsell-sheet',role:'dialog','aria-modal':'true','aria-labelledby':headingId,tabindex:'-1'});
  const exit=()=>{document.removeEventListener('keydown',onKey);overlay.remove();before?.focus?.();};
  closeBtn.addEventListener('click',exit);
  overlay.addEventListener('click',e=>{if(e.target===overlay)exit();});
  const onKey=e=>{
    if(e.key==='Escape'){e.preventDefault();exit();}
    if(e.key==='Tab'){
      const focusable=[...panel.querySelectorAll('button:not([disabled]),a[href],input:not([disabled])')];
      if(!focusable.length)return;
      if(e.shiftKey&&document.activeElement===focusable[0]){e.preventDefault();focusable.at(-1).focus();}
      else if(!e.shiftKey&&document.activeElement===focusable.at(-1)){e.preventDefault();focusable[0].focus();}
    }
  };
  const desc=shortPlain((L==='en'&&p.description_en)||p.description||(L==='en'&&p.short_description_en)||p.short_description,350);
  const more=urlFor(S,p.slug);
  const chips=h('div',{class:'bk-upsell-chips',role:'group','aria-label':t('choose_time')},slots.map(slot=>{
    const hint=slot.fit?t(slot.fit==='before'?'before':'after'):'';
    const b=h('button',{type:'button',class:'bk-upsell-chip','aria-label':`${clock(slot.start,L)} ${hint}`,onclick:async()=>{
      b.disabled=true;
      const ok=await onChoose(slot);
      if(ok)exit();else b.disabled=false;
    }},h('strong',{text:clock(slot.start,L)}),hint?h('small',{text:hint}):null);
    return b;
  }));
  panel.append(h('header',{class:'bk-upsell-sheet-head'},h('h3',{id:headingId,text:(L==='en'&&p.name_en)||p.name}),closeBtn),
    h('p',{class:'bk-upsell-desc',text:desc}),more?h('a',{href:more,target:'_blank',rel:'noopener noreferrer',text:t('read_more')}):null,
    h('h4',{text:t('choose_time')}),chips);
  overlay.append(panel);document.body.append(overlay);document.addEventListener('keydown',onKey);closeBtn.focus();
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
export function orderUpsellSection({ S,L,token,order,rpc,onAdded }) {
  const section=h('section',{class:'ord-card bk-upsell','data-testid':'upsell-confirmation',hidden:true});
  (async()=>{
    const t=await strings(S,L);if(!t('title'))return;
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
      bottomSheet({p,t,L,S,slots:p.slots,onChoose:async(slot)=>{
        const result=await rpc('public_upsell_add',{p_token:token,p_item:{type:'reservation',product_id:p.product_id,persons:1,start:slot.start},p_session_id:sourceSession,p_origin:p.origin||null}).catch(()=>null);
        if(!result?.ok){feedback.textContent=t('no_longer_available');return false;}
        feedback.textContent=t('added');await onAdded();return true;
      }});
    }));
    const addonButtons=addons.map(a=>h('button',{type:'button',class:'btn light bk-upsell-addon',onclick:async(e)=>{
      const res=(order.reservations||[]).find(r=>+r.product_id===+a.origin&&!['cancelled','expired'].includes(r.status));
      const item={type:'addon',addon_id:a.addon_id,quantity:1};
      if(res?.reservation_id)item.reservation_id=res.reservation_id;
      e.currentTarget.disabled=true;trackAddon(rpc,'confirmation',a,'opened');
      const out=await rpc('public_upsell_add',{p_token:token,p_item:item,p_session_id:sourceSession,p_origin:a.origin}).catch(()=>null);
      if(out?.ok){feedback.textContent=t('added');await onAdded();} else {feedback.textContent=t('no_longer_available');e.currentTarget.disabled=false;}
    }},`${(L==='en'&&a.name_en)||a.name} · ${money(a.price,L)}`));
    addons.forEach(a=>trackAddon(rpc,'confirmation',a,'shown'));
    section.append(h('h3',{text:t('title')}),h('p',{class:'bk-note',text:t('lead')}),
      h('div',{class:'bk-upsell-row'},cards),addonButtons.length?h('div',{class:'bk-upsell-addon-row'},addonButtons):null,
      order.payment_status==='paid'?null:h('p',{class:'bk-note',text:t('pay_separately')}),feedback);
    section.hidden=false;usable.slice(0,3).forEach(p=>track(rpc,'confirmation',p,'shown'));
  })().catch(()=>{});
  return section;
}

export function checkoutUpsellSection({S,L,productId,date,visitStart,persons,rpc,addons,onChange}) {
  const section=h('section',{class:'bk-section bk-upsell','data-testid':'upsell-checkout',hidden:true});
  const selected=new Map();let t=()=>'';let addonIds=new Set();
  const reset=()=>{selected.clear();section.querySelectorAll('[aria-pressed]')?.forEach(b=>b.setAttribute('aria-pressed','false'));onChange?.();};
  (async()=>{
    t=await strings(S,L);if(!t('checkout_title'))return;
    const data=await rpc('public_upsell_suggestions',{p_product_ids:[productId],p_date:date,p_persons:1,p_visit_start:visitStart}).catch(()=>null);if(!data)return;
    const slots=(data.products||[]).filter(p=>p.suggested).map(p=>({...p,slots:rankSlots(p.slots,[],date)})).filter(p=>p.slots.length).slice(0,3);
    const addonOffers=(data.addons||[]).filter(a=>addons.some(x=>+x.id===+a.addon_id));addonIds=new Set(addonOffers.map(a=>+a.addon_id));
    if(!slots.length&&!addonOffers.length)return;
    const row=h('div',{class:'bk-upsell-row'});
    for(const p of slots){
      const pane=h('div',{class:'bk-upsell-inline',hidden:true});
      const opener=card(p,t,L,()=>{pane.hidden=!pane.hidden;opener.setAttribute('aria-expanded',String(!pane.hidden));track(rpc,'checkout',p,'opened');});
      opener.setAttribute('aria-expanded','false');
      const chipRow=h('div',{class:'bk-upsell-chips',role:'group','aria-label':t('choose_time')});
      for(const slot of p.slots){
        const b=h('button',{type:'button',class:'bk-upsell-chip','aria-pressed':'false',onclick:()=>{
          const cur=selected.get(p.product_id);
          if(cur&&cur.start===slot.start){selected.delete(p.product_id);b.setAttribute('aria-pressed','false');}
          else {selected.clear();section.querySelectorAll('.bk-upsell-chip').forEach(x=>x.setAttribute('aria-pressed','false'));selected.set(p.product_id,{product_id:p.product_id,start:slot.start,persons:1,total:+slot.total||0});b.setAttribute('aria-pressed','true');}
          onChange?.();
        }},clock(slot.start,L));chipRow.append(b);
      }
      pane.append(h('p',{text:shortPlain((L==='en'&&p.description_en)||p.description,180)}),chipRow);
      row.append(h('div',{class:'bk-upsell-cell'},opener,pane));
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
  return {node:section,items:()=>[...selected.values()].map(({total,...item})=>item),total:()=>[...selected.values()].reduce((sum,x)=>sum+x.total,0),hasSuggestedAddon:items=>(items||[]).some(x=>addonIds.has(+x.id)),session:sourceSession,reset,text:(key)=>t(key)};
}
