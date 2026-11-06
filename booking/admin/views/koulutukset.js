// booking_255: Lauran työtila. category=training, ei kind-pohjaista luokittelua.
// Tekstit ja muut aiemmat tuotetoiminnot säilyvät erillisessä lisätietonäkymässä.
import { rpc } from '../sb.js';
import { h, dialog, field, toast, run, errMsg, fmtDate, fmtDT, money, todayHel, badge } from '../ui.js';
import { getLang } from '../talous-i18n.js';
import { render as renderEvents } from './events.js';
import { loadTrainingTexts, trainingText as T } from '../training-texts.js';
import { trainingCards, enrichTrainingProducts, trainingGroup, TRAINING_SPACES, validSpaceTime, paymentState, nextTrainingStep, trainingExport, messagePreviewGate, orderedWaiters } from '../training-logic.js';
import { clearDayBundles } from '../day-bundle-cache.js';
import { downloadCsv } from '../csv.js';
import { customerMessageText } from '../events-logic.js';

const PANELS = ['osallistujat', 'viestit', 'maksut', 'tilat'];
const KEYS = ['people', 'messages', 'payments', 'spaces'];
const btn = (text, onclick, testid, cls = 'btn') => h('button', { type: 'button', class: cls, text, onclick, 'data-testid': testid });
const link = (text, href, cls = 'btn') => h('a', { class: cls, href, text });
const nameOf = p => getLang() === 'en' && p.name_en ? p.name_en : p.name;
const dates = r => `${fmtDate(r.starts_at || r.date)}${r.ends_at ? ` – ${fmtDate(r.ends_at)}` : ''}`;
const spaceBlocks = (r, refs) => (r.blocks || []).filter(b => b.mode === 'exclusive' && (b.resource_kind === 'space' || TRAINING_SPACES.has(b.resource_code) || (refs?.resources || []).some(s => s.id === b.resource_id && TRAINING_SPACES.has(s.code))));
const safeError = e => (e?.code === 'conflict' ? T('conflict') : e?.code === 'queue_order' ? T('queue_order') : errMsg(e));
async function act(button, job) { return run(button, async () => { try { await job(); } catch (e) { toast(safeError(e), 'err'); } }); }

