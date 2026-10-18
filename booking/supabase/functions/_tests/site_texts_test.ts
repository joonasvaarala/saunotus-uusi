// _shared/site_texts.ts: paikkamerkkien täyttö, DB → oletus -haku, haku ja välimuisti. Ajo: deno test --node-modules-dir=none booking/supabase/functions/_tests/site_texts_test.ts
import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import { _clearTextCache, fetchSiteTexts, fillText, makeT, tokensOf, type TextTable } from "../_shared/site_texts.ts";

const TABLE: TextTable = {
  "email.x.a": { fi: "Hei {{var:name}} – {{setting:business_name}}", en: "Hello {{var:name}} – {{setting:business_name}}" },
  "email.x.b": { fi: "Vain FI", en: "EN default" },
};
const warns: string[] = [];
const T = (rows?: any[], settings?: any) => makeT(TABLE, rows, settings, (m) => warns.push(m));

Deno.test("fillText: var, setting; puuttuva arvo ja tuntematon laji heittävät; arvo saa sisältää {{ }}", () => {
  assertEquals(fillText("A {{var:x}} B {{setting:s}}", { vars: { x: 1 }, settings: { s: "S" } }), "A 1 B S");
  assertThrows(() => fillText("{{var:x}}", {}), Error, "muuttuja puuttuu");
  assertThrows(() => fillText("{{setting:eiole}}", { settings: {} }), Error, "asetus puuttuu");
  assertThrows(() => fillText("{{price:7}}", {}), Error, "tuntematon");
  assertThrows(() => fillText("Rikki {{var:x", { vars: { x: 1 } }), Error, "virheellinen");
  assertEquals(fillText("N: {{var:x}}", { vars: { x: "{{var:y}} $& {" } }), "N: {{var:y}} $& {");   // asiakkaan nimi ei voi rikkoa viestiä
  assertEquals(tokensOf("{{var:a}} {{var:a}} {{setting:b}}").sort(), ["{{setting:b}}", "{{var:a}}"]);
});

Deno.test("makeT: oletus, DB-rivi voittaa, puuttuva kieli → oletus, rikkinäinen DB-rivi → oletus + varoitus, oletusasetukset", () => {
  warns.length = 0;
  assertEquals(T()("email.x.a", "fi", { name: "Matti" }), "Hei Matti – Sipoonjoen Perinnesauna");
  assertEquals(T()("email.x.a", "en", { name: "Matti" }), "Hello Matti – Sipoonjoen Perinnesauna");
  assertEquals(T()("email.x.a", undefined, { name: "Matti" }), "Hei Matti – Sipoonjoen Perinnesauna");
  const rows = [{ key: "email.x.a", lang: "fi", text: "Moi {{var:name}}!" }, { key: "email.x.b", lang: "en", text: "{{var:eiole}}" }, { key: "email.x.b", lang: "fi", text: "   " }];
  assertEquals(T(rows)("email.x.a", "fi", { name: "M" }), "Moi M!");
  assertEquals(T(rows)("email.x.a", "en", { name: "M" }), "Hello M – Sipoonjoen Perinnesauna", "EN-riviä ei ole → oletus");
  assertEquals(T(rows)("email.x.b", "en"), "EN default"); assert(warns.some((w) => w.includes("email.x.b")), "varoitus rikkinäisestä rivistä");
  assertEquals(T(rows)("email.x.b", "fi"), "Vain FI", "tyhjä DB-rivi ohitetaan");
  assertEquals(T([], { business_name: "Uusi Nimi" })("email.x.a", "fi", { name: "M" }), "Hei M – Uusi Nimi");
  assertThrows(() => T()("email.x.eiole", "fi"), Error, "tuntematon tekstiavain");
  assertThrows(() => T()("email.x.a", "fi", {}), Error, "muuttuja puuttuu", "oletuksen paikkamerkki ilman arvoa = ohjelmointivirhe");
});

const mockFetch = (calls: string[], fail = false) => (url: string, init?: RequestInit) => {
  calls.push(`${url} ${(init?.headers as any)?.["accept-profile"] ?? ""}`);
  if (fail) return Promise.resolve(new Response("x", { status: 500 }));
  const body = url.endsWith("public_get_site_texts") ? { ok: true, texts: [{ key: "email.a.b", lang: "fi", text: "T" }, { key: "ui.shop.x", lang: "fi", text: "ei" }, { key: "email.a.c", lang: "en", text: "U", placeholders: [] }] } : { business_name: "BN", n: 5, obj: {} };
  return Promise.resolve(new Response(JSON.stringify(body), { status: 200 }));
};
Deno.test("fetchSiteTexts: anon-RPC booking-skeemalla, prefiksisuodatus, välimuisti; virhe → null; sb_secret hylätään; avain puuttuu → null", async () => {
  _clearTextCache();
  const calls: string[] = [];
  const o = { url: "https://x.supabase.co/", anonKey: "sb_publishable_abc", prefixes: ["email."], fetchImpl: mockFetch(calls) as any, now: () => 1000 };
  const r = await fetchSiteTexts(o);
  assertEquals(r?.rows.map((x) => x.key), ["email.a.b", "email.a.c"]); assertEquals((r?.settings as any).business_name, "BN");
  assertEquals(calls, ["https://x.supabase.co/rest/v1/rpc/public_get_site_texts booking", "https://x.supabase.co/rest/v1/rpc/public_settings booking"]);
  await fetchSiteTexts(o); assertEquals(calls.length, 2, "välimuisti");
  assertEquals((await fetchSiteTexts({ ...o, now: () => 1000 + 301_000 }))?.rows.length, 2); assertEquals(calls.length, 4, "TTL umpeutuu");
  _clearTextCache();
  assertEquals(await fetchSiteTexts({ ...o, fetchImpl: mockFetch([], true) as any }), null);
  _clearTextCache();
  assertEquals(await fetchSiteTexts({ ...o, anonKey: "sb_secret_x" }), null);
  assertEquals(await fetchSiteTexts({ ...o, url: "" }), null);
});
