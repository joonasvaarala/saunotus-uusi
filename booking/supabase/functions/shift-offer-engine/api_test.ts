// deno test -A --no-lock --node-modules-dir=none booking/supabase/functions/shift-offer-engine/api_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import { handleOfferRequest, type OfferDb } from "./api.ts";

const FOCUS = "aaaaaaaa-0000-4000-8000-0000000000aa";
const OTHER = "bbbbbbbb-0000-4000-8000-0000000000bb";
const STAFF = "22222222-2222-4222-8222-222222222222";
const FOREIGN = "cccccccc-0000-4000-8000-0000000000cc";
const TEMPLATE = "https://sxbofnuisemspgquoxyv.supabase.co/functions/v1/shift-offer-engine?token={{1}}";

const OPEN = {
  ok: true,
  staff_id: STAFF,
  focus_offer_id: FOCUS,
  offers: [
    {
      offer_id: OTHER,
      role_type: "heater",
      starts_at: "2026-11-02T14:00:00.000Z",
      ends_at: "2026-11-02T18:00:00.000Z",
      deadline_at: "2026-10-28T10:00:00.000Z",
      snooze_allowed: false,
    },
    {
      offer_id: FOCUS,
      role_type: "therapist",
      starts_at: "2026-10-24T13:00:00.000Z",
      ends_at: "2026-10-24T17:00:00.000Z",
      deadline_at: "2026-10-24T09:00:00.000Z",
      snooze_allowed: true,
    },
  ],
};

type Call = { name: string; args: Record<string, unknown> };

function dbOf(
  open: { data: unknown; error: { message?: string } | null },
  respond?: (args: Record<string, unknown>) => { data: unknown; error: { message?: string } | null },
): OfferDb & { calls: Call[] } {
  const calls: Call[] = [];
  return {
    calls,
    async rpc(name, args) {
      calls.push({ name, args });
      if (name === "shift_offer_open_for_token") return open;
      if (name === "shift_offer_respond_as_staff" && respond) return respond(args);
      throw new Error("unexpected rpc " + name);
    },
  };
}

function req(method: string, path: string, origin: string | null, body?: unknown): Request {
  const headers = new Headers();
  if (origin) headers.set("origin", origin);
  if (body !== undefined) headers.set("content-type", "application/json");
  return new Request("https://sxbofnuisemspgquoxyv.supabase.co" + path, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

Deno.test("WhatsApp GET redirects to the static page and does not touch the database", async () => {
  const db = dbOf({ data: null, error: null });
  db.rpc = () => {
    throw new Error("redirect must not call rpc");
  };
  const res = await handleOfferRequest(
    req("GET", "/functions/v1/shift-offer-engine?token=" + encodeURIComponent("a+b/c=d"), null),
    db,
    undefined,
  );
  assertEquals(res.status, 302);
  assertEquals(
    res.headers.get("location"),
    "https://saunotus.fi/vuoro/?token=a%2Bb%2Fc%3Dd",
  );
  assertEquals(res.headers.get("cache-control"), "no-store");
  assertEquals(res.headers.get("referrer-policy"), "no-referrer");

  const moved = await handleOfferRequest(
    req("GET", "/functions/v1/shift-offer-engine?token=abc", null),
    db,
    "https://saunotus.fi/",
  );
  assertEquals(moved.status, 302);
  assertEquals(moved.headers.get("location"), "https://saunotus.fi/vuoro/?token=abc");
});

Deno.test("GET /api/offers returns the person's open offers as JSON", async () => {
  const db = dbOf({ data: OPEN, error: null });
  const res = await handleOfferRequest(
    req("GET", "/functions/v1/shift-offer-engine/api/offers?token=abc.def", "https://saunotus.fi"),
    db,
    undefined,
  );
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("content-type"), "application/json; charset=utf-8");
  assertEquals(res.headers.get("cache-control"), "no-store");
  const body = await res.json();
  assertEquals(body.ok, true);
  assertEquals(body.result, null);
  assertEquals(body.title, "Vahvista vastauksesi");
  assertEquals(body.focus_offer_id, FOCUS);
  assertEquals(body.offers.map((o: { offer_id: string }) => o.offer_id), [FOCUS, OTHER]);
  assertEquals(body.offers[0].role_title, "Hoitajavuoro");
  assertEquals(body.offers[0].when, "Lauantai 24.10.2026 klo 16:00–20:00");
  assertEquals(body.offers[0].deadline, "24.10.2026 klo 12:00");
  assertEquals(body.offers[0].snooze_allowed, true);
  assertEquals(body.offers[1].role_title, "Lämmitysvuoro");
  assertEquals(body.offers[1].snooze_allowed, false);
  assertEquals(body.staff_id, undefined);
  assert(!JSON.stringify(body).includes(STAFF));
  assertEquals(db.calls.map((c) => c.name), ["shift_offer_open_for_token"]);
  assertEquals(db.calls[0].args.p_token, "abc.def");
});

Deno.test("POST /api/respond records only through the ownership rpc", async () => {
  const db = dbOf({ data: OPEN, error: null }, () => ({
    data: {
      result: "accepted",
      offer_id: FOCUS,
      role_type: "therapist",
      starts_at: "2026-10-24T13:00:00.000Z",
      ends_at: "2026-10-24T17:00:00.000Z",
      deadline_at: "2026-10-24T09:00:00.000Z",
    },
    error: null,
  }));
  const res = await handleOfferRequest(
    req("POST", "/functions/v1/shift-offer-engine/api/respond", "https://saunotus.fi", {
      token: "abc.def",
      offer_id: FOCUS,
      response: "accept",
    }),
    db,
    undefined,
  );
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.result, "accepted");
  assertEquals(body.title, "Vuoro on sinun");
  assertEquals(body.acted.offer_id, FOCUS);
  assertEquals(body.acted.role_title, "Hoitajavuoro");
  assertEquals(db.calls.map((c) => c.name), [
    "shift_offer_open_for_token",
    "shift_offer_respond_as_staff",
    "shift_offer_open_for_token",
  ]);
  assertEquals(db.calls[1].args, {
    p_token: "abc.def",
    p_offer_id: FOCUS,
    p_response: "accept",
    p_snooze_until: null,
  });
  assertEquals("p_staff_id" in db.calls[1].args, false);
});

