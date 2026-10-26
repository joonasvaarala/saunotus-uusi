import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { canAddPurchase, afterAddChoices, reservationDeepLink, orderDeepLink, newPurchaseItem, isFlowEnabledValue } from '../admin/order-reservation-logic.js';


const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const src = (p) => readFileSync(resolve(root,p),'utf8');

test('oikeudet, Johku ja kytkin päältä', () => {
  const native = { is_native:true, staff_can_add:true, status:'confirmed' };
  const yes = { can:(p)=>p==='bookings.manage' };
  assert.deepEqual(canAddPurchase(native,yes,true),{allowed:true,reason:null});
  assert.equal(canAddPurchase(native,yes,false).reason,'flag_off');
  assert.equal(canAddPurchase(native,{can:()=>false},true).reason,'no_permission');
  assert.equal(canAddPurchase({...native,is_native:false},yes,true).reason,'johku');
  assert.equal(canAddPurchase({...native,external_source:'johku'},yes,true).reason,'johku');
  assert.equal(canAddPurchase({...native,staff_can_add:false},yes,true).reason,'closed');
  assert.equal(isFlowEnabledValue([{value:false}]),false);
  assert.equal(isFlowEnabledValue([{value:true}]),true);
  assert.equal(isFlowEnabledValue([]),false);
});
test('maksun kirjaus ja linkin luonti vain maksuoikeudella ja avoimelle saldolle', () => {
  assert.deepEqual(afterAddChoices({unpaid:23},(x)=>x==='payments.manage'),{unpaid:23,link:true,record:true,leave:true});
  assert.deepEqual(afterAddChoices({unpaid:0},()=>true),{unpaid:0,link:false,record:false,leave:true});
  assert.equal(afterAddChoices({unpaid:12},()=>false).link,false);
});
test('syvälinkit koodaavat parametrit', () => {
  assert.equal(reservationDeepLink(42),'#/tilaukset?tab=reservations&id=42&period=all');
  assert.equal(orderDeepLink('A&B'),'#/tilaukset?order=A%26B');
});
test('rivityypit ovat rajattuja ja hinta tulee palvelimelta', () => {
  const addon = newPurchaseItem('addon',{reservation_id:13,code:'saunavihta',quantity:1,amount:400});
  assert.deepEqual(addon,{type:'addon',reservation_id:13,code:'saunavihta',quantity:1});
  assert.deepEqual(newPurchaseItem('reservation',{rule_id:4,date:'2027-01-01',persons:2,quantity:1}),{type:'reservation',rule_id:4,date:'2027-01-01',persons:2});
  assert.deepEqual(newPurchaseItem('product',{product_id:5,quantity:2,price:3}),{type:'product',product_id:5,quantity:2});
  assert.throws(()=>newPurchaseItem('addon',{reservation_id:13,code:'x',quantity:0}));
  assert.throws(()=>newPurchaseItem('custom',{description:'',amount:1,vat_rate:0,quantity:1}));
});
test('FI/EN-tekstiavaimet ja XSS: tuotenimi ei päädy innerHTML:ään',()=>{
  const textSource = src('booking/admin/orders-texts.js');
  assert.match(textSource,/open_reservation_label/);
  assert.match(textSource,/Open booking:/);
  assert.match(textSource,/Avaa varaus:/);
  assert.match(src('booking/admin/views/order-add.js'),/h\('span', \{ text: x\.name/);
  assert.doesNotMatch(src('booking/admin/views/order-add.js'),/innerHTML|insertAdjacentHTML|eval\(/);
});
test('ei lähetyksiä lisäostossa eikä maksulinkissä',()=>{
  const code=src('booking/admin/views/order-add.js');
  assert.match(code,/addToOrder\(\{[^}]*sendEmail: false/s);
  assert.match(code,/createPaymentLink\(\{[^}]*sendEmail: false/s);
  assert.doesNotMatch(code,/sendEmail:\s*true|p_send_email:\s*true/);
});
test('tilausrivin painike, suora admin-haku, kytkin ja fallback',()=>{
  const srcBridge=src('booking/admin/views/order-reservation-bridge.js');
  assert.match(srcBridge,/order-open-reservation/);
  assert.match(srcBridge,/p_reservation_id/);
  assert.match(srcBridge,/reservationDeepLink/);
  assert.match(srcBridge,/reservationDialog/);
  assert.match(srcBridge,/canAddPurchase/);
  assert.match(srcBridge,/data-action=/);
  assert.match(srcBridge,/MutationObserver/);
  assert.doesNotMatch(srcBridge,/innerHTML|insertAdjacentHTML/);
});
test('kytkin ja vanhan toiminnan säilyttäminen',()=>{
  const js=src('booking/admin/views/orders.js');
  assert.match(js,/admin_order_reservation_flow_enabled/);
  assert.match(js,/if \(flowEnabled\) \{\s*try \{ \(await import\('\.\/order-reservation-bridge\.js'\)\)\.installOrderReservationBridge/);
  assert.doesNotMatch(js,/^import [^\n]*order-reservation-bridge/m);
  assert.match(js,/admin_order_reservation_flow_enabled[^\n]*\n\s*if \(seq !== sequence\) return;/);
});
test('uudet moduulit ovat syntaktisesti kelvollisia (node --check)',()=>{
  for (const f of ['booking/admin/order-reservation-logic.js','booking/admin/views/order-add.js','booking/admin/views/order-reservation-bridge.js','booking/admin/views/orders.js','booking/admin/orders-texts.js']) {
    const r=spawnSync(process.execPath,['--check',resolve(root,f)],{encoding:'utf8'});
    assert.equal(r.status,0,`${f}: ${r.stderr}`);
  }
});
