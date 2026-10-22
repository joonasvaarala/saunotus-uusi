// deno test -A --no-lock --node-modules-dir=none booking/vuoro/vuoro_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import { render } from "./vuoro.js";

const FOCUS = "aaaaaaaa-0000-4000-8000-0000000000aa";
const OTHER = "bbbbbbbb-0000-4000-8000-0000000000bb";
const NASTY = `<img src=x onerror="alert(1)">`;

type Listener = (ev: { preventDefault(): void; submitter: Node | null }) => void;

class Node {
  tag: string;
  className = "";
  id = "";
  type = "";
  value = "";
  required = false;
  open = false;
  dataset: Record<string, string> = {};
  children: Node[] = [];
  listeners: Record<string, Listener[]> = {};
  #text = "";
  constructor(tag: string) {
    this.tag = tag;
  }
  set textContent(value: string) {
    this.#text = String(value);
    this.children = [];
  }
  get textContent(): string {
    return this.#text + this.children.map((child) => child.textContent).join("");
  }
  append(...nodes: Node[]) {
    this.children.push(...nodes);
  }
  addEventListener(type: string, fn: Listener) {
    (this.listeners[type] ??= []).push(fn);
  }
  querySelector(sel: string): Node | null {
    const walk = (node: Node): Node | null => {
      if (node.tag === sel) return node;
      for (const child of node.children) {
        const hit = walk(child);
        if (hit) return hit;
      }
      return null;
    };
    for (const child of this.children) {
      const hit = walk(child);
      if (hit) return hit;
    }
    return null;
  }
}

function page() {
  const title = new Node("h1");
  title.id = "title";
  const banner = new Node("div");
  banner.id = "banner";
  banner.append(title);
  const stack = new Node("div");
  stack.id = "stack";
  const known = [title, banner, stack];
  return {
    doc: {
      title: "",
      createElement: (tag: string) => new Node(tag),
      getElementById: (id: string) => known.find((node) => node.id === id) ?? null,
    },
    stack,
    banner,
    title,
  };
}

function walk(node: Node, out: Node[] = []): Node[] {
  out.push(node);
  for (const child of node.children) walk(child, out);
  return out;
}

function tags(node: Node, tag: string): Node[] {
  return walk(node).filter((item) => item.tag === tag);
}

const therapist = {
  offer_id: FOCUS,
  role: "therapist",
  role_title: "Hoitajavuoro",
  when: "Lauantai 24.10.2026 klo 16:00–20:00",
  deadline: "24.10.2026 klo 12:00",
  snooze_allowed: true,
};

const heater = {
  offer_id: OTHER,
  role: "heater",
  role_title: "Lämmitysvuoro",
  when: "Maanantai 2.11.2026 klo 16:00–20:00",
  deadline: "28.10.2026 klo 12:00",
  snooze_allowed: false,
};

Deno.test("offer text is escaped and the linked offer is first", () => {
  const { doc, stack } = page();
  const nasty = {
    ...therapist,
    role_title: NASTY,
    when: "<script>alert(1)</script>",
    deadline: "</p><img src=x>",
  };
  render(doc, {
    ok: true,
    result: null,
    title: "Vahvista vastauksesi",
    focus_offer_id: FOCUS,
    acted: null,
    snooze_open_offer_id: null,
    offers: [heater, nasty],
  }, () => {});
  const cards = tags(stack, "article");
  assertEquals(cards.length, 2);
  assert(cards[0].className.includes("focus"));
  assertEquals(tags(cards[0], "h2")[0].textContent, NASTY);
  assertEquals(tags(cards[0], "p").some((p) => p.textContent === "<script>alert(1)</script>"), true);
  assertEquals(tags(cards[0], "img").length, 0);
  assertEquals(tags(cards[0], "script").length, 0);
  assertEquals(tags(cards[1], "h2")[0].textContent, "Lämmitysvuoro");
  assertEquals(tags(cards[0], "button").map((b) => b.textContent), ["Hyväksy", "Kieltäydy", "Vahvista päivä"]);
  assertEquals(tags(cards[0], "summary")[0].textContent, "Palaan asiaan");
  assertEquals(tags(cards[0], "details")[0].open, false);
  assertEquals(tags(cards[0], "input").length, 1);
  assertEquals(tags(cards[1], "details").length, 0);
  assertEquals(tags(cards[1], "input").length, 0);
  assertEquals(tags(cards[1], "button").map((b) => b.textContent), ["Hyväksy", "Kieltäydy"]);
});

