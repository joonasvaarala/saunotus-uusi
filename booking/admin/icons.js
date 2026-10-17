// Yksivärisiä viivaikoneita (24×24, Lucide/Feather-tyyliin itse piirretty yksinkertaiset muodot; ei ulkoisia riippuvuuksia).
// Väri tulee CSS:stä (currentColor); elementit luodaan createElementNS:llä vakiomääritelmistä (ei innerHTML:ää).
const P = (d) => ['path', { d }];
const C = (cx, cy, r) => ['circle', { cx, cy, r }];
const R = (x, y, width, height, rx = 0) => ['rect', { x, y, width, height, rx }];
const CAL = [R(3, 4, 18, 18, 2), P('M16 2v4M8 2v4M3 10h18')];
export const ICONS = {
  day: [...CAL, R(8, 14, 4, 4, 0.5)],                                                         // Päivä: kalenteri + tämän päivän ruutu
  list: [R(8, 2, 8, 4, 1), P('M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2M9 12h6M9 16h6')], // Varaukset: leikepöytä + lista
  calendar: [...CAL, P('M8 14h.01M12 14h.01M16 14h.01M8 18h.01M12 18h.01M16 18h.01')],        // Kalenteri: kuukausiruudukko
  plus: [C(12, 12, 10), P('M8 12h8M12 8v8')],                                                 // Uusi varaus
  users: [P('M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2'), C(9, 7, 4), P('M22 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75')], // Asiakkaat
  tag: [P('M12.586 2.586A2 2 0 0 0 11.172 2H4a2 2 0 0 0-2 2v7.172a2 2 0 0 0 .586 1.414l8.704 8.704a2.426 2.426 0 0 0 3.42 0l6.58-6.58a2.426 2.426 0 0 0 0-3.42z'), P('M7.5 7.5h.01')], // Tuotteet
  cabin: [P('M3 11l9-8 9 8M5 9.5V20h14V9.5M10 20v-6h4v6')],                                  // Resurssit: sauna/mökki
  sliders: [P('M3 6h9M16 6h5M3 12h3M10 12h11M3 18h11M18 18h3'), C(14, 6, 2), C(8, 12, 2), C(16, 18, 2)], // Asetukset
  lock: [R(4, 11, 16, 10, 2), P('M8 11V7a4 4 0 0 1 8 0v4')],                                    // Kalenterisulut: lukko
  check: [C(12, 12, 10), P('M8.5 12.5l2.5 2.5 4.5-5')],                                       // Tarkista: ympyrä + valintamerkki
  key: [P('M21 2l-9.6 9.6'), C(7.5, 15.5, 5.5), P('M15.5 7.5l3 3L22 7l-3-3')],                // Käyttäjät
  leaf: [P('M11 20A7 7 0 0 1 9.8 6.1C15.5 5 17 4.48 19 2c1 2 2 4.18 2 8 0 5.5-4.78 10-10 10z'), P('M2 21c0-3 1.85-5.36 5.08-6C9.5 14.52 12 13 13 12')], // Lisäpalvelut: lehti
  whisk: [P('M12 22v-8M10 14h4'), P('M12 14C8.5 12.5 7 8 9 3.5 12 5 13 9 12 14z'), P('M12 14c3.5-1.5 5-6 3-10.5-3 1.5-4 5.5-3 10.5z'), P('M12 14V5')],   // Saunavihta: sidottu vihta, lehdet
  mask: [P('M12 3c-4 0-7 3.5-7 8.5S8 21 12 21s7-4.5 7-9.5S16 3 12 3z'), P('M5.2 9.5C8 10.5 10 9.5 12 9.5s4 1 6.8 0'), P('M8.5 12.5c.7-.5 1.4-.5 2 0M13.5 12.5c.7-.5 1.4-.5 2 0M10 17h4')],   // Turvenaamio: kasvot, joilla hoitomaski
  towel: [P('M9 7V4h6v3'), P('M5 7h14a1 1 0 0 1 1 1v11a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V8a1 1 0 0 1 1-1z'), P('M4 12h16M4 16h16')],   // Pyyhe: ripustettu raidallinen pyyhe
  foot: [P('M4 15h16l-1.6 5H5.6z'), P('M9 15V5.5a2 2 0 0 1 4 0V15M13 12.5h2.5')],   // Jalkakylpy: jalka ammeessa
  euro: [P('M18 7c-1.3-1.4-3-2-4.8-2a7 7 0 0 0 0 14c1.8 0 3.5-.6 4.8-2'), P('M4 10.5h9M4 13.5h9')],         // Talous: euromerkki
  receipt: [P('M5 2h14v20l-3-2-2 2-2-2-2 2-2-2-3 2z'), P('M9 7h6M9 11h6M9 15h3')],                  // Kuitit
  link: [P('M10 13a5 5 0 0 0 7 0l3-3a5 5 0 0 0-7-7l-1 1'), P('M14 11a5 5 0 0 0-7 0l-3 3a5 5 0 0 0 7 7l1-1')],   // Maksulinkki
  undo: [P('M3 12a9 9 0 1 0 3-6.7L3 8'), P('M3 3v5h5')],                                           // Hyvitä
  download: [P('M12 3v12M7 10l5 5 5-5'), P('M4 20h16')],                                           // CSV-lataus
  print: [P('M7 9V3h10v6'), R(3, 9, 18, 8, 2), R(7, 14, 10, 7, 1)],                                // PDF / tulostus
  chev: [P('M6 9l6 6 6-6')],                                                                       // Laajenna rivi
  pgfirst: [P('M17 18l-6-6 6-6'), P('M7 6v12')],                                                   // Sivutus: ensimmäinen
  pgprev: [P('M15 18l-6-6 6-6')],
  pgnext: [P('M9 18l6-6-6-6')],
  pglast: [P('M7 18l6-6-6-6'), P('M17 6v12')],
  minus: [P('M5 12h14')],                                                                        // Stepper: vähennä
  add: [P('M12 5v14M5 12h14')],                                                                  // Stepper: lisää
  chart: [P('M4 20V10M10 20V4M16 20v-8M22 20H2')],                                                 // Raportit
  tick: [P('M5 12.5l4.5 4.5L19 7.5')],                                                         // Saapunut: valintamerkki
  close: [P('M18 6L6 18M6 6l12 12')],                                                         // Sulje
};
const NS = 'http://www.w3.org/2000/svg';
export function icon(name, size = 24) {
  const defs = ICONS[name];
  if (!defs) throw new Error(`Tuntematon ikoni: ${name}`);
  const svg = document.createElementNS(NS, 'svg');
  const set = (el, o) => { for (const [k, v] of Object.entries(o)) el.setAttribute(k, v); };
  set(svg, { viewBox: '0 0 24 24', width: size, height: size, fill: 'none', stroke: 'currentColor', 'stroke-width': 2, 'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'aria-hidden': 'true', focusable: 'false', class: 'icon' });
  for (const [tag, a] of defs) { const el = document.createElementNS(NS, tag); set(el, a); svg.append(el); }
  return svg;
}
