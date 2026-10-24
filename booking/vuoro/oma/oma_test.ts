// deno test -A --no-lock --node-modules-dir=none booking/vuoro/oma/oma_test.ts
// booking_153: henkilökunnan oma sivu. Valetekstipuu, ei verkkoa.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { langFrom, render, TEXTS, tr, whenText } from "./oma.js";

const NASTY = `<img src=x onerror="alert(1)">`;
type Listener = (ev: { preventDefault(): void }) => void;

class Node {
  tag: string;
  className = "";
  id = "";
  type = "";
  dataset: Record<string, string> = {};
  children: Node[] = [];
  listeners: Record<string, Listener[]> = {};
  #text = "";
  constructor(tag: string) { this.tag = tag; }
  set textContent(v: string) { this.#text = String(v); this.children = []; }
  get textContent(): string { return this.#text + this.children.map((c) => c.textContent).join(""); }
  append(...n: Node[]) { this.children.push(...n); }
  addEventListener(t: string, fn: Listener) { (this.listeners[t] ??= []).push(fn); }
  all(tag: string): Node[] {
    const out: Node[] = [];
    const walk = (n: Node) => { if (n.tag === tag) out.push(n); n.children.forEach(walk); };
    this.children.forEach(walk);
    return out;
  }
}

function doc() {
  const nodes: Record<string, Node> = {};
  for (const id of ["title", "intro", "banner", "open", "done", "open-title", "done-title", "help"]) {
    nodes[id] = new Node("div");
    nodes[id].id = id;
  }
  return {
    nodes,
    title: "",
    getElementById: (id: string) => nodes[id] ?? null,
    createElement: (tag: string) => new Node(tag),
  };
}

const PAGE = {
  ok: true,
  name: NASTY,
  open: [{ offer_id: "o1", role_type: "heater", starts_at: "2026-11-07T14:00:00Z", ends_at: "2026-11-07T18:00:00Z", deadline_at: "2026-11-01T10:00:00Z", my_status: "pending", can_accept: true, can_decline: true }],
  answered: [
    { offer_id: "o2", role_type: "therapist", starts_at: "2026-11-14T10:00:00Z", ends_at: "2026-11-14T16:00:00Z", my_status: "declined", can_accept: true, can_decline: false },
    { offer_id: "o3", role_type: "reception", starts_at: "2026-11-21T10:00:00Z", ends_at: "2026-11-21T16:00:00Z", my_status: "filled_other", can_accept: false, can_decline: false },
  ],
};

Deno.test("oma sivu: avoimet ja vastatut, nimi tekstinä, kieltäytymisen voi muuttaa", () => {
  const d = doc();
  const calls: string[] = [];
  (render as unknown as { onRespond: unknown }).onRespond = (id: string, r: string) => calls.push(`${id}:${r}`);
  render(d, "fi", PAGE, null);
  assert(d.nodes.intro.textContent.includes(NASTY));
  assertEquals(d.nodes.open.all("article").length, 1);
  assertEquals(d.nodes.done.all("article").length, 2);
  assert(d.nodes.open.textContent.includes("Lämmitysvuoro"));
  assert(d.nodes.open.textContent.includes("16.00") || d.nodes.open.textContent.includes("16:00"));
  const openBtns = d.nodes.open.all("button");
  assertEquals(openBtns.map((b) => b.dataset.response), ["accept", "decline"]);
  const doneBtns = d.nodes.done.all("button");
  assertEquals(doneBtns.length, 1);
  assertEquals(doneBtns[0].dataset.offerId, "o2");
  doneBtns[0].listeners.click[0]({ preventDefault() {} });
  assertEquals(calls, ["o2:accept"]);
  assert(d.nodes.done.textContent.includes("Vuoro on jo mennyt"));
});

Deno.test("oma sivu: huono linkki ja tulosviestit, EN", () => {
  const d = doc();
  render(d, "en", { ok: false }, null);
  assertEquals(d.nodes.intro.textContent, TEXTS.en.bad_token);
  render(d, "en", PAGE, "already_taken");
  assertEquals(d.nodes.intro.textContent, TEXTS.en.result_already_taken);
  assert(d.nodes.open.textContent.includes("Heating shift"));
  assertEquals(langFrom("?lang=en&token=x"), "en");
  assertEquals(langFrom("?token=x"), "fi");
  assertEquals(tr("en", "intro", { name: "A" }), "Hi A. Here are the shifts offered to you.");
});

Deno.test("oma sivu: FI- ja EN-avaimet täsmäävät, ei '<', aika Helsingissä", () => {
  assertEquals(Object.keys(TEXTS.fi).sort(), Object.keys(TEXTS.en).sort());
  for (const l of ["fi", "en"] as const) for (const v of Object.values(TEXTS[l])) assert(!v.includes("<"));
  const w = whenText({ starts_at: "2026-11-07T14:00:00Z", ends_at: "2026-11-07T18:00:00Z" }, "fi");
  assert(/16[.:]00/.test(w) && /20[.:]00/.test(w), w);
});
