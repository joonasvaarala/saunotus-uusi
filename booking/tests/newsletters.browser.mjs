// Run after npm run build:test. All Supabase calls are mocked; never sends real mail.
import {chromium} from 'playwright-core';
import {createServer} from 'node:http';
import {readFileSync} from 'node:fs';
import {resolve,extname} from 'node:path';
import assert from 'node:assert/strict';
const root=resolve('dist'), server=createServer((req,res)=>{
 try{const path=resolve(root,'.'+new URL(req.url,'http://localhost').pathname);if(!path.startsWith(root+'/'))throw Error();
 const content=readFileSync(path);res.setHeader('content-type',({'.html':'text/html','.js':'text/javascript','.css':'text/css','.svg':'image/svg+xml'})[extname(path)]||'application/octet-stream');res.end(content);
 }catch{res.statusCode=404;res.end();}
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const base=`http://127.0.0.1:${server.address().port}`;
const browser=await chromium.launch({executablePath:process.env.CHROME||'/opt/google/chrome/chrome',args:['--no-sandbox']});
let sends=0,saves=0,previews=0;
try{
 for(const viewport of [{width:1280,height:900},{width:390,height:844}]){
  let draft={id:1,version:1,state:'draft',subject_fi:'Testiluonnos',subject_en:'Test draft',body_fi:'Tämä on testiluonnos.',body_en:'This is a test draft.',segment:'all',language:'all',style:{layout:'letter',accent:'#445566'}};
  const ctx=await browser.newContext({viewport});
  await ctx.addInitScript(()=>localStorage.setItem('booking.session',JSON.stringify({access_token:'synthetic-test-session',expires_at:Math.floor(Date.now()/1000)+3600,user:{id:'synthetic-staff'}})));
  const page=await ctx.newPage(), errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.route('**/*',async route=>{
   const url=new URL(route.request().url());
   if(url.origin===base)return route.continue();
   const name=url.pathname.split('/').at(-1), p=route.request().postDataJSON();
   let out;
   if(name==='public_get_site_texts')out={texts:[]};
   else if(name==='admin_my_permissions')out={permissions:['messages.edit']};
   else if(name==='admin_newsletters_list')out=[draft];
   else if(name==='admin_newsletter_save'){saves++;draft={...draft,...p.p_data,version:draft.version+1,state:'draft'};out=draft;}
   else if(name==='admin_newsletter_dispatch'){
    if(p.p_confirm){assert.equal(p.p_preview_token,'synthetic-preview-token');sends++;draft.state='sent';out={sent:true,recipient_count:2,queued_count:2};}
    else{previews++;out={sent:false,version:draft.version,recipient_count:2,fi_count:1,en_count:1,preview_token:'synthetic-preview-token'};}
   }else throw new Error('Unexpected external request '+name);
   await route.fulfill({contentType:'application/json',body:JSON.stringify(out),headers:{'access-control-allow-origin':'*'}});
  });
  await page.goto(base+'/hallinta/newsletters.html');
  await page.getByRole('heading',{name:'Uutiskirjeet',exact:true}).waitFor();
  const send=page.getByRole('button',{name:'Lähetä uutiskirje',exact:true});
  assert.equal(await send.isDisabled(),true);
  await page.getByRole('button',{name:'Tallenna ja esikatsele',exact:true}).click();
  await page.getByText('Vastaanottajia: 2 (FI 1, EN 1).',{exact:true}).waitFor();
  assert.equal(await send.isEnabled(),true);
  assert.equal(await page.locator('iframe[sandbox]').count(),2);
  assert.equal(await page.locator('[name="subject_fi"]').isEnabled(),true);
  await page.locator('[name="subject_fi"]').fill('Muokattu testiluonnos');
  assert.equal(await send.isDisabled(),true);assert.equal(await page.locator('iframe').count(),0);
  await page.getByRole('button',{name:'Tallenna ja esikatsele',exact:true}).click();
  await page.getByText('Vastaanottajia: 2 (FI 1, EN 1).',{exact:true}).waitFor();
  await send.click();
  assert.equal(sends,viewport.width===1280?0:1,'opening confirmation does not dispatch');
  await page.getByRole('button',{name:'Peruuta',exact:true}).click();
  await send.click();
  await page.locator('[data-testid="confirm-yes"]').click();
  await page.getByText('Uutiskirje lisätty lähetysjonoon. Tämä ei vielä vahvista toimitusta.',{exact:true}).waitFor();
  assert.equal(await send.isDisabled(),true);
  assert.equal(await page.locator('[name="subject_fi"]').isDisabled(),true);
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth),true,'no horizontal overflow');
  assert.deepEqual(errors,[]);
  console.log(`PASS newsletter browser ${viewport.width}px: save, preview, edit invalidation, cancel, confirmed send, lock`);
  await ctx.close();
 }
 assert.equal(sends,2);assert.equal(previews,4);assert.equal(saves,4);
 // Anonymous page must offer existing admin sign-in, never display author/send controls.
 const ctx=await browser.newContext();const page=await ctx.newPage();
 await page.route('**/rest/v1/rpc/**',r=>r.fulfill({contentType:'application/json',body:'{"texts":[]}'}));
 await page.goto(base+'/hallinta/newsletters.html');
 await page.getByText('Kirjaudu ensin hallintaan ja palaa sitten tälle sivulle.',{exact:true}).waitFor();
 assert.equal(await page.getByRole('button',{name:'Lähetä uutiskirje',exact:true}).count(),0);
 console.log('PASS newsletter browser anonymous session gate');
 const publicErrors=[];page.on('pageerror',e=>publicErrors.push(e.message));
 let optoutCalls=0;
 await page.route('**/rest/v1/rpc/public_newsletter_unsubscribe',async route=>{
  optoutCalls++;assert.equal(route.request().method(),'POST');
  assert.equal(route.request().postDataJSON().p_token,'00000000-0000-4000-8000-000000000259');
  await route.fulfill({contentType:'application/json',body:'{"ok":true}',headers:{'access-control-allow-origin':'*'}});
 });
 for(const lang of ['fi','en']){
  const before=optoutCalls;
  await page.goto(`${base}/hallinta/newsletter-unsubscribe.html#token=00000000-0000-4000-8000-000000000259&lang=${lang}`);
  const button=page.getByRole('button',{name:lang==='en'?'Confirm newsletter unsubscribe':'Vahvista uutiskirjeiden peruutus'});
  await button.waitFor();assert.equal(new URL(page.url()).hash,'');assert.equal(optoutCalls,before,'Opening link must not unsubscribe');
  assert.equal(await page.locator('#newsletter-view').count(),0,'Public opt-out must not render admin');
  await button.click();await page.getByRole('status').filter({hasText:lang==='en'?'Unsubscribe processed.':'Peruutus on käsitelty.'}).waitFor();
  assert.equal(optoutCalls,before+1);
 }
 await page.goto(`${base}/hallinta/newsletter-unsubscribe.html#token=invalid&lang=en`);
 await page.getByRole('alert').waitFor();
 assert.equal(await page.getByRole('button').count(),0);assert.equal(optoutCalls,2);
 assert.deepEqual(publicErrors,[]);await ctx.close();
 console.log('Public FI/EN explicit opt-out, invalid link and fragment privacy PASS');
}finally{await browser.close();await new Promise(r=>server.close(r));}
