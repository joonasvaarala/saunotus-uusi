// Mock-only adapters: callers install these only inside createEventsMock (?mock=1).
// Nothing here calls network or sends mail. SQL is the authority for real writes.
import { helsinkiIso, localParts, addDays } from './events-logic.js';
import { orderedWaiters } from './training-logic.js';
export function trainingMockHandlers({ st, locate, ruleObj, resources, err }) {
  const works = new Map(), details = new Map(), waiters = [], previews = new Map();
  const work = id => works.get(id) || { materials_shared: false, templates: {} };
  const people = id => st.participants.filter(x => x.rule_id === id && x.order_status !== 'cancelled').map(x => ({
    ...x, diet: '', accommodation: '', arrival: '', language: x.language || 'fi', present: false,
    deposit_due: x.deposit_due ?? 200, course_total: x.course_total ?? 890,
    paid_actual: x.payment_status === 'paid' ? x.course_total ?? 890 : 0,
    due_actual: x.payment_status === 'paid' ? 0 : x.course_total ?? 890, billed_total: x.course_total ?? 890,
    ...details.get(x.reservation_id),
  }));
  const assertTraining = id => { const out = locate(id); if (out.p.category !== 'training') throw err('not_found'); return out; };
  const recipients = id => people(id).filter(x => x.email).map(x => ({ order_id: x.order_id, name:x.name,email:x.email,language:x.language }));
  return {
    admin_training_work_list: () => st.events.filter(p=>p.category==='training').flatMap(p=>p.rules.map(r=>({rule_id:r.id,group_kind:p.product_id===121?'trip':'training',open_payments:people(r.id).filter(x=>x.due_actual>0).length}))),
    admin_training_work_get: a => { const {p,r}=assertTraining(a.p_rule_id);return {rule:ruleObj(p,r),people:people(r.id),work:work(r.id),waitlist:orderedWaiters(waiters.filter(w=>w.rule_id===r.id&&['waiting','offered'].includes(w.status))),messages:st.messages.filter(m=>m.rule_id===r.id)}; },
    admin_training_work_save: a => { assertTraining(a.p_rule_id);works.set(a.p_rule_id,{materials_shared:a.p_materials_shared,templates:a.p_templates});return {ok:true}; },
    admin_training_person_save: a => { details.set(a.p_reservation_id,a.p_details);return {ok:true}; },
    admin_training_person_add: a => { const {r}=assertTraining(a.p_rule_id);if(r.sold_persons>=r.max_persons)throw err('capacity_exceeded'); const id=10000+st.participants.length;st.participants.push({...a.p_customer,reservation_id:id,order_id:id,order_no:id,rule_id:r.id,persons:1,order_status:'confirmed',payment_status:'unpaid'});r.sold_persons++;return {ok:true}; },
    admin_training_space_add: a => { const {p,r}=assertTraining(a.p_rule_id);const start=helsinkiIso(`${a.p_date}T${a.p_start}`),end=helsinkiIso(`${a.p_date}T${a.p_end}`);const all=st.events.flatMap(p=>p.rules.flatMap(r=>ruleObj(p,r).blocks)); if(all.some(b=>b.resource_id===a.p_space_id&&b.starts_at<end&&b.ends_at>start))throw err('conflict');r.blocks.push({id:++st.blockSeq,resource_id:a.p_space_id,mode:'exclusive',starts_at:start,ends_at:end});return {ok:true}; },
    admin_training_space_cancel: a => { if(!a.p_confirm)throw err('no_confirm');const {r}=assertTraining(a.p_rule_id);r.blocks=r.blocks.filter(b=>b.id!==a.p_block_id);return {ok:true}; },
    admin_training_waitlist_add: a => {assertTraining(a.p_rule_id);const id=waiters.length+1;waiters.push({id,rule_id:a.p_rule_id,...a.p_person,status:'waiting',created_at:new Date().toISOString()});return {ok:true,id};},
    admin_training_waitlist_update: a => { const w=waiters.find(w=>w.id===a.p_id&&w.rule_id===a.p_rule_id);if(!w)throw err('not_found');if(a.p_status==='offered'&&orderedWaiters(waiters.filter(x=>x.rule_id===a.p_rule_id&&['waiting','offered'].includes(x.status)))[0]?.id!==w.id)throw err('queue_order');w.status=a.p_status;return {ok:true}; },
    admin_training_message_preview: a => { const id=`mock-${previews.size+1}`, rows=recipients(a.p_rule_id);if(!rows.length)throw err('no_recipients');const pv={id,rule_id:a.p_rule_id,recipients:rows,content:a.p_content};previews.set(id,structuredClone(pv));return pv; },
    admin_training_message_send: a => { const pv=previews.get(a.p_preview_id);if(!a.p_confirm||!pv)throw err('no_confirm');if(pv.sent)return {ok:true,queued_count:0};if(JSON.stringify(pv.recipients)!==JSON.stringify(recipients(pv.rule_id)))throw err('preview_changed');pv.sent=true;st.messages.push({rule_id:pv.rule_id,subject:pv.content.fi.subject,queued_count:pv.recipients.length,created_at:new Date().toISOString()});return {ok:true,queued_count:pv.recipients.length}; },
    admin_calendar_space_blocks: a => st.events.flatMap(p=>p.rules.flatMap(r=>ruleObj(p,r).blocks)).filter(b=>b.resource_kind==='space'&&b.starts_at<a.p_to&&b.ends_at>a.p_from).map(b=>({...b,space_id:b.resource_id,space_name:b.resource_name,reason:'Koulutus'})),
    admin_training_session_copy: a => { const {p,r}=assertTraining(a.p_rule_id),delta=Math.round((Date.parse(`${a.p_date}T12:00Z`)-Date.parse(`${r.date}T12:00Z`))/864e5),product_id=++st.productSeq,id=++st.ruleSeq;const copy=structuredClone(p);copy.product_id=product_id;copy.name=a.p_name;copy.active=false;copy.rules=[{...structuredClone(r),id,date:a.p_date,sold_persons:0,reservation_count:0,blocks:r.blocks.map(b=>{const row={...b,id:++st.blockSeq};if(!('offset_min' in row)){for(const k of ['starts_at','ends_at']){const part=localParts(row[k]);row[k]=helsinkiIso(`${addDays(part.date,delta)}T${part.time}`);}}return row;})}];st.events.push(copy);works.set(id,{templates:structuredClone(work(r.id).templates),materials_shared:false});return {ok:true,product_id,rule_id:id}; },
  };
}
