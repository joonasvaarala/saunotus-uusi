// booking_259: standalone, reusable view. No nav/shell/Message-page edits.
import { rpc } from '../sb.js';
import { h, field, run, fmtDT } from '../ui.js';
import { confirmDialog } from '../confirm.js';
import { NEWSLETTER_SEGMENTS, newsletterPatch, newsletterCanSend } from '../newsletter-logic.js';
import { loadNewsletterTexts, newsletterText as T } from '../newsletter-texts.js';
import { renderNewsletter } from '../newsletter-render.js';

export async function render({ctx}) {
  if (!document.getElementById('newsletter-style')) {
    const url=new URL('../newsletter.css',import.meta.url);url.search=new URL(import.meta.url).search;
    document.head.append(h('link',{id:'newsletter-style',rel:'stylesheet',href:url.href}));
  }
  await loadNewsletterTexts(rpc);
  if (!ctx.can('messages.edit')) return [h('p',{role:'alert',text:T('forbidden')})];
  const root=h('section',{class:'newsletter-work'});
  const title=h('h1',{text:T('title')});
  const status=h('p',{role:'status','aria-live':'polite'});
  const editor=h('div');
  root.append(title,h('p',{text:T('lead')}),h('p',{class:'muted',text:T('privacy')}),status,editor);
  let rows=await rpc('admin_newsletters_list');
  rows=Array.isArray(rows)?rows:[];
  if (!rows.length) { editor.append(h('p',{class:'empty',text:T('empty')})); return [root]; }
  const select=h('select',{'aria-label':T('choose'),onchange:()=>open(rows.find(x=>String(x.id)===select.value))},rows.map(x=>h('option',{value:x.id,text:`${x.subject_fi} · ${T(x.state)}`})));
  root.insertBefore(field(T('choose'),select),editor);
  open(rows[0]);
  return [root];

  function open(initial) {
    if (!initial) return;
    editor.replaceChildren(); status.textContent='';
    let draft={...initial}, preview=null, dirty=false, busy=false;
    const error=h('p',{class:'err',role:'alert'});
    const frames=h('div',{class:'newsletter-previews'});
    const form=h('form',{class:'stack',onsubmit:e=>e.preventDefault()});
    const inputs=['subject_fi','subject_en','body_fi','body_en'].map(k=>field(T(k),h(k.startsWith('body')?'textarea':'input',{name:k,value:draft[k]||'',required:true,maxlength:k.startsWith('body')?16000:200,rows:k.startsWith('body')?10:null})));
    const group=h('fieldset',{},...inputs,
      field(T('segment'),h('select',{name:'segment'},NEWSLETTER_SEGMENTS.map(k=>h('option',{value:k,selected:k===draft.segment||null,text:T(k)})))),
      field(T('language'),h('select',{name:'language'},[['all',T('all_languages')],['fi','Suomi'],['en','English']].map(([v,t])=>h('option',{value:v,selected:v===draft.language||null,text:t})))));
    const save=h('button',{type:'button',class:'btn',text:T('save'),onclick:e=>action(e.currentTarget,async()=>{await persist();status.textContent=T('saved');})});
    const check=h('button',{type:'button',class:'btn',text:T('preview'),onclick:e=>action(e.currentTarget,async()=>{
      await persist();
      preview={...await rpc('admin_newsletter_dispatch',{p_id:draft.id,p_version:draft.version,p_confirm:false}),at:Date.now()};
      draft.state='previewed';
      frames.replaceChildren(...['fi','en'].map(lang=>previewFrame(draft,lang)));
      status.textContent=T('count',{count:preview.recipient_count,fi:preview.fi_count,en:preview.en_count});
      send.disabled=!newsletterCanSend(preview,draft,dirty);
    })});
    const send=h('button',{type:'button',class:'btn primary',disabled:true,text:T('send'),onclick:e=>action(e.currentTarget,async()=>{
      if(!newsletterCanSend(preview,draft,dirty)) { invalidate();error.textContent=T('preview_required');return; }
      const ok=await confirmDialog({title:T('confirm_title'),body:T('confirm_body',{count:preview.recipient_count}),yes:T('send'),no:T('cancel')});
      if(!ok)return;
      if(!newsletterCanSend(preview,draft,dirty)) { invalidate();error.textContent=T('preview_required');return; }
      const out=await rpc('admin_newsletter_dispatch',{p_id:draft.id,p_version:draft.version,p_confirm:true,p_preview_token:preview.preview_token});
      if(!out.sent)throw new Error('newsletter_not_sent');
      draft.state='sent';group.disabled=true;save.disabled=true;check.disabled=true;invalidate();
      rows=rows.map(x=>x.id===draft.id?{...draft}:x);
      select.options[select.selectedIndex].textContent=`${draft.subject_fi} · ${T('sent')}`;
      status.textContent=T('queued');
    })});
    form.addEventListener('input',()=>{dirty=true;invalidate();});
    form.addEventListener('change',()=>{dirty=true;invalidate();});
    form.append(group,error,h('div',{class:'row wrap'},save,check,send),h('p',{class:'muted',text:T('style')}),frames);
    editor.append(form);
    if(draft.suggested_send_at) editor.prepend(h('p',{text:T('suggestion',{date:fmtDT(draft.suggested_send_at)})}));
    if(draft.delivery) editor.prepend(h('p',{text:T('history',{count:draft.delivery.recipient_count,...draft.delivery,queued:draft.delivery.queued_count})}));
    if(draft.state==='sent') {group.disabled=true;save.disabled=true;check.disabled=true;frames.append(...['fi','en'].map(lang=>previewFrame(draft,lang)));}
    function invalidate(){preview=null;send.disabled=true;frames.replaceChildren();}
    async function persist(){
      if(!form.reportValidity())throw new Error('invalid_form');
      draft=await rpc('admin_newsletter_save',{p_id:draft.id,p_data:newsletterPatch(form),p_version:draft.version});
      rows=rows.map(x=>x.id===draft.id?{...draft}:x);dirty=false;invalidate();
    }
    async function action(button,job){
      if(busy)return;busy=true;select.disabled=true;group.disabled=true;save.disabled=true;check.disabled=true;send.disabled=true;error.textContent='';
      await run(button,async()=>{try {await job();}catch(e) {invalidate();error.textContent=T(['too_many','email_disabled','no_recipients','newsletter_conflict','newsletter_preview_required'].includes(e?.code)?e.code:'error');}});
      busy=false;select.disabled=false;group.disabled=draft.state==='sent';save.disabled=draft.state==='sent';check.disabled=draft.state==='sent';send.disabled=!newsletterCanSend(preview,draft,dirty);
    }
  }
}
function previewFrame(draft,lang){
  const mail=renderNewsletter({subject:draft['subject_'+lang],body:draft['body_'+lang],style:draft.style,locale:lang,unsubscribe_url:'https://saunotus.fi/tilaus/?u=PREVIEW'});
  const csp='<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; img-src https:; style-src \'unsafe-inline\'; base-uri \'none\'; form-action \'none\'">';
  return h('section',{},h('h2',{text:T(lang+'_preview')}),h('iframe',{title:T(lang+'_preview'),sandbox:'',referrerpolicy:'no-referrer',srcdoc:mail?.html.replace('<head>','<head>'+csp)||'',class:'newsletter-frame'}));
}