export async function render(args) {
  const { ctx, refs, reload, query = new URLSearchParams() } = args;
  // Vanhat linkit Tekstit/Kerrat/Asetukset: ne poistamatta aiempaa editoria.
  if (['tekstit','kerrat','asetukset'].includes(query.get('valilehti'))) return renderEvents({ ...args, section: 'training' });
  await loadTrainingTexts(rpc);
  const canSpace = ctx.can('blocks.manage'), canEdit = ctx.can('catalog.edit'), canBook = ctx.can('bookings.manage'), canSend = ctx.can('messages.edit'), canPay = ctx.can('payments.manage');
  let products = await rpc('admin_event_list', { p_category: 'training', p_include_past: true });
  let statuses = null;
  try { statuses = await rpc('admin_training_work_list'); } catch { /* migration not installed: show unknown, never pretend ready */ }
  products = enrichTrainingProducts(products || [], statuses || []);
  const productId = Number(query.get('tapahtuma'));
  const p = (products || []).find(x => x.product_id === productId && x.category === 'training');
  const group = p ? trainingGroup(p, statuses || []) : query.get('ryhma') === 'matkat' ? 'trip' : 'training';
  const qbase = group === 'trip' ? { ryhma: 'matkat' } : {};
  const href = extras => '#/koulutukset' + (Object.keys({ ...qbase, ...extras }).length ? '?' + new URLSearchParams({ ...qbase, ...extras }) : '');
  const refresh = () => { clearDayBundles(); ctx.refs = null; reload(); };
  const go = (panel, ruleId = rule?.id) => { location.hash = href({ tapahtuma: p.product_id, kerta: ruleId, valilehti: panel }); };
  const nav = h('nav', { class: 'tl-tabs training-top', 'aria-label': T('title') },
    link(T('title'), '#/koulutukset', `tl-tabbtn${group === 'training' ? ' active' : ''}`),
    link(T('trips'), '#/koulutukset?ryhma=matkat', `tl-tabbtn${group === 'trip' ? ' active' : ''}`));
  const title = h('h1', { text: group === 'trip' ? T('trips') : T('title') });
  if (!p) {
    const rows = trainingCards(products || [], { group, includePast: query.get('menneet') === '1', today: todayHel(), statuses: statuses || [] });
    return [h('div', { class: 'training-work' }, title, nav, h('p', { class: 'muted', text: T('lead') }),
      h('h2', { text: T('now') }), h('div', { class: 'training-cards', 'data-testid': 'training-cards' }, rows.length ? rows.map(card) : h('p', { class: 'empty', text: T('empty') })),
      h('label', { class: 'check' }, h('input', { type: 'checkbox', checked: query.get('menneet') === '1' || null, onchange: e => { location.hash = href(e.target.checked ? { menneet: '1' } : {}); } }), T('past')))];
  }
  // Capacity-only dates stay off the home cards, but remain available for on-site work.
  const rules = [...(p.rules || [])].sort((a,b) => String(a.starts_at).localeCompare(String(b.starts_at)));
  let rule = rules.find(r => r.id === Number(query.get('kerta'))) || rules.find(r => !r.cancelled_at && String(r.ends_at).slice(0,10) >= todayHel()) || rules[0];
  if (!rule) return [title, nav, h('p', { text: T('empty') }), more()];
  let data;
  try { data = await rpc('admin_training_work_get', { p_rule_id: rule.id }); }
  catch { return [title, nav, link(T('back'), href({})), h('p', { class: 'err', role: 'alert', text: T('unavailable') }), more()]; }
  rule = data.rule || rule;
  const people = data.people || [], work = data.work || {}, messages = data.messages || [], blocks = spaceBlocks(rule, refs);
  const panel = PANELS.includes(query.get('valilehti')) ? query.get('valilehti') : 'osallistujat';
  const next = nextTrainingStep({ blocks, people, messages, work });
  const nextPanel = next === 'spaces' ? 'tilat' : next === 'payments' ? 'maksut' : next === 'messages' ? 'viestit' : 'osallistujat';
  const checklist = h('section', { class: 'card training-check', 'aria-label': T('ready') }, h('h2', { text: T('ready') }),
    check(T('spaces_ok'), blocks.length > 0), check(T('message_done'), messages.some(m => m.queued_count > 0)),
    check(T('payments_done'), people.length > 0 && !people.some(x => Number(x.due_actual) > 0.004)),
    h('label', { class: 'check' }, h('input', { type: 'checkbox', checked: work.materials_shared || null, onchange: e => act(e.target, async () => { await rpc('admin_training_work_save', { p_rule_id: rule.id, p_materials_shared: e.target.checked, p_templates: work.templates || {} }); refresh(); }) }), T('materials')));
  const summary = h('section', { class: 'card training-summary', 'data-testid': 'training-summary' },
    h('h1', { text: nameOf(p) }), p.active === false ? badge('warn',T('hidden')) : null,
    rules.length > 1 ? field(T('date'), h('select', { 'aria-label': T('date'), onchange: e => go('osallistujat', Number(e.target.value)) }, rules.map(r => h('option', { value: r.id, selected: r.id === rule.id || null, text: dates(r) })))) : h('p', { class: 'training-dates', text: dates(rule) }),
    h('div', { class: 'training-facts' }, fact(T('places_free'), String(rule.seats_remaining ?? '–')), fact(T('people'), `${rule.sold_persons || 0} / ${rule.max_persons ?? '–'}`), fact(T('spaces'), blocks.length ? T('spaces_ok') : T('spaces_missing')), fact(T('open_payments'), String(people.filter(x => Number(x.due_actual)>0.004).length))),
    h('div', { class: 'row wrap' }, h('strong', { text: `${T('next')}:` }), btn(next === 'materials' ? T('materials') : next === 'spaces' ? T('reserve') : T(next), () => go(nextPanel), 'training-next')));
  const tabs = h('nav', { class: 'tl-tabs training-tabs', 'aria-label': nameOf(p) }, PANELS.map((id,i) => link(T(KEYS[i]), href({ tapahtuma: p.product_id, kerta: rule.id, valilehti: id }), `tl-tabbtn${id===panel?' active':''}`)));
  const content = panel === 'osallistujat' ? peoplePanel() : panel === 'viestit' ? messagesPanel() : panel === 'maksut' ? paymentsPanel() : spacesPanel();
  return [h('div', { class: 'training-work' }, link(`‹ ${T('back')}`, href({}), 'link'), nav, summary, checklist, tabs, h('section', { class: 'training-panel', 'data-testid': `training-panel-${panel}` }, content), more())];

  function card({ p: item, r, status }) {
    const reserved = spaceBlocks(r, refs).length > 0;
    const args = { tapahtuma: item.product_id, kerta: r.id };
    return h('article', { class: 'card training-card', 'data-testid': 'training-card' }, h('h3', { text: nameOf(item) }), h('p', { class: 'training-dates', text: dates(r) }),
      fact(T('places'), `${r.sold_persons || 0} / ${r.max_persons ?? '–'}`), fact(T('places_free'), String(r.seats_remaining ?? '–')), h('p', {}, badge(reserved?'ok':'warn',T(reserved?'spaces_ok':'spaces_missing'))),
      fact(T('open_payments'), status ? String(status.open_payments) : T('unknown')),
      h('div', { class: 'row wrap' }, link(T('open'), href(args), 'btn primary'), !reserved && canSpace ? link(T('reserve'), href({ ...args,valilehti:'tilat' }), 'btn ghost') : null));
  }
  function more() {
    return h('details', { class: 'training-more' }, h('summary', { text: T('more') }), h('div', { class: 'row wrap' },
      link(T('texts'), href({ tapahtuma: p.product_id, valilehti:'tekstit' })),
      link(T('more'), href({ tapahtuma: p.product_id, valilehti:'kerrat' })),
      canEdit && rule && !rule.training_segment_only ? btn(T('copy'), () => copySession(), 'training-copy') : null));
  }
  function check(label, done) { return h('p', { class: done?'training-done':'training-todo' }, h('span', { 'aria-hidden':'true', text:done?'✓ ':'— ' }), label); }
  function fact(label, value) { return h('div', {}, h('span', { class:'muted',text:label+' ' }), h('strong',{text:value})); }
  function formBox(title, nodes, submitText, job, testid) {
    let busy = false;
    const submit = h('button', { type:'submit',class:'btn primary',text:submitText,'data-testid':testid });
    const cancel = btn(T('cancel'), () => { if (!busy) d.close(); });
    const error = h('p', { class:'err',role:'alert' });
    const form = h('form', { class:'stack training-form' }, nodes, error, h('div',{class:'row wrap'},submit,cancel));
    const d = dialog(title,form);
    form.addEventListener('submit',async e => { e.preventDefault(); if(busy) return; busy=true; submit.disabled=true; cancel.disabled=true;
      try { await job(new FormData(form)); d.close(); } catch(e2) { error.textContent=safeError(e2); } finally { busy=false; submit.disabled=false; cancel.disabled=false; } });
    return { d,form };
  }
  function input(label,name,value='',type='text',extra={}) { return field(T(label),h('input',{name,type,value,...extra})); }
  function langSelect(value='fi') { return field(T('language'),h('select',{name:'language'},[['fi','Suomi'],['en','English']].map(([v,t])=>h('option',{value:v,selected:value===v||null,text:t})))); }
  function personInputs(person={},emailRequired=true) { return [input('name','name',person.name||'','text',{required:true,maxlength:200}), input('email','email',person.email||'','email',{required:emailRequired||null,maxlength:254}), input('phone','phone',person.phone||'','tel',{maxlength:40}),langSelect(person.language)]; }
  function detailsDialog(row) {
    formBox(T('details')+' – '+row.name,[...['diet','accommodation','arrival'].map(k=>input(k,k,row[k]||'','text',{maxlength:k==='arrival'?200:1000})),langSelect(row.language)],T('save'),async fd=> {
      await rpc('admin_training_person_save',{p_reservation_id:row.reservation_id,p_details:{...row,...Object.fromEntries(fd)}}); refresh();
    },'training-details-save');
  }
  function peoplePanel() {
    const payBadge = row => badge({paid:'ok',partial:'warn',unpaid:'err'}[paymentState(row)],T(paymentState(row)));
    const heads = ['name','persons','payments','contact','present'];
    return [h('h2',{text:T('people')}), h('div',{class:'row wrap training-no-print'},
      canBook && !rule.training_segment_only ? btn(T('add_person'),()=>formBox(T('add_person'),personInputs(),T('save'),async fd=>{ await rpc('admin_training_person_add',{p_rule_id:rule.id,p_customer:Object.fromEntries(fd)}); refresh(); },'training-person-add'),'training-add-person','btn primary') : null,
      btn(T('export'),()=>downloadCsv(`osallistujat_${p.product_id}_${rule.id}.csv`,trainingExport(people,['name','email','phone','persons','diet','accommodation','arrival','language','present','actual_paid','remaining'].map(T))),'training-export'),
      btn(T('print'),()=>{ document.body.classList.add('training-printing'); const finish=()=>{document.body.classList.remove('training-printing');window.removeEventListener('afterprint',finish);};window.addEventListener('afterprint',finish);window.print(); },'training-print')),
      people.length ? h('div',{class:'ev-table-wrap training-print-area'},h('h3',{class:'training-print-only',text:nameOf(p)+' · '+dates(rule)}), h('table',{class:'ev-table training-people'},h('thead',{},h('tr',{},heads.map(x=>h('th',{scope:'col',text:T(x)})))), h('tbody',{},people.map(row=>h('tr',{'data-testid':'training-person'},
        h('td',{},h('strong',{text:row.name||'–'}),btn(T('details'),()=>detailsDialog(row),null,'btn sm ghost training-no-print'),h('div',{class:'training-print-only',text:[row.diet,row.accommodation,row.arrival,row.language].filter(Boolean).join(' · ')})),
        h('td',{text:String(row.persons||1)}),h('td',{},payBadge(row)),h('td',{text:[row.email,row.phone].filter(Boolean).join(' · ')}),
        h('td',{},h('label',{class:'check'},h('input',{type:'checkbox',checked:row.present||null,'aria-label':T('present')+' '+row.name,onchange:e=>act(e.target,async()=>{await rpc('admin_training_person_save',{p_reservation_id:row.reservation_id,p_details:{...row,present:e.target.checked}});row.present=e.target.checked;})}),T('present')))))))) : h('p',{class:'empty',text:T('none_people')}),
      waitlistPanel()];
  }
  function waitlistPanel() {
    const waiters = orderedWaiters(data.waitlist||[]);
    function update(w,status) { return rpc('admin_training_waitlist_update',{p_rule_id:rule.id,p_id:w.id,p_status:status}).then(refresh); }
    return h('details',{class:'card training-no-print',open:rule.seats_remaining===0||(rule.sold_persons||0)>=(rule.max_persons||Infinity)||null},h('summary',{text:`${T('waitlist')} (${waiters.length})`}),
      btn(T('add_waiter'),()=>formBox(T('add_waiter'),[...personInputs({},false),input('persons','persons',1,'number',{min:1,max:20,required:true})],T('save'),async fd=>{await rpc('admin_training_waitlist_add',{p_rule_id:rule.id,p_person:Object.fromEntries(fd)});refresh();},'training-waiter-save'),'training-add-waiter'),
      waiters.length ? h('ol',{class:'training-waiters'},waiters.map((w,i)=>h('li',{},h('strong',{text:w.name}),h('p',{text:[w.persons,w.email,w.phone,T(w.status)].filter(Boolean).join(' · ')}),
        i===0 && w.status==='waiting' ? btn(T('offer'),()=>formBox(T('offer'),[h('p',{text:w.name+' · '+[w.email,w.phone].filter(Boolean).join(' · ')}),h('p',{text:T('offer_hint')})],T('mark_offered'),()=>update(w,'offered'),'training-offer-confirm'),'training-offer') : null,
        w.status==='offered' ? btn(T('booked'),()=>formBox(T('booked'),h('p',{text:w.name}),T('confirm'),()=>update(w,'booked'))) : null,
        btn(T('remove_waiter'),()=>formBox(T('remove_waiter'),h('p',{text:T('remove_confirm')+' '+w.name}),T('confirm'),()=>update(w,'cancelled')),null,'btn sm ghost')))) : h('p',{text:T('none_waiters')}));
  }
  function spacesPanel() {
    const spaces = (refs?.resources||[]).filter(x=>x.active!==false&&TRAINING_SPACES.has(x.code)&&x.kind==='space');
    return [h('h2',{text:T('spaces')}),h('p',{text:T('space_hint')}), canSpace ? btn(T('reserve'),()=>formBox(T('reserve'),[
      field(T('space'),h('select',{name:'space',required:true},spaces.map(s=>h('option',{value:s.id,text:s.name})))),input('date','date',rule.date,'date',{required:true}),
      input('start','start','14:00','time',{required:true}),input('end','end','16:00','time',{required:true})],T('reserve'),async fd=>{
        if(!validSpaceTime(fd.get('date'),fd.get('start'),fd.get('end'))) throw new Error(T('bad_time'));
        await rpc('admin_training_space_add',{p_rule_id:rule.id,p_space_id:Number(fd.get('space')),p_date:fd.get('date'),p_start:fd.get('start'),p_end:fd.get('end')}); refresh();
      },'training-space-save'),'training-reserve','btn primary') : h('p',{text:T('readonly')}),
      blocks.length ? h('ul',{class:'training-blocks'},blocks.map(b=>h('li',{class:'card','data-testid':'training-space'},h('strong',{text:b.resource_name||(refs.resources||[]).find(s=>s.id===b.resource_id)?.name||T('space')}),h('p',{text:`${fmtDT(b.starts_at)} – ${fmtDT(b.ends_at)}`}),
        canSpace ? btn(T('space_cancel'),()=>formBox(T('space_cancel'),h('p',{text:T('space_confirm')}),T('confirm'),async()=>{await rpc('admin_training_space_cancel',{p_rule_id:rule.id,p_block_id:b.id,p_confirm:true});refresh();},'training-space-cancel-confirm'),null,'btn ghost') : null))) : h('p',{class:'empty',text:T('none_spaces')})];
  }
  function messagesPanel() {
    const gate = messagePreviewGate();
    const fields = {};
    const previewHost = h('div',{'data-testid':'training-message-preview',hidden:true,class:'card stack'});
    const send = btn(T('send'),e=>act(e.target,async()=>{
      const pv=gate.read(); if(!pv || !confirm.checked) { toast(T('preview_again'),'err'); return; }
      await rpc('admin_training_message_send',{p_preview_id:pv.id,p_confirm:true}); gate.invalidate();send.disabled=true;toast(T('sent'));refresh();
    }),'training-message-send','btn primary');send.disabled=true;
    const confirm = h('input',{type:'checkbox','data-testid':'training-message-confirm',onchange:()=>{send.disabled=!gate.read()||!confirm.checked;}});
    function invalidate() {gate.invalidate();send.disabled=true;confirm.checked=false;previewHost.hidden=true;}
    const editor = h('div',{class:'training-language-editors'},['fi','en'].map(lang=>{
      const subject=h('input',{maxlength:200,required:true,'data-testid':`training-subject-${lang}`,oninput:invalidate}),body=h('textarea',{rows:7,maxlength:4000,required:true,'data-testid':`training-body-${lang}`,oninput:invalidate});fields[lang]={subject,body};
      return h('fieldset',{class:'card stack'},h('legend',{text:lang==='fi'?'Suomi':'English'}),field(T('subject'),subject),field(T('body'),body));
    }));
    const template = h('select',{'data-testid':'training-template',onchange:e=>apply(e.target.value)},['arrival','payment','free'].map(v=>h('option',{value:v,text:T(v+'_template')})));
    function content() {return Object.fromEntries(['fi','en'].map(lang=>[lang,{subject:fields[lang].subject.value.trim(),body:fields[lang].body.value.trim()}]));}
    function apply(kind) {invalidate();const saved=work.templates?.[kind];for(const lang of ['fi','en']){fields[lang].subject.value=saved?.[lang]?.subject||(kind==='free'?'':T(kind+'_subject',lang));fields[lang].body.value=saved?.[lang]?.body||(kind==='free'?'':T(kind+'_body',lang));}}
    apply('arrival');
    return [h('h2',{text:T('messages')}),h('p',{text:T('manual_hint')}), canSend ? h('div',{class:'stack'},field(T('template'),template),editor,
      h('div',{class:'row wrap'},btn(T('preview'),e=>act(e.target,async()=>{
        const draft=content();if(['fi','en'].some(lang=>draft[lang].body===T('arrival_body',lang)))throw new Error(T('complete_template'));
        const revision=gate.revision();const pv=await rpc('admin_training_message_preview',{p_rule_id:rule.id,p_content:draft});if(!gate.accept(pv,revision))return;
        previewHost.hidden=false;previewHost.replaceChildren(h('ul',{},pv.recipients.map(x=>h('li',{text:`${x.name} · ${x.email} · ${x.language}`}))),...['fi','en'].map(lang=>h('pre',{class:'ev-mail',text:customerMessageText({subject:pv.content[lang].subject,body:pv.content[lang].body,eventName:lang==='en'?(pv.content._context?.event_name_en||pv.content._context?.event_name||p.name_en||p.name):(pv.content._context?.event_name||p.name),whenText:pv.content._context?.when_text||dates(rule),lang}).text})));confirm.checked=false;send.disabled=true;
      }),'training-message-preview-button'),btn(T('save_template'),e=>act(e.target,async()=>{await rpc('admin_training_work_save',{p_rule_id:rule.id,p_materials_shared:!!work.materials_shared,p_templates:{...(work.templates||{}),[template.value]:content()}});work.templates={...(work.templates||{}),[template.value]:content()};toast(T('saved'));}),'training-save-template')),
      previewHost,h('label',{class:'check'},confirm,T('send_confirm')),h('div',{class:'row wrap'},send,btn(T('cancel'),()=>{invalidate();apply(template.value);}))) : h('p',{text:T('readonly')}),
      h('h3',{text:T('log')}),messages.length?h('ul',{},messages.map(m=>h('li',{text:`${fmtDT(m.created_at)} · ${m.subject} · ${m.queued_count}`}))):h('p',{text:T('none_messages')})];
  }
  function paymentsPanel() {
    const selected = new Set();
    const unique = [...new Map(people.map(x=>[x.order_id,x])).values()];
    const rows = unique.map(row=>h('tr',{},h('td',{},h('input',{type:'checkbox','aria-label':T('select')+' '+row.name,onchange:e=>{if(e.target.checked)selected.add(row.order_id);else selected.delete(row.order_id);}})),h('td',{text:row.name}),h('td',{text:money(row.deposit_due)}),h('td',{text:row.course_total==null?'–':money(row.course_total)}),h('td',{text:money(row.paid_actual)}),h('td',{text:money(row.due_actual)}),
      h('td',{},h('div',{class:'row wrap'},link(T('order'),`#/tilaukset?order=${encodeURIComponent(row.order_no)}`,'btn sm ghost'),canPay&&ctx.can('bookings.override')&&row.course_total!=null&&Number(row.billed_total)<Number(row.course_total)?btn(T('prepare_balance'),()=>formBox(T('balance'),[h('p',{text:row.name+' · '+money(Number(row.course_total)-Number(row.deposit_due))}),h('p',{text:T('prepare_hint')})],T('confirm'),async()=>{await rpc('admin_training_prepare_balance',{p_rule_id:rule.id,p_order_id:row.order_id});refresh();}),null,'btn sm'):null,
        ctx.can('invoices.manage') ? btn(T('invoice'),()=>formBox(T('invoice'),h('p',{text:row.name+' · '+money(Math.max(0,Number(row.billed_total)-Number(row.paid_actual)))}),T('confirm'),async()=>{const invoice=await rpc('admin_create_invoice_from_order',{p_order_id:row.order_id});location.hash=`#/laskut?invoice=${invoice.invoice_id||invoice.id}`;}),null,'btn sm ghost'):null))));
    return [h('h2',{text:T('payments')}),h('p',{text:T('payment_info')}),h('p',{text:T('pay_hint')}),
      h('div',{class:'ev-table-wrap'},h('table',{class:'ev-table'},h('thead',{},h('tr',{},['select','name','deposit','course_price','actual_paid','remaining','payments'].map(k=>h('th',{scope:'col',text:T(k)})))),h('tbody',{},rows))),
      canPay ? btn(T('paylink'),()=>{
        const list=unique.filter(x=>selected.has(x.order_id));if(!list.length){toast(T('no_selection'),'err');return;}
        formBox(T('pay_preview'),[h('p',{text:T('pay_hint')}),h('ul',{},list.map(x=>h('li',{text:`${x.name} · ${x.email||T('no_email')} · ${money(Math.max(0,Number(x.billed_total)-Number(x.paid_actual)))}`})))],T('paylink'),async()=>{
          await rpc('admin_training_payment_links',{p_rule_id:rule.id,p_rows:list.map(row=>({order_id:row.order_id,amount:Math.max(0,Number(row.billed_total)-Number(row.paid_actual)),email:row.email})),p_confirm:true});refresh();
        },'training-paylink-confirm');
      },'training-paylink','btn primary'):null];
  }
  function copySession() {
    formBox(T('copy'),[h('p',{text:T('copy_hint')}),input('copy_name','name',nameOf(p),'text',{required:true,maxlength:200}),input('copy_date','date','','date',{required:true,min:todayHel()})],T('copy'),async fd=>{
      const out=await rpc('admin_training_session_copy',{p_rule_id:rule.id,p_date:fd.get('date'),p_name:fd.get('name')});clearDayBundles();ctx.refs=null;location.hash=href({tapahtuma:out.product_id,kerta:out.rule_id});
    },'training-copy-confirm');
  }
}
