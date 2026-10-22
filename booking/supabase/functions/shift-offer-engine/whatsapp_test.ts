// deno test -A --no-lock --node-modules-dir=none booking/supabase/functions/shift-offer-engine/whatsapp_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import templates from "../../../../docs/whatsapp-templates.json" with { type: "json" };
import {
  GRAPH_API_VERSION,
  KIND_TEMPLATE,
  buildTemplatePayload,
  classifyHttp,
  formatShiftWhen,
  handleClaimedMessage,
  handleWebhookRequest,
  lockForSend,
  messagesUrl,
  nextOutboxStatus,
  maskPhoneE164,
  normalizeFinnishPhone,
  parseWebhookStatuses,
  planMessage,
  readChallenge,
  redactTemplatePayload,
  retryPlan,
  staleSendingResolution,
  STALE_SEND_LOCK_MS,
  verifyHubSignature,
  webhookSignatureHex,
  type ClaimedMessage,
  type Settings,
  type TemplatePayload,
  type WhatsappEnv,
} from "./whatsapp.ts";

const STAFF = "aaaaaaaa-0000-4000-8000-0000000000a1";
const NOW = Date.parse("2026-10-22T00:00:00.000Z");
const SIG_BODY = new TextEncoder().encode('{"object":"whatsapp_business_account"}');
const SIG_HEX = "b6978b21c4467654c466607663db9b43fae44b71083568df403e0a077089208e";

function msg(over: Partial<ClaimedMessage> = {}): ClaimedMessage {
  return {
    id: 7,
    kind: "offer",
    channel: "whatsapp",
    staff_id: STAFF,
    attempts: 0,
    wamid: null,
    status: "sending",
    phone_raw: "040 123 4567",
    email: null,
    role_type: "heater",
    starts_at: "2026-10-24T13:00:00.000Z",
    ends_at: "2026-10-24T17:00:00.000Z",
    deadline_at: "2026-10-24T09:00:00.000Z",
    ask_no: null,
    ask_count: null,
    token: "payload.sig",
    staff_whatsapp_enabled: true,
    bot_channel: false,
    ...over,
  };
}

function settings(over: Partial<Settings> = {}): Settings {
  return {
    sender_enabled: true,
    whatsapp_enabled: true,
    whatsapp_dry_run: false,
    allow_staff_ids: [STAFF],
    ...over,
  };
}

const env: WhatsappEnv = {
  token: "super-secret-token",
  phoneNumberId: "123456789012345",
  appSecret: "test-app-secret",
  verifyToken: "verify-me",
};

function bodyParams(payload: TemplatePayload): string[] {
  const body = payload.template.components.find((c) => c.type === "body");
  return body && body.type === "body" ? body.parameters.map((p) => p.text) : [];
}

Deno.test("Finnish numbers normalise to E.164", () => {
  assertEquals(normalizeFinnishPhone("0401234567"), "+358401234567");
  assertEquals(normalizeFinnishPhone("040 123 4567"), "+358401234567");
  assertEquals(normalizeFinnishPhone("(040) 123-4567"), "+358401234567");
  assertEquals(normalizeFinnishPhone("+358401234567"), "+358401234567");
  assertEquals(normalizeFinnishPhone("00358401234567"), "+358401234567");
  assertEquals(normalizeFinnishPhone("358401234567"), "+358401234567");
  assertEquals(normalizeFinnishPhone("0501234567"), "+358501234567");
  assertEquals(normalizeFinnishPhone(""), null);
  assertEquals(normalizeFinnishPhone(null), null);
  assertEquals(normalizeFinnishPhone("091234567"), null);
  assertEquals(normalizeFinnishPhone("040123"), null);
  assertEquals(normalizeFinnishPhone("+46701234567"), null);
});

Deno.test("shift clock is Europe/Helsinki in summer and winter", () => {
  assertEquals(formatShiftWhen("2026-10-24T13:00:00.000Z", "2026-10-24T17:00:00.000Z"), "la 24.10.2026 klo 16:00–20:00");
  assertEquals(formatShiftWhen("2027-01-15T06:00:00.000Z", null), "pe 15.01.2027 klo 08:00");
});