Deno.test("a non-uuid offer id is not_owner and does not call the respond rpc", async () => {
  const db = dbOf({ data: OPEN, error: null }, () => {
    throw new Error("respond rpc must not run");
  });
  const res = await handleOfferRequest(
    req("POST", "/functions/v1/shift-offer-engine/api/respond", null, {
      token: "abc.def",
      offer_id: "<img src=x onerror=alert(1)>",
      response: "accept",
    }),
    db,
    undefined,
  );
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.result, "not_owner");
  assertEquals(body.title, "Tähän vuoroon ei voi vastata");
  assertEquals(body.offers.map((o: { offer_id: string }) => o.offer_id), [FOCUS, OTHER]);
  assertEquals(db.calls.map((c) => c.name), ["shift_offer_open_for_token"]);
});

Deno.test("the respond rpc's not_owner is returned with the person's own offers", async () => {
  const db = dbOf({ data: OPEN, error: null }, (args) => {
    assertEquals(args.p_offer_id, FOREIGN);
    return { data: { result: "not_owner" }, error: null };
  });
  const res = await handleOfferRequest(
    req("POST", "/functions/v1/shift-offer-engine/api/respond", null, {
      token: "abc.def",
      offer_id: FOREIGN,
      response: "decline",
    }),
    db,
    undefined,
  );
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.result, "not_owner");
  assertEquals(body.acted, null);
  assertEquals(body.offers.length, 2);
  assert(!JSON.stringify(body).includes(FOREIGN));
});

Deno.test("an invalid snooze date does not call the respond rpc", async () => {
  const db = dbOf({ data: OPEN, error: null }, () => {
    throw new Error("respond rpc must not run");
  });
  const res = await handleOfferRequest(
    req("POST", "/functions/v1/shift-offer-engine/api/respond", null, {
      token: "abc.def",
      offer_id: FOCUS,
      response: "snooze",
      until: "eilen",
    }),
    db,
    undefined,
  );
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.result, null);
  assertEquals(body.snooze_open_offer_id, FOCUS);
  assertEquals(db.calls.map((c) => c.name), ["shift_offer_open_for_token"]);
});

Deno.test("missing offer id acts on the focus offer", async () => {
  const db = dbOf({ data: OPEN, error: null }, (args) => {
    assertEquals(args.p_offer_id, FOCUS);
    return { data: { result: "declined", offer_id: FOCUS, role_type: "therapist", starts_at: "2026-10-24T13:00:00.000Z", ends_at: "2026-10-24T17:00:00.000Z", deadline_at: null }, error: null };
  });
  const res = await handleOfferRequest(
    req("POST", "/functions/v1/shift-offer-engine/api/respond", null, {
      token: "abc.def",
      response: "decline",
    }),
    db,
    undefined,
  );
  assertEquals(res.status, 200);
  assertEquals((await res.json()).result, "declined");
});

Deno.test("a bad token does not call the respond rpc", async () => {
  const db = dbOf({ data: { ok: false, error: "bad_token" }, error: null }, () => {
    throw new Error("respond rpc must not run");
  });
  const posted = await handleOfferRequest(
    req("POST", "/functions/v1/shift-offer-engine/api/respond", null, { token: "nope", response: "accept" }),
    db,
    undefined,
  );
  assertEquals(posted.status, 400);
  assertEquals((await posted.json()).result, "bad_token");
  const listed = await handleOfferRequest(
    req("GET", "/functions/v1/shift-offer-engine/api/offers?token=nope", null),
    db,
    undefined,
  );
  assertEquals(listed.status, 400);
  assertEquals(db.calls.map((c) => c.name), ["shift_offer_open_for_token", "shift_offer_open_for_token"]);
});

