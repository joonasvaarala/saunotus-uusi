import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,existsSync,readdirSync} from 'node:fs';
import {renderNewsletter,newsletterUrl} from '../supabase/functions/_shared/newsletter-render.js';
import {newsletterCanSend,newsletterPatch,NEWSLETTER_SEGMENTS} from '../admin/newsletter-logic.js';
import {NEWSLETTER_TEXTS} from '../admin/newsletter-texts.js';
const read=p=>readFileSync(new URL('../../'+p,import.meta.url),'utf8');
const data={subject:'Löylyn äärellä',body:'Ensimmäinen kappale.\n\nToinen kappale.\nUusi rivi.',locale:'fi',style:{layout:'editorial',accent:'#445566',background:'#f4f1e9',image_url:'https://saunotus.fi/kuva.jpg',cta_url:'https://saunotus.fi/lahjakortti/',cta_fi:'Avaa',cta_en:'Open'},unsubscribe_url:'https://saunotus.fi/tilaus/?u=test'};
test('newsletter renderer is standalone, branded, responsive and keeps the bot style',()=>{
 const out=renderNewsletter(data);
 assert.match(out.html,/<html lang="fi"/);assert.match(out.html,/#445566/);assert.match(out.html,/font-size:38px/);
 assert.match(out.html,/max-width:640px/);assert.match(out.html,/width:100%/);assert.match(out.html,/Havuhattu Oy/);
 assert.match(out.html,/Toinen kappale\.<br>Uusi rivi/);assert.match(out.text,/Avaa: https:/);
 assert.doesNotMatch(out.html,/Tapahtuma:|Aika:|event_message/);
});
test('marketing opt-out is mandatory and localized',()=>{
 assert.equal(renderNewsletter({...data,unsubscribe_url:null}),null);
 assert.match(renderNewsletter(data).html,/Peruuta uutiskirjeet/);
 assert.match(renderNewsletter({...data,locale:'en'}).html,/Unsubscribe from newsletters/);
 assert.match(renderNewsletter({...data,locale:'en'}).text,/Open: https:/);
});
test('all bot text is escaped; unsafe URLs and CSS never enter HTML',()=>{
 const out=renderNewsletter({...data,subject:'<script>alert(1)</script>',body:'<img src=x onerror=alert(1)> & "text"',style:{layout:'letter',background:'red;position:fixed',accent:'#fff" onmouseover="bad',image_url:'javascript:bad()',cta_url:'https://user:pass@example.test',cta_fi:'Unsafe'}});
 assert.doesNotMatch(out.html,/<script|<img src=x|position:fixed|onmouseover|javascript:|user:pass/);
 assert.match(out.html,/&lt;script&gt;/);assert.match(out.html,/&lt;img/);
});
test('URL allowlist requires credential-free HTTPS and blocks attribute injection',()=>{
 for(const url of ['javascript:alert(1)','data:image/png;base64,x','http://example.test','https://x.test/" onclick="x','https://user:pass@x.test','https://x.test/\nnext'])assert.equal(newsletterUrl(url),'');
 assert.equal(newsletterUrl('https://saunotus.fi/varaa/'),'https://saunotus.fi/varaa/');
});
test('human editor patch cannot include style, schedule or template HTML',()=>{
 const elements=Object.fromEntries(['subject_fi','subject_en','body_fi','body_en','segment','language','style','html','suggested_send_at'].map(k=>[k,{value:k}]));
 assert.deepEqual(Object.keys(newsletterPatch({elements})),['subject_fi','subject_en','body_fi','body_en','segment','language']);
 assert.equal(NEWSLETTER_SEGMENTS.length,7);
});
test('confirmation gate invalidates on edits, expiry, version or state change',()=>{
 const now=Date.now(),draft={version:4,state:'previewed'},preview={version:4,preview_token:'id',recipient_count:2,at:now};
 assert.equal(newsletterCanSend(preview,draft,false,now),true);
 for(const [p,d,dirty,t] of [[preview,draft,true,now],[preview,{...draft,version:5},false,now],[preview,{...draft,state:'sent'},false,now],[preview,draft,false,now+1800000],[{...preview,recipient_count:0},draft,false,now],[{...preview,recipient_count:5001},draft,false,now]])assert.equal(newsletterCanSend(p,d,dirty,t),false);
});
test('pending-import FI/EN texts exactly match all fallbacks',()=>{
 const rows=JSON.parse(read('content/site-texts.pending-import-146.json'));
 for(const lang of ['fi','en'])for(const [key,text]of Object.entries(NEWSLETTER_TEXTS[lang]))assert.equal(rows.find(r=>r.key==='admin.newsletter.'+key&&r.lang===lang)?.text,text);
});
test('sender resolves fresh consent payload before allowlist/render and retains privacy-safe failure messages',()=>{
 const code=read('booking/supabase/functions/send-emails/index.ts');
 assert.ok(code.indexOf('email_newsletter_payload')<code.indexOf('const blocked = outboxAllowlistBlock'));
 assert.match(code,/newsletter\?\.allowed !== true/);assert.match(code,/renderNewsletter\(newsletter\)/);
 assert.match(code,/r.kind === "newsletter" \? "newsletter_delivery_failed"/);
 assert.match(code,/r.kind === "newsletter" \? "newsletter_dry_run"/);
});
test('isolated entry and route integration hook do not require shell/nav edits',()=>{
 const code=read('booking/admin/newsletters.html');
 assert.match(code,/noindex,nofollow/);assert.match(code,/newsletter-page.js/);
 const view=read('booking/admin/views/newsletters.js');
 assert.match(view,/sandbox:''/);assert.match(view,/default-src/);assert.match(view,/p_confirm:false/);assert.match(view,/p_confirm:true/);
 assert.doesNotMatch(view,/console\.log|innerHTML/);
});


test('scoped opt-out is explicit, clears its opaque fragment and has no admin session requirement',async()=>{
 const js=readFileSync(new URL('../admin/newsletter-unsubscribe.js',import.meta.url),'utf8');
 const sql=readFileSync(new URL('../supabase/migrations/20261106223314_booking_259_newsletters.sql',import.meta.url),'utf8');
 assert.match(js,/history\.replaceState/);assert.match(js,/onclick:async/);
 assert.match(js,/rpc\('public_newsletter_unsubscribe'/);assert.doesNotMatch(js,/getSession|console\./);
 assert.doesNotMatch(sql,/create (?:or replace )?function booking\.public_marketing_unsubscribe/i);
 assert.match(sql,/create unique index newsletter_outbox_address_uq/);
 assert.match(sql,/status in \('failed','dead'\)/);
 assert.match(sql,/booking\._newsletter_fingerprint\(c\.email\) is distinct from expected/);
});


test('permanent suppression lifecycle is independent of feature rollback and re-enable',()=>{
 const core=read('booking/supabase/migrations/20261106223314_booking_259_newsletters.sql');
 const rollback=read('booking/supabase/rollbacks/20261106223314_booking_259_ROLLBACK.sql');
 const hook=read('booking/supabase/migrations/20261106223319_booking_262_newsletter_capture.sql');
 const enable=read('booking/docs/newsletter-reenable-proposal.sql');
 const fixture=read('booking/supabase/tests/newsletters/local-fixture.sql');
 const shared=read('booking/supabase/migrations/20261021145208_booking_121_messages.sql');
 const contract=shared.slice(shared.indexOf('create function booking.public_marketing_unsubscribe('),shared.indexOf('\n--',shared.indexOf('grant execute on function booking.public_marketing_unsubscribe')));
 assert.ok(fixture.includes(contract.trim()),'disposable fixture must use real unchanged shared token RPC');
 assert.match(fixture,/constraint schedule_rules_event_shape/);
 assert.equal((core.match(/t\.tgname='newsletter_capture_general_optout'/g)||[]).length,2,'capture is hard gate in BOTH dispatch and payload');
 assert.match(core,/insert into booking\.newsletter_suppressions\(address_fingerprint\)\s*select distinct/i);
 assert.ok(core.indexOf('lock table booking.customers')<core.indexOf('create sequence'),'259 locks before ANY newsletter DDL');
 assert.doesNotMatch(hook,/^begin;|^commit;/mi,'262 must compose in one caller-owned transaction');
 assert.ok(core.indexOf('lock table')<core.indexOf('create trigger'));
 assert.ok(core.indexOf('create trigger')<core.indexOf('select distinct booking._newsletter_fingerprint'));
 assert.doesNotMatch(hook,/^(?:create|alter|drop|insert|update|delete|truncate|lock table|notify|grant|revoke) /mi,'262 verifies only');
 assert.match(hook,/p\.prosrc/);assert.match(hook,/t\.tgtype=21/);
 assert.doesNotMatch(core,/^begin;|^commit;/mi,'official apply_migration owns259 transaction/history');
 assert.doesNotMatch(rollback,/^drop (?:table|function|trigger|index).*?(?:newsletter_suppressions|newsletter_optout_tokens|newsletter_capture_general_optout|_newsletter_fingerprint|_newsletter_address_blocked|public_newsletter_unsubscribe|newsletter_customers_optout_email_idx|newsletter_campaign_id_seq|newsletter_log_id_seq)/mi);
 assert.doesNotMatch(enable,/^(?:drop |truncate |delete |create sequence|alter sequence|select setval)/mi);
 assert.match(core,/create sequence booking\.newsletter_log_id_seq as bigint no cycle cache 1 owned by none/);
 assert.match(core,/default nextval\('booking\.newsletter_campaign_id_seq'/);
 assert.match(core,/default nextval\('booking\.newsletter_log_id_seq'/);
 assert.match(enable,/next_log<=retained_max/);
 assert.doesNotMatch(enable,/^create (?:table|function).*?(?:newsletter_suppressions|newsletter_optout_tokens|_newsletter_fingerprint|_newsletter_address_blocked|public_newsletter_unsubscribe)/mi);
 const featureHead=core.slice(core.indexOf('create table booking.newsletters'),core.indexOf('-- Separate, durable'));
 assert.ok(enable.includes(featureHead),'re-enable feature schema must match259');
 const featureFunctions=core.slice(core.indexOf('-- Helpers are in the non-public'),core.indexOf('-- Revoke every direct/default'));
 assert.ok(enable.includes(featureFunctions),'re-enable must not drift from reviewed feature RPCs');
 for(const sql of [core,hook,enable,rollback])assert.doesNotMatch(sql,/^create (?:or replace )?function booking\.public_marketing_unsubscribe/mi);
});


test('reservation scenarios cannot be mistaken for the sole hosted capture candidate',()=>{
 const tests=new URL('../supabase/tests/',import.meta.url);
 assert.deepEqual(readdirSync(tests).filter(p=>/^t259_newsletters.*hosted_safe\.sql$/.test(p)),['t259_newsletters_capture_hosted_safe.sql']);
 assert.equal(existsSync(new URL('t259_newsletters_attendance_hosted_safe.sql',tests)),false);
 assert.match(read('booking/supabase/tests/t259_newsletters_attendance_local_only.sql'),/NEVER DEV\/PROD/);
 assert.doesNotMatch(read('booking/supabase/tests/t259_newsletters_capture_hosted_safe.sql'),/insert into booking\.(?:reservations|orders|schedule_rules)/i);
 const captureRollback=read('booking/supabase/rollbacks/20261106223319_booking_262_ROLLBACK.sql');
 assert.match(captureRollback,/raise exception/i);assert.doesNotMatch(captureRollback,/^(?:drop|alter|delete|truncate) /mi);
});