Deno.test("template payload uses the approved name, Finnish, and the token suffix", () => {
  const offer = buildTemplatePayload(msg(), "+358401234567");
  assert(offer);
  assertEquals(offer.messaging_product, "whatsapp");
  assertEquals(offer.to, "+358401234567");
  assertEquals(offer.template.name, "vuorotarjous");
  assertEquals(offer.template.language.code, "fi");
  assertEquals(bodyParams(offer), ["lämmitysvuoro", "la 24.10.2026 klo 16:00–20:00", "24.10.2026 klo 12:00"]);
  const button = offer.template.components.find((c) => c.type === "button");
  assert(button && button.type === "button");
  assertEquals(button.parameters[0].text, "payload.sig");
  assert(!JSON.stringify(offer).includes("https://"));

  const filled = buildTemplatePayload(msg({ kind: "filled", token: null }), "+358401234567");
  assert(filled);
  assertEquals(filled.template.name, "vuoro_taytetty");
  assertEquals(filled.template.components.some((c) => c.type === "button"), false);

  const cancelled = buildTemplatePayload(msg({ kind: "cancelled", role_type: "therapist" }), "+358401234567");
  assertEquals(cancelled?.template.name, "tarjous_peruttu");
  assertEquals(bodyParams(cancelled!), ["hoitajavuoro", "la 24.10.2026 klo 16:00–20:00"]);

  const ask = buildTemplatePayload(msg({ kind: "exhausted_ask", ask_no: 2, ask_count: 3 }), "+358401234567");
  assertEquals(ask?.template.name, "joonas_tyhja_vuoro");
  assertEquals(bodyParams(ask!), ["lämmitysvuoro", "la 24.10.2026 klo 16:00–20:00", "2/3"]);
  assertEquals(buildTemplatePayload(msg({ kind: "alert" }), "+358401234567") && bodyParams(buildTemplatePayload(msg({ kind: "alert" }), "+358401234567")!), [
    "lämmitysvuoro",
    "la 24.10.2026 klo 16:00–20:00",
    "hälytys",
  ]);
  assertEquals(buildTemplatePayload(msg({ kind: "offer", token: null }), "+358401234567"), null);
  assertEquals(KIND_TEMPLATE.reminder, "vuorotarjous");
});

Deno.test("repo template JSON matches the kinds the sender sends", () => {
  assertEquals(templates.language, "fi");
  assertEquals(templates.category, "UTILITY");
  assertEquals(templates.graph_api_version, GRAPH_API_VERSION);
  assertEquals(templates.kind_map, KIND_TEMPLATE);
  const byName = new Map(templates.templates.map((t) => [t.name, t]));
  for (const name of new Set(Object.values(KIND_TEMPLATE))) {
    const spec = byName.get(name);
    assert(spec, name);
    assertEquals(spec.language, "fi");
    assertEquals(spec.category, "UTILITY");
    const body = spec.components.find((c) => c.type === "BODY");
    assert(body && "text" in body);
    const placeholders = (body.text ?? "").match(/\{\{\d+\}\}/g) ?? [];
    const sampleKind = Object.entries(KIND_TEMPLATE).find(([, template]) => template === name)?.[0] ?? "offer";
    const built = buildTemplatePayload(msg({ kind: sampleKind, token: "esimerkkitoken" }), "+358401234567");
    assert(built);
    assertEquals(bodyParams(built).length, placeholders.length);
    const buttons = spec.components.find((c) => c.type === "BUTTONS");
    const sentButton = built.template.components.find((c) => c.type === "button");
    if (buttons && "buttons" in buttons) {
      assert(sentButton && sentButton.type === "button");
      assertEquals(sentButton.parameters[0].text, "esimerkkitoken");
      const sampleUrl = buttons.buttons?.[0]?.url ?? "";
      assert(sampleUrl.endsWith("{{1}}"));
    } else {
      assertEquals(sentButton, undefined);
    }
  }
});

Deno.test("webhook signature matches the pinned HMAC and rejects tampering", async () => {
  assertEquals(await webhookSignatureHex("test-app-secret", SIG_BODY), SIG_HEX);
  assert(await verifyHubSignature("test-app-secret", SIG_BODY, `sha256=${SIG_HEX}`));
  const tampered = new Uint8Array(SIG_BODY);
  tampered[0] = tampered[0] ^ 1;
  assertEquals(await verifyHubSignature("test-app-secret", tampered, `sha256=${SIG_HEX}`), false);
  assertEquals(await verifyHubSignature("other-secret", SIG_BODY, `sha256=${SIG_HEX}`), false);
  assertEquals(await verifyHubSignature("test-app-secret", SIG_BODY, null), false);
  assertEquals(await verifyHubSignature("", SIG_BODY, `sha256=${SIG_HEX}`), false);
});

