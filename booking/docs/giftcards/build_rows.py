#!/usr/bin/env python3
"""Rakentaa svc_gift_cards_johku_upsert-rivit (955 Johku-korttia 17.4.2025 alkaen) + jaettuna SQL-tiedostoiksi.
Lähteet: Johku-export valuecards.json, staging order_items.jsonl, vc_detail.json (API-saldot; ei koskaan tulosteta/commitoida koodeineen).
Käyttö: build_rows.py <detail.json> <out_dir> [chunk=100]
Tulostiedostot (chmod 600) sisältävät koodit selkokielisinä -> EI repoon. Raportti (ilman koodeja) tulostuu stdoutiin."""
import json, sys, os, collections, datetime, zoneinfo
EXPORT='/workspace/johku/export/valuecards.json'
OI='/workspace/johku/import/staging/order_items.jsonl'
detail_path, out_dir = sys.argv[1], sys.argv[2]
chunk = int(sys.argv[3]) if len(sys.argv) > 3 else 100
vc = json.load(open(EXPORT))
sel = [v for v in vc if str(v['status']) == '1' and int(v['created']) >= 1744837200]
sel.sort(key=lambda v: int(v['id']))
oi = {}
for l in open(OI):
    r = json.loads(l); oi[r['external_id']] = r
det = json.load(open(detail_path))
HEL = zoneinfo.ZoneInfo('Europe/Helsinki')
def hdate(u): return datetime.datetime.fromtimestamp(int(u), HEL).date().isoformat()
rows = []; stats = collections.Counter(); notes = []
for v in sel:
    d = det.get(v['id'])
    it = oi[v['item_id']]
    value = float(v['value'])
    validto = int(d['validto']) if d and d.get('validto') not in (None, '', '0') else int(v['validto'])
    if validto == 0: stats['no_validto'] += 1; continue
    ledger = [{'at_unix': int(v['created']), 'seq': 0, 'delta': value, 'reason': 'johku_purchase', 'note': 'Johku-osto', 'meta': {'item_id': v['item_id'], 'voucher_id': v['voucher_id']}}]
    if d:
        remaining = float(d['remainingvalue'])
        run = value
        pays = sorted(d['pay'], key=lambda p: (int(p['paymentdate']), int(p['id'])))
        for i, p in enumerate(pays, 1):
            amt = float(p['amount'])
            if amt > run + 1e-9:
                stats['usage_clamped'] += 1; notes.append(('usage_clamped', v['id'])); amt = run
            if amt <= 0: continue
            run = round(run - amt, 2)
            ledger.append({'at_unix': int(p['paymentdate']), 'seq': i, 'delta': -amt, 'reason': 'johku_usage', 'note': 'Johku-lunastus (lasku %s)' % p.get('bill_id'),
                           'meta': {'bill_id': p.get('bill_id'), 'payment_id': p.get('id'), 'vat': p.get('vat')}})
        if abs(run - remaining) > 0.004:
            stats['adjust_row'] += 1; notes.append(('adjust_row', v['id'], round(remaining - run, 2)))
            ledger.append({'at_unix': int(d['fetched_at']), 'seq': 99, 'delta': round(remaining - run, 2), 'reason': 'johku_adjust', 'note': 'Johku-saldo ei täsmää käyttöriveihin (tuontihetken erotus)', 'meta': {'computed': run, 'johku_remaining': remaining}})
        balance = remaining; ver = True; src = 'johku_api'
        single = str(d.get('singleorder', v['singleorder'])) == '1'
        stats['verified'] += 1
    else:
        balance = value; ver = False; src = 'staging_unverified'; single = v['singleorder'] == '1'
        stats['unverified'] += 1
    rows.append({'external_id': v['id'], 'code': v['code'], 'kind': 'value' if str(v['voucher_id']) == '4' else 'product',
                 'product_id': str(it['product_id']) if it.get('product_id') else '', 'initial_amount': value, 'balance': balance,
                 'valid_to': hdate(validto), 'created_unix': int(v['created']), 'purchase_order_ext': it['order_ext'], 'purchase_item_ext': v['item_id'],
                 'sale_vat_rate': str(it['vat_rate']), 'balance_verified': ver, 'balance_source': src, 'single_order': single,
                 'meta': {'template': v['name'], 'voucher_id': v['voucher_id'], 'johku_validto_unix': validto, 'johku_value': value, 'detail_fetched_at': d['fetched_at'] if d else None}, 'ledger': ledger})
os.makedirs(out_dir, exist_ok=True); os.chmod(out_dir, 0o700)
for f in os.listdir(out_dir):
    if f.startswith('chunk_'): os.remove(os.path.join(out_dir, f))
n = 0
for i in range(0, len(rows), chunk):
    part = rows[i:i + chunk]
    p = os.path.join(out_dir, 'chunk_%02d.sql' % (i // chunk))
    with open(p, 'w') as f:
        f.write("select booking.svc_gift_cards_johku_upsert($j$" + json.dumps(part, ensure_ascii=False) + "$j$::jsonb) as r;\n")
    os.chmod(p, 0o600); n += 1
print(json.dumps({'rows': len(rows), 'chunks': n, 'stats': dict(stats), 'notes_n': len(notes), 'balance_total': round(sum(r['balance'] for r in rows), 2),
  'active_candidates': sum(1 for r in rows if r['balance'] > 0 and r['valid_to'] >= datetime.date.today().isoformat()), 'expired_with_balance': sum(1 for r in rows if r['balance'] > 0 and r['valid_to'] < datetime.date.today().isoformat()),
  'by_kind': dict(collections.Counter(r['kind'] for r in rows)), 'single_order': sum(r['single_order'] for r in rows)}))
