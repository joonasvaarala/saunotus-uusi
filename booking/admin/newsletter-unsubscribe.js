// Public, token-limited newsletter opt-out. GET/page load NEVER mutates consent.
// Fragment avoids server/referrer token logs. Clear it before any RPC or image load.
import {rpc} from './sb.js';
import {h} from './ui.js';
import {loadNewsletterTexts,newsletterText as T} from './newsletter-texts.js';
const root=document.getElementById('newsletter-optout');
let generation=0;
async function init(){
 const current=++generation;
 const params=new URLSearchParams(location.hash.replace(/^#/,''));
 const token=params.get('token'),lang=params.get('lang')==='en'?'en':'fi';
 history.replaceState(null,'',location.pathname+location.search);
 document.documentElement.lang=lang;root.replaceChildren();
 await loadNewsletterTexts(rpc);
 if(current!==generation)return;
 const text=k=>T(k,{},lang);
 root.append(h('h1',{text:text('unsubscribe_title')}),h('p',{text:text('unsubscribe_lead')}));
 if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(token||'')){root.append(h('p',{role:'alert',text:text('unsubscribe_invalid')}));return;}
 const status=h('p',{role:'status'});
 const button=h('button',{type:'button',class:'btn primary',text:text('unsubscribe_confirm'),onclick:async()=>{
  button.disabled=true;status.textContent='';
  try {await rpc('public_newsletter_unsubscribe',{p_token:token});status.textContent=text('unsubscribe_done');}
  catch {status.textContent=text('unsubscribe_error');button.disabled=false;}
 }});
 root.append(button,status);
}
window.addEventListener('hashchange',()=>void init());
void init();