Deno.test("verify challenge returns the hub challenge only for the configured token", async () => {
  const ok = new URLSearchParams("hub.mode=subscribe&hub.verify_token=verify-me&hub.challenge=987654");
  assertEquals(await readChallenge(ok, "verify-me"), "987654");
  assertEquals(await readChallenge(ok, "other"), null);
  assertEquals(await readChallenge(new URLSearchParams("hub.mode=unsubscribe&hub.verify_token=verify-me&hub.challenge=1"), "verify-me"), null);
  assertEquals(await readChallenge(ok, ""), null);
});

Deno.test("webhook records delivery statuses and passes inbound messages", async () => {
  const applied: unknown[] = [];
  const inbound: unknown[] = [];
  const body = JSON.stringify({
    object: "whatsapp_business_account",
    entry: [{
      changes: [{
        value: {
          messages: [{ from: "358401234567", id: "wamid.IN", type: "text", text: { body: "ok" } }],
          statuses: [{
            id: "wamid.ABC",
            status: "delivered",
            timestamp: "1700000000",
            recipient_id: "358401234567",
          }, {
            id: "wamid.BAD",
            status: "failed",
            timestamp: "1700000001",
            errors: [{ code: 131026, title: "Message undeliverable" }],
          }],
        },
      }],
    }],
  });
  const raw = new TextEncoder().encode(body);
  const sig = await webhookSignatureHex(env.appSecret, raw);
  const post = new Request("https://example.test/functions/v1/shift-offer-engine/webhook", {
    method: "POST",
    headers: { "x-hub-signature-256": `sha256=${sig}`, "content-type": "application/json" },
    body,
  });
  const res = await handleWebhookRequest(post, env, async (update) => {
    applied.push(update);
  }, async (message) => {
    inbound.push({ from: message.from, type: message.type, text: message.text, wamid: message.wamid });
  });
  assertEquals(res.status, 200);
  assertEquals(inbound, [{ from: "358401234567", type: "text", text: "ok", wamid: "wamid.IN" }]);
  assertEquals(applied, [{
    wamid: "wamid.ABC",
    status: "delivered",
    error: null,
    at: new Date(1700000000 * 1000).toISOString(),
  }, {
    wamid: "wamid.BAD",
    status: "failed",
    error: "131026 Message undeliverable",
    at: new Date(1700000001 * 1000).toISOString(),
  }]);
  assertEquals(parseWebhookStatuses({ entry: [{ changes: [{ value: { messages: [{ id: "in" }] } }] }] }), []);

  const bad = new Request("https://example.test/webhook", {
    method: "POST",
    headers: { "x-hub-signature-256": "sha256=00" },
    body,
  });
  const rejected = await handleWebhookRequest(bad, env, async () => {
    throw new Error("should not apply");
  });
  assertEquals(rejected.status, 401);

  const get = new Request("https://example.test/webhook?hub.mode=subscribe&hub.verify_token=verify-me&hub.challenge=555");
  const challenge = await handleWebhookRequest(get, env, async () => {});
  assertEquals(challenge.status, 200);
  assertEquals(await challenge.text(), "555");
});

Deno.test("delivery status does not move backwards", () => {
  assertEquals(nextOutboxStatus("sent", "delivered"), "delivered");
  assertEquals(nextOutboxStatus("delivered", "read"), "read");
  assertEquals(nextOutboxStatus("delivered", "sent"), null);
  assertEquals(nextOutboxStatus("read", "failed"), null);
  assertEquals(nextOutboxStatus("sent", "failed"), "failed");
  assertEquals(nextOutboxStatus("failed", "delivered"), null);
  assertEquals(nextOutboxStatus("failed_no_contact", "delivered"), null);
  assertEquals(nextOutboxStatus("unknown", "delivered"), null);
  assertEquals(nextOutboxStatus("unknown", "sent"), null);
  assertEquals(nextOutboxStatus("unknown", "failed"), null);
});

Deno.test("missing phone is failed_no_contact and stays addressable", () => {
  const plan = planMessage(msg({ phone_raw: null, email: null, channel: "none" }), settings());
  assertEquals(plan.action, "fail_no_contact");
  const email = planMessage(msg({ phone_raw: " ", email: "aino@example.com", channel: "email" }), settings());
  assertEquals(email.action, "release");
  if (email.action === "release") {
    assertEquals(email.reason, "email_pending");
    assertEquals(email.channel, "email");
    assertEquals(email.payload, null);
  }
});