Deno.test("a recorded answer drops the acted card's buttons and keeps the rest", () => {
  const { doc, stack, banner, title } = page();
  render(doc, {
    ok: true,
    result: "accepted",
    title: "Vuoro on sinun",
    focus_offer_id: FOCUS,
    acted: therapist,
    snooze_open_offer_id: null,
    offers: [heater],
  }, () => {});
  assertEquals(title.textContent, "Vuoro on sinun");
  assert(banner.className.includes("ok"));
  const cards = tags(stack, "article");
  assertEquals(cards.length, 2);
  assertEquals(tags(cards[0], "h2")[0].textContent, "Hoitajavuoro");
  assertEquals(tags(cards[0], "button").length, 0);
  assertEquals(tags(cards[1], "button").map((b) => b.textContent), ["Hyväksy", "Kieltäydy"]);
});

Deno.test("not_owner still shows the person's own buttons", () => {
  const { doc, stack, banner } = page();
  render(doc, {
    ok: true,
    result: "not_owner",
    title: "Tähän vuoroon ei voi vastata",
    focus_offer_id: FOCUS,
    acted: null,
    snooze_open_offer_id: null,
    offers: [therapist, heater],
  }, () => {});
  assert(banner.className.includes("bad"));
  const cards = tags(stack, "article");
  assertEquals(tags(cards[0], "button").length, 3);
  assertEquals(tags(cards[1], "button").length, 2);
});

Deno.test("bad token hides every button", () => {
  const { doc, stack } = page();
  render(doc, {
    ok: false,
    result: "bad_token",
    title: "Linkki ei kelpaa",
    focus_offer_id: null,
    acted: null,
    snooze_open_offer_id: null,
    offers: [],
  }, () => {});
  assertEquals(tags(stack, "button").length, 0);
  assertEquals(tags(stack, "article").length, 0);
});

Deno.test("Palaan asiaan opens the date only for the offer that asked", () => {
  const { doc, stack } = page();
  render(doc, {
    ok: true,
    result: null,
    title: "Vahvista vastauksesi",
    focus_offer_id: FOCUS,
    acted: null,
    snooze_open_offer_id: FOCUS,
    offers: [therapist],
  }, () => {});
  assertEquals(tags(stack, "details")[0].open, true);
  assertEquals(tags(stack, "input")[0].type, "date");
});

Deno.test("submitting a card sends that offer id and the button response", () => {
  const { doc, stack } = page();
  const seen: unknown[] = [];
  render(doc, {
    ok: true,
    result: null,
    title: "Vahvista vastauksesi",
    focus_offer_id: FOCUS,
    acted: null,
    snooze_open_offer_id: null,
    offers: [heater, therapist],
  }, (offerId: string, response: string, until: string) => seen.push([offerId, response, until]));
  const form = tags(stack, "form")[1];
  const decline = tags(form, "button").find((b) => b.dataset.response === "decline")!;
  decline.listeners.click[0]({ preventDefault() {}, submitter: null });
  assertEquals(seen, [[OTHER, "decline", ""]]);
  const snoozeForm = tags(stack, "form")[0];
  const input = tags(snoozeForm, "input")[0];
  input.value = "2026-11-01";
  const snooze = tags(snoozeForm, "button").find((b) => b.dataset.response === "snooze")!;
  snooze.listeners.click[0]({ preventDefault() {}, submitter: null });
  assertEquals(seen[1], [FOCUS, "snooze", "2026-11-01"]);
});

Deno.test("the page source does not build HTML from data and the door image is relative", async () => {
  const js = await Deno.readTextFile(new URL("./vuoro.js", import.meta.url));
  const html = await Deno.readTextFile(new URL("./index.html", import.meta.url));
  const css = (await Deno.readTextFile(new URL("./vuoro.css", import.meta.url))).replace(/\s+/g, "");
  assert(!js.includes("innerHTML"));
  assert(!js.includes("insertAdjacentHTML"));
  assert(!js.includes("document.write"));
  assert(js.includes("textContent"));
  assert(html.includes('src="../img/ovi-kaiverrus-1024.webp"'));
  assert(html.includes('content="noindex, nofollow"'));
  assert(html.includes("–Tapio"));
  assert(css.includes(".arch{position:relative"));
  assert(css.includes("height:252px"));
  assert(css.includes("overflow:hidden"));
  assert(css.includes("font-size:0"));
  assert(css.includes(".snooze[open]{display:grid"));
  assert(!css.includes(".snooze{display:grid"));
  assert(css.includes("font-size:16px"));
  assert(css.includes("font-weight:600"));
  assert(css.includes("min-height:48px"));
});