Deno.test("CORS echoes only the configured site origins", async () => {
  const allowed = [
    "https://saunotus.fi",
    "https://www.saunotus.fi",
  ];
  const db = dbOf({ data: OPEN, error: null });
  for (const origin of allowed) {
    const pre = await handleOfferRequest(
      req("OPTIONS", "/functions/v1/shift-offer-engine/api/offers", origin),
      db,
      undefined,
    );
    assertEquals(pre.status, 204);
    assertEquals(pre.headers.get("access-control-allow-origin"), origin);
    assertEquals(pre.headers.get("access-control-allow-methods"), "GET, POST, OPTIONS");
    assertEquals(pre.headers.get("access-control-allow-headers"), "content-type");
    assertEquals(pre.headers.get("vary"), "origin");
    assert(pre.headers.get("access-control-allow-origin") !== "*");
    const got = await handleOfferRequest(
      req("GET", "/functions/v1/shift-offer-engine/api/offers?token=abc.def", origin),
      db,
      undefined,
    );
    assertEquals(got.headers.get("access-control-allow-origin"), origin);
    assert(!got.headers.has("access-control-allow-credentials"));
  }
  for (const origin of ["https://evil.example", "https://joonasvaarala.github.io", "https://joonasvaarala.github.io.evil.com", "https://saunotus.fi.evil.com"]) {
    const pre = await handleOfferRequest(
      req("OPTIONS", "/functions/v1/shift-offer-engine/api/respond", origin),
      db,
      undefined,
    );
    assertEquals(pre.status, 403);
    assertEquals(pre.headers.get("access-control-allow-origin"), null);
    assertEquals(pre.headers.get("vary"), "origin");
    const got = await handleOfferRequest(
      req("GET", "/functions/v1/shift-offer-engine/api/offers?token=abc.def", origin),
      db,
      undefined,
    );
    assertEquals(got.status, 200);
    assertEquals(got.headers.get("access-control-allow-origin"), null);
    assert(![...got.headers.values()].includes("*"));
  }
  const bare = await handleOfferRequest(
    req("OPTIONS", "/functions/v1/shift-offer-engine/api/offers", null),
    db,
    undefined,
  );
  assertEquals(bare.status, 403);
  assertEquals(bare.headers.get("access-control-allow-origin"), null);
});

Deno.test("github.io works only when the env asks and the project is not production", async () => {
  const db = dbOf({ data: null, error: null });
  const prod = "https://sxbofnuisemspgquoxyv.supabase.co";
  const dev = "https://aoejjmfzulhkhxbehphs.supabase.co";
  const gh = "https://joonasvaarala.github.io";
  const blocked = await handleOfferRequest(
    req("GET", "/functions/v1/shift-offer-engine?token=abc", null),
    db,
    "https://joonasvaarala.github.io/saunotus-uusi",
    { origins: gh, supabaseUrl: prod },
  );
  assertEquals(blocked.status, 302);
  assertEquals(blocked.headers.get("location"), "https://saunotus.fi/vuoro/?token=abc");
  const preProd = await handleOfferRequest(
    req("OPTIONS", "/functions/v1/shift-offer-engine/api/offers", gh),
    db,
    undefined,
    { origins: gh, supabaseUrl: prod },
  );
  assertEquals(preProd.status, 403);
  const preDev = await handleOfferRequest(
    req("OPTIONS", "/functions/v1/shift-offer-engine/api/offers", gh),
    db,
    "https://joonasvaarala.github.io/saunotus-uusi",
    { origins: gh, supabaseUrl: dev },
  );
  assertEquals(preDev.status, 204);
  assertEquals(preDev.headers.get("access-control-allow-origin"), gh);
  const moved = await handleOfferRequest(
    req("GET", "/functions/v1/shift-offer-engine?token=abc", null),
    db,
    "https://joonasvaarala.github.io/saunotus-uusi/",
    { origins: gh, supabaseUrl: dev },
  );
  assertEquals(moved.headers.get("location"), "https://joonasvaarala.github.io/saunotus-uusi/vuoro/?token=abc");
});

Deno.test("the WhatsApp template button URL stays on the function", async () => {
  const raw = await Deno.readTextFile(new URL("../../../../docs/whatsapp-templates.json", import.meta.url));
  const doc = JSON.parse(raw);
  assertEquals(doc.response_button_url, TEMPLATE);
  const urls = JSON.stringify(doc).match(/https:\/\/[^"\\]+/g) ?? [];
  const buttons = urls.filter((u) => u.includes("shift-offer-engine"));
  assert(buttons.length >= 2);
  for (const url of buttons) assertEquals(url, TEMPLATE);
});