Deno.test("dry-run logs a redacted API body and does not call Meta", async () => {
  const logs: unknown[] = [];
  let calls = 0;
  const fetchImpl: typeof fetch = async () => {
    calls += 1;
    return new Response("no", { status: 500 });
  };
  const result = await handleClaimedMessage(
    msg(),
    settings({ whatsapp_dry_run: true }),
    env,
    fetchImpl,
    (_event, data) => logs.push({ event: _event, ...data }),
    NOW,
  );
  assertEquals(calls, 0);
  assertEquals(result.action, "release");
  assertEquals(result.error, "dry_run");
  assertEquals(logs.length, 1);
  const logged = logs[0] as { event: string; body: TemplatePayload; url: string };
  assertEquals(logged.event, "whatsapp_dry_run");
  assertEquals(logged.url, messagesUrl(env.phoneNumberId));
  const redacted = redactTemplatePayload(buildTemplatePayload(msg(), "+358401234567")!);
  assertEquals(logged.body, redacted);
  assertEquals(result.payload, redacted);
  assertEquals(logged.body.to, "+358*******67");
  assertEquals(bodyParams(logged.body), ["lämmitysvuoro", "la 24.10.2026 klo 16:00–20:00", "24.10.2026 klo 12:00"]);
  const dumped = JSON.stringify({ logs, payload: result.payload });
  assert(!dumped.includes("+358401234567"));
  assert(!dumped.includes("payload.sig"));
  assert(!dumped.includes("super-secret-token"));
  assert(!dumped.includes("Bearer"));
});

Deno.test("only an allowlisted staff id is sent, and a row is never posted twice", async () => {
  const calls: { url: string; body: string; authorization: string | null }[] = [];
  const fetchImpl: typeof fetch = async (input, init) => {
    const headers = new Headers(init?.headers);
    calls.push({
      url: String(input),
      body: String(init?.body ?? ""),
      authorization: headers.get("authorization"),
    });
    return new Response(JSON.stringify({ messages: [{ id: "wamid.ABC" }] }), { status: 200 });
  };
  const blocked = await handleClaimedMessage(
    msg(),
    settings({ allow_staff_ids: [] }),
    env,
    fetchImpl,
    () => {},
    NOW,
  );
  assertEquals(blocked.action, "release");
  assertEquals(blocked.error, "not_allowlisted");
  assertEquals(calls.length, 0);

  const off = await handleClaimedMessage(msg(), settings({ whatsapp_enabled: false }), env, fetchImpl, () => {}, NOW);
  assertEquals(off.error, "whatsapp_disabled");
  assertEquals(calls.length, 0);

  const row = msg();
  const [first, second] = await Promise.all([
    handleClaimedMessage(row, settings(), env, fetchImpl, () => {}, NOW),
    handleClaimedMessage(row, settings(), env, fetchImpl, () => {}, NOW),
  ]);
  assertEquals(calls.length, 1);
  assertEquals(calls[0].url, "https://graph.facebook.com/v25.0/123456789012345/messages");
  assertEquals(calls[0].authorization, "Bearer super-secret-token");
  assertEquals(JSON.parse(calls[0].body), buildTemplatePayload(msg(), "+358401234567"));
  const actions = [first.action, second.action].sort();
  assertEquals(actions, ["already_sent", "sent"]);
  const sent = first.action === "sent" ? first : second;
  assertEquals(sent.payload?.to, "+358*******67");
  assert(!JSON.stringify(sent.payload).includes("+358401234567"));
  assert(!JSON.stringify(sent.payload).includes("payload.sig"));
  assert(calls[0].body.includes("+358401234567"));
  assert(calls[0].body.includes("payload.sig"));
  assertEquals(row.wamid, "wamid.ABC");
  const again = await handleClaimedMessage(row, settings(), env, fetchImpl, () => {}, NOW);
  assertEquals(again.action, "already_sent");
  assertEquals(calls.length, 1);
});

