// Existing admin sign-in/session; no new auth flow and no edits to the shared shell.
import { getSession, rpc } from './sb.js';
import { h } from './ui.js';
import { render } from './views/newsletters.js';
import { loadNewsletterTexts, newsletterText as T } from './newsletter-texts.js';
const root=document.getElementById('newsletter-root');
async function load(){
  root.replaceChildren();
  await loadNewsletterTexts(rpc);
  root.append(h('a',{href:'./',class:'btn',text:T('back')}));
  if(!getSession()) {root.append(h('p',{text:T('login')}),h('button',{type:'button',class:'btn',text:T('reload'),onclick:load}));return;}
  try {
    const perms=await rpc('admin_my_permissions');
    const ctx={can:p=>(perms.permissions||[]).includes(p)};
    root.append(...await render({ctx}));
  } catch {root.append(h('p',{role:'alert',class:'err',text:T('error')}),h('button',{type:'button',class:'btn',text:T('reload'),onclick:load}));}
}
void load();
