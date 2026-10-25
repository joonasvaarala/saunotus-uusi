// Product edit widget. All visible labels from public site_texts ui.upsell.*, no direct table writes.
import { getSiteTexts } from '../site-texts-cache.js';
import { rpc } from '../sb.js';
import { h, toast, run } from '../ui.js';

function strings(rows) {
  const index = new Map((rows || []).filter(x=>x?.key?.startsWith('ui.upsell.')&&x.lang==='fi').map(x=>[x.key,x.text]));
  return key=>index.get(`ui.upsell.${key}`)||'';
}

export async function productSuggestionsEditor({ product, all, canEdit }) {
  const [txt, old, addonsRaw] = await Promise.all([
    getSiteTexts(rpc).catch(()=>null),rpc('admin_get_product_suggestions',{p_product_id:product.id}).catch(()=>null),
    rpc('admin_list_addons').catch(()=>[])
  ]);
  const t=strings(txt?.texts);
  if(!t('admin_title') || !Array.isArray(old)) return null;
  const addons=Array.isArray(addonsRaw)?addonsRaw:Array.isArray(addonsRaw?.addons)?addonsRaw.addons:[];
  const candidateProducts=(all||[]).filter(p=>p.id!==product.id&&p.active&&p.config?.bookable&&p.config?.public_slots);
  const state=(Array.isArray(old)?old:[]).map(x=>({product_id:x.product_id,addon_id:x.addon_id,enabled:x.enabled}));
  const form=h('form',{class:'box stack','data-testid':'product-suggestions-form'});
  const list=h('div',{class:'stack'});
  const feedback=h('p',{role:'status','aria-live':'polite'});
  const opts=[...candidateProducts.map(p=>({value:`p:${p.id}`,label:p.name})),...addons.filter(a=>a.active!==false).map(a=>({value:`a:${a.id}`,label:a.name}))];
  function paint() {
    list.replaceChildren(...state.map((x,i)=>{
      const sel=h('select',{'aria-label':`${t('admin_item')} ${i+1}`,disabled:!canEdit},opts.map(o=>h('option',{value:o.value,text:o.label})));
      sel.value=x.product_id?`p:${x.product_id}`:`a:${x.addon_id}`;
      sel.addEventListener('change',()=>{ const [kind,id]=sel.value.split(':');state[i]={...state[i],product_id:kind==='p'?+id:null,addon_id:kind==='a'?+id:null}; });
      const check=h('input',{type:'checkbox',checked:x.enabled!==false,disabled:!canEdit,'aria-label':t('admin_enabled')});
      check.addEventListener('change',()=>{x.enabled=check.checked;});
      return h('div',{class:'row wrap'},sel,h('label',{class:'check'},check,t('admin_enabled')),
        h('button',{type:'button',class:'btn sm',disabled:!canEdit||i===0,onclick:()=>{[state[i-1],state[i]]=[state[i],state[i-1]];paint();},text:t('admin_up')}),
        h('button',{type:'button',class:'btn sm',disabled:!canEdit||i===state.length-1,onclick:()=>{[state[i+1],state[i]]=[state[i],state[i+1]];paint();},text:t('admin_down')}),
        h('button',{type:'button',class:'btn sm',disabled:!canEdit,onclick:()=>{state.splice(i,1);paint();},text:t('admin_remove')}));
    }));
  }
  const add=h('button',{type:'button',class:'btn light',text:t('admin_add'),disabled:!canEdit,onclick:()=>{
    if(state.length>=3||!opts.length)return;
    const free=opts.find(o=>!state.some(s=>o.value===(s.product_id?`p:${s.product_id}`:`a:${s.addon_id}`)));
    if(!free)return;
    const [kind,id]=free.value.split(':');state.push({product_id:kind==='p'?+id:null,addon_id:kind==='a'?+id:null,enabled:true});paint();add.disabled=state.length>=3;
  }});
  form.append(h('h3',{text:t('admin_title')}),h('p',{class:'muted',text:t('admin_help')}),list,
    h('div',{class:'row wrap'},add,h('button',{type:'submit',class:'btn primary',text:t('admin_save'),disabled:!canEdit})),feedback);
  form.addEventListener('submit',e=>{e.preventDefault();
    const ids=state.map(s=>s.product_id?`p:${s.product_id}`:`a:${s.addon_id}`);
    if(new Set(ids).size!==ids.length){feedback.textContent=t('admin_duplicate');return;}
    run(form.querySelector('button[type=submit]'),async()=>{
      await rpc('admin_set_product_suggestions',{p_product_id:product.id,p_items:state});
      feedback.textContent=t('admin_saved');toast(t('admin_saved'));
    });
  });
  paint();add.disabled=state.length>=3;
  const report=h('div',{class:'box stack'},h('h3',{text:t('report_title')}));
  const table=h('div',{'aria-live':'polite'});
  const btn=h('button',{type:'button',class:'btn',text:t('report_load'),onclick:async()=>{
    btn.disabled=true;
    try{
      const data=await rpc('admin_upsell_report',{});
      const rows=(Array.isArray(data)?data:[]).filter(r=>+r.origin_id===+product.id||+r.product_id===+product.id);
      const tbl=h('table',{class:'tl-table'},h('thead',{},h('tr',{},...['report_product','report_shown','report_opened','report_added','report_paid','report_eur'].map(k=>h('th',{text:t(k)})))),
        h('tbody',{},rows.map(r=>h('tr',{},h('td',{text:r.product_name}),...['shown','opened','added','paid','paid_eur'].map(k=>h('td',{text:String(r[k]??0)}))))));
      table.replaceChildren(tbl);
    }catch{table.textContent=t('report_error');}finally{btn.disabled=false;}
  }});
  report.append(btn,table);
  return h('div',{class:'stack'},form,report);
}