Deno.test("5xx and 429 retry with backoff, 4xx does not", async () => {
  assertEquals(classifyHttp(200), "ok");
  assertEquals(classifyHttp(429), "retry");
  assertEquals(classifyHttp(503), "retry");
  assertEquals(classifyHttp(400), "fail");
  assertEquals(classifyHttp(408), "fail");
  const first = retryPlan(0, NOW);
  assertEquals(first.retry, true);
  assertEquals(first.attempts, 1);
  assertEquals(first.retryAt, "2026-10-22T00:01:00.000Z");
  assertEquals(retryPlan(1, NOW).retryAt, "2026-10-22T00:04:00.000Z");
  assertEquals(retryPlan(7, NOW).retry, false);

  const retryFetch = async () => new Response(JSON.stringify({ error: { code: 131000, message: "temporary" } }), { status: 503 });
  const retrying = msg();
  const retried = await handleClaimedMessage(retrying, settings(), env, retryFetch, () => {}, NOW);
  assertEquals(retried.action, "retry");
  assertEquals(retried.attempts, 1);
  assertEquals(retried.retry_at, "2026-10-22T00:01:00.000Z");
  assertEquals(retrying.wamid, null);
  assertEquals(retrying.status, "sending");

  let calls = 0;
  const failFetch: typeof fetch = async () => {
    calls += 1;
    return new Response(JSON.stringify({ error: { code: 131026, message: "undeliverable" } }), { status: 400 });
  };
  const failing = msg();
  const failed = await handleClaimedMessage(failing, settings(), env, failFetch, () => {}, NOW);
  assertEquals(failed.action, "fail");
  assertEquals(failed.error, "131026 undeliverable");
  assertEquals(failing.status, "failed");
  const ignored = await handleClaimedMessage(failing, settings(), env, failFetch, () => {}, NOW);
  assertEquals(ignored.action, "already_sent");
  assertEquals(calls, 1);

  const limited = await handleClaimedMessage(msg({ attempts: 7 }), settings(), env, retryFetch, () => {}, NOW);
  assertEquals(limited.action, "fail");
  assertEquals(limited.attempts, 8);
});

Deno.test("missing credentials do not call Meta and the log is redacted", async () => {
  let calls = 0;
  const logs: unknown[] = [];
  const result = await handleClaimedMessage(
    msg(),
    settings(),
    { ...env, token: "", phoneNumberId: "" },
    async () => {
      calls += 1;
      return new Response("no", { status: 200 });
    },
    (event, data) => logs.push({ event, ...data }),
    NOW,
  );
  assertEquals(calls, 0);
  assertEquals(result.action, "release");
  assertEquals(result.error, "missing_credentials");
  assertEquals(logs.length, 1);
  assertEquals((logs[0] as { event: string }).event, "whatsapp_missing_credentials");
  assertEquals(result.payload?.to, "+358*******67");
  const dumped = JSON.stringify({ logs, payload: result.payload });
  assert(!dumped.includes("+358401234567"));
  assert(!dumped.includes("payload.sig"));
  assert(!dumped.includes("super-secret-token"));
});

Deno.test("phone and token redaction keeps the template text and is idempotent", () => {
  assertEquals(maskPhoneE164("+358401234567"), "+358*******67");
  assertEquals(maskPhoneE164("+358*******67"), "+358*******67");
  assertEquals(maskPhoneE164("04012"), "***");
  const raw = buildTemplatePayload(msg(), "+358401234567");
  assert(raw);
  const once = redactTemplatePayload(raw);
  const twice = redactTemplatePayload(once);
  assertEquals(twice, once);
  assertEquals(raw.to, "+358401234567");
  assertEquals(once.to, "+358*******67");
  const button = once.template.components.find((c) => c.type === "button");
  assert(button && button.type === "button");
  assertEquals(button.parameters[0].text, "***");
  assertEquals(bodyParams(once)[0], "lämmitysvuoro");
});

