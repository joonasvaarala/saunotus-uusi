import json,time,sys,os
sys.path.insert(0,'/workspace/johku/tools')
import johku_api as J
vc=json.load(open('/workspace/johku/export/valuecards.json'))
sel=[v for v in vc if str(v['status'])=='1' and int(v['created'])>=1744837200]
OUT='vc_detail.json'
out=json.load(open(OUT)) if os.path.exists(OUT) else {}
fails={}; t0=time.time(); n403=0; ncalls=0
for i,v in enumerate(sel):
    if v['id'] in out: continue
    ok=False
    for att in range(8):
        s,d=J.get(f"valuecards/{v['code']}.json",{"details":"true"},retries=0)
        ncalls+=1
        if s==200 and isinstance(d,dict) and d.get('code')==v['code']: ok=True; break
        if s==403 and not d: n403+=1; time.sleep(3); continue
        if s in (404,): break
        time.sleep(3)
    if not ok:
        fails[v['id']]=s; print('FAIL',v['id'],s,flush=True); continue
    out[v['id']]={'id':d['id'],'code':d['code'],'value':d['value'],'remainingvalue':d.get('remainingvalue'),'remainingcount':d.get('remainingcount'),'validto':d.get('validto'),'status':d.get('status'),'order_id':d.get('order_id'),'singleorder':d.get('singleorder'),'singleuse':d.get('singleuse'),
      'pay':[{k:p.get(k) for k in('id','paymentdate','method','amount','bill_id','vat','surplus')} for p in d.get('ownPayment') or []],
      'fetched_at':int(time.time())}
    if len(out)%10==0:
        json.dump(out,open(OUT,'w')); os.chmod(OUT,0o600); print('n',len(out),'calls',ncalls,'403',n403,'t',int(time.time()-t0),flush=True)
json.dump(out,open(OUT,'w')); os.chmod(OUT,0o600)
json.dump(fails,open('fails.json','w'))
print('DONE',len(out),len(fails),flush=True)
