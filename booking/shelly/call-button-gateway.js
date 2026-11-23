// Saunotus – terassin hälytysnappi: Shelly BLU Gateway Gen3 -skripti (mJS). booking_340–342.
// Kuuntelee BLE-mainoksia, jäsentää BTHome v2 -paketit (service data UUID fcd2) ja välittää VAIN button-objektit (0x3A)
// Supabasen call-button-press-funktioon. Muut BLE-laitteet ja muut BTHome-objektit jätetään huomiotta.
// Kaikki button-tapahtumat välitetään (Joonas t1926u), vain 0 (none) jätetään pois.
//
// Asetukset KVS:ssä (EI koodissa eikä repossa):
//   cb_url      https://<project>.supabase.co/functions/v1/call-button-press
//   cb_secret   CALL_BUTTON_WEBHOOK_SECRET (sama kuin Supabasen salaisuus)
//   cb_gateway  tämän vastaanottimen tunniste, esim. gw-mokki tai gw-ylaterassi
// Asennusohje: booking/shelly/README.md

let CFG = { url: "", secret: "", gateway: "" };
let RETRY_DELAYS_MS = [1000, 3000]; // 2 uusintaa: 1 s ja 3 s
let HTTP_TIMEOUT_S = 15;
let BTHOME_UUID = "fcd2";

// BTHome 0x3A -arvo → tapahtumanimi (KOODARI.md). Tuntematon nollasta poikkeava → "press" (kanta hyväksyy, soittaa).
let BUTTON_EVENTS = { 1: "single_push", 2: "double_push", 3: "triple_push", 4: "long_push", 5: "long_double_push", 6: "long_triple_push", 128: "hold" };

// BTHome v2 -objektien datan pituus tavuina (id → koko). Tuntematon id lopettaa jäsennyksen.
let SIZES = {
  0x00: 1, 0x01: 1, 0x02: 2, 0x03: 2, 0x04: 3, 0x05: 3, 0x06: 2, 0x07: 2, 0x08: 2, 0x09: 1, 0x0a: 3, 0x0b: 3,
  0x0c: 2, 0x0d: 2, 0x0e: 2, 0x0f: 1, 0x10: 1, 0x11: 1, 0x12: 2, 0x13: 2, 0x14: 2, 0x2e: 1, 0x2f: 1, 0x3a: 1,
  0x3c: 2, 0x3d: 2, 0x3e: 4, 0x3f: 2, 0x40: 2, 0x41: 2, 0x42: 3, 0x43: 2, 0x44: 2, 0x45: 2, 0x46: 1, 0x47: 2,
  0x48: 2, 0x49: 2, 0x4a: 2, 0x4b: 3, 0x4c: 4, 0x4d: 4, 0x4e: 4, 0x4f: 4, 0x50: 4, 0x51: 2, 0x52: 2,
  0xf0: 2, 0xf1: 4, 0xf2: 3
};
for (let i = 0x15; i <= 0x2d; i++) SIZES[i] = 1; // binääriset sensorit

let lastPid = {}; // mac → viimeksi välitetty pid (BLU lähettää saman mainoksen useasti)

function byteAt(s, i) {
  let b = s.at(i);
  if (typeof b === "string") b = b.charCodeAt(0); // (Node-testiympäristö)
  return b & 0xff;
}

// Palauttaa { pid, battery, buttons: [arvo, …] } tai null (ei BTHome v2, salattu tai virheellinen).
function parseBTHome(data) {
  if (typeof data !== "string" || data.length < 1) return null;
  let info = byteAt(data, 0);
  if ((info & 0x01) !== 0) return null; // salattu → ei tueta (älä ota salausta käyttöön napeissa)
  if (((info >> 5) & 0x07) !== 2) return null; // vain BTHome v2
  let out = { pid: null, battery: null, buttons: [] };
  let i = 1;
  while (i < data.length) {
    let id = byteAt(data, i);
    let size = SIZES[id];
    if (size === undefined || i + 1 + size > data.length) break;
    if (id === 0x00) out.pid = byteAt(data, i + 1);
    else if (id === 0x01) out.battery = byteAt(data, i + 1);
    else if (id === 0x3a) out.buttons.push(byteAt(data, i + 1));
    i += 1 + size;
  }
  return out;
}

function eventName(v) {
  let n = BUTTON_EVENTS[v];
  return n ? n : "press";
}

function post(body, attempt) {
  Shelly.call("HTTP.Request", {
    method: "POST",
    url: CFG.url,
    headers: { "content-type": "application/json", "x-call-button-secret": CFG.secret },
    body: body,
    timeout: HTTP_TIMEOUT_S
  }, function (res, errCode, errMsg) {
    let code = res && typeof res.code === "number" ? res.code : 0;
    if (errCode === 0 && code >= 200 && code < 300) return;
    // uusinta vain verkkovirheelle, 429:lle ja 5xx:lle (4xx = asetusvirhe, uusinta ei auta)
    let retryable = errCode !== 0 || code === 0 || code === 429 || code >= 500;
    print("call-button: POST epäonnistui (yritys " + (attempt + 1) + ", http " + code + ", err " + errCode + ")");
    if (retryable && attempt < RETRY_DELAYS_MS.length) {
      Timer.set(RETRY_DELAYS_MS[attempt], false, function () { post(body, attempt + 1); });
    }
  });
}

function onScan(ev, res) {
  if (ev !== BLE.Scanner.SCAN_RESULT || !res || !res.service_data) return;
  let data = res.service_data[BTHOME_UUID];
  if (typeof data !== "string") return;
  let p = parseBTHome(data);
  if (!p || p.buttons.length === 0) return;
  let mac = String(res.addr).toLowerCase();
  if (p.pid !== null && lastPid[mac] === p.pid) return; // sama mainos uudelleen
  for (let k = 0; k < p.buttons.length; k++) {
    let v = p.buttons[k];
    if (v === 0) continue; // none
    if (!CFG.url || !CFG.secret) { print("call-button: KVS-asetukset puuttuvat (cb_url/cb_secret)"); return; }
    let payload = { mac: mac, pid: p.pid, event: eventName(v), gateway: CFG.gateway, rssi: res.rssi };
    if (p.battery !== null) payload.battery = p.battery;
    post(JSON.stringify(payload), 0);
    break; // yksi painallus = yksi viesti (sama pid deduppaantuisi kannassa joka tapauksessa)
  }
  if (p.pid !== null) lastPid[mac] = p.pid;
}

function kvs(key, cb) {
  Shelly.call("KVS.Get", { key: key }, function (r) { cb(r && typeof r.value === "string" ? r.value : ""); });
}

function start() {
  kvs("cb_url", function (u) {
    CFG.url = u;
    kvs("cb_secret", function (s) {
      CFG.secret = s;
      kvs("cb_gateway", function (g) {
        CFG.gateway = g ? g.slice(0, 100) : "";
        if (!CFG.gateway) {
          let info = Shelly.getDeviceInfo();
          CFG.gateway = info && info.id ? String(info.id) : "gw";
        }
        print("call-button: käynnissä, gateway=" + CFG.gateway + ", url " + (CFG.url ? "ok" : "PUUTTUU") + ", salaisuus " + (CFG.secret ? "ok" : "PUUTTUU"));
        if (!BLE.Scanner.isRunning()) BLE.Scanner.Start({ duration_ms: BLE.Scanner.INFINITE_SCAN, active: false });
        BLE.Scanner.Subscribe(onScan);
      });
    });
  });
}

start();