Deno.test("Joonas and Otto never get a WhatsApp send", async () => {
  let calls = 0;
  const fetchImpl: typeof fetch = async () => {
    calls += 1;
    return new Response(JSON.stringify({ messages: [{ id: "wamid.BOT" }] }), { status: 200 });
  };
  const joonas = "5ab2ba62-97b2-4712-b500-a47a898036a5";
  const otto = "2975633f-c53f-48d6-8a38-41cae0be5a83";
  for (const staffId of [joonas, otto]) {
    const result = await handleClaimedMessage(
      msg({ staff_id: staffId, staff_whatsapp_enabled: true, bot_channel: false, channel: "whatsapp" }),
      settings({ allow_staff_ids: [staffId] }),
      env,
      fetchImpl,
      () => {},
      NOW,
    );
    assertEquals(result.action, "bot_channel");
    assertEquals(result.payload, null);
    assertEquals(result.to, null);
  }
  const flagged = await handleClaimedMessage(
    msg({ bot_channel: true, staff_whatsapp_enabled: true }),
    settings(),
    env,
    fetchImpl,
    () => {},
    NOW,
  );
  assertEquals(flagged.action, "bot_channel");
  assertEquals(calls, 0);
  const sql = await Deno.readTextFile(
    new URL("../../migrations/20261022024547_shift_offer_bot_channel.sql", import.meta.url),
  );
  assert(sql.includes("'bot_channel'"));
  assert(sql.includes("channel = 'bot'"));
  assert(sql.includes("not public.shift_offer_is_bot_staff"));
  assert(sql.includes("new.whatsapp_enabled := false"));
  assert(sql.includes("'joonas', 'otto'"));
  assert(sql.includes("5ab2ba62-97b2-4712-b500-a47a898036a5"));
  assert(sql.includes("2975633f-c53f-48d6-8a38-41cae0be5a83"));
});

Deno.test("staff whatsapp opt-in is required in addition to the allowlist", async () => {
  let calls = 0;
  const fetchImpl: typeof fetch = async () => {
    calls += 1;
    return new Response(JSON.stringify({ messages: [{ id: "wamid.NO" }] }), { status: 200 });
  };
  const optedOut = await handleClaimedMessage(
    msg({ staff_whatsapp_enabled: false }),
    settings(),
    env,
    fetchImpl,
    () => {},
    NOW,
  );
  assertEquals(calls, 0);
  assertEquals(optedOut.action, "release");
  assertEquals(optedOut.error, "staff_whatsapp_disabled");
  assertEquals(optedOut.payload, null);
  const plan = planMessage(msg({ staff_whatsapp_enabled: false }), settings());
  assertEquals(plan.action, "release");
  if (plan.action === "release") assertEquals(plan.payload, null);
});

Deno.test("a sending row without wamid is unknown after the lock timeout, not requeued", async () => {
  const lockedAt = NOW - STALE_SEND_LOCK_MS;
  assertEquals(staleSendingResolution("sending", null, lockedAt - 1, NOW), "unknown");
  assertEquals(staleSendingResolution("sending", null, NOW - 60_000, NOW), "leave");
  assertEquals(staleSendingResolution("sending", "wamid.ABC", lockedAt - 1, NOW), "leave");
  assertEquals(staleSendingResolution("sending", null, null, NOW), "leave");
  assertEquals(staleSendingResolution("queued", null, lockedAt - 1, NOW), "leave");
  assertEquals(staleSendingResolution("unknown", null, lockedAt - 1, NOW), "leave");

  const sql = await Deno.readTextFile(
    new URL("../../migrations/20261022014510_shift_offer_whatsapp_guard.sql", import.meta.url),
  );
  const claimStart = sql.indexOf("function public.shift_offer_sender_claim");
  const completeStart = sql.indexOf("function public.shift_offer_sender_complete");
  const claim = sql.slice(claimStart, completeStart);
  const expire = claim.slice(claim.indexOf("update public.shift_offer_messages"), claim.indexOf("v_limit :="));
  assert(expire.includes("status = 'unknown'"));
  assert(expire.includes("unknown_delivery"));
  assert(expire.includes("wamid is null"));
  assert(expire.includes("interval '10 minutes'"));
  assert(!expire.includes("'queued'"));
  const queue = sql.slice(sql.indexOf("function public.shift_offer_queue_message"), claimStart);
  assert(queue.includes("st.whatsapp_enabled"));
  assert(queue.includes("shift_offer_phone_e164"));
  const handled = planMessage(msg({ status: "unknown" }), settings());
  assertEquals(handled.action, "already_sent");
});

Deno.test("a locked row cannot be locked again", () => {
  const rows = [{ id: 1, status: "queued", wamid: null as string | null }, { id: 2, status: "sent", wamid: "wamid.X" }];
  assert(lockForSend(rows, 1));
  assertEquals(rows[0].status, "sending");
  assertEquals(lockForSend(rows, 1), null);
  assertEquals(lockForSend(rows, 2), null);
  rows[0].wamid = "wamid.ABC";
  rows[0].status = "queued";
  assertEquals(lockForSend(rows, 1), null);
});
