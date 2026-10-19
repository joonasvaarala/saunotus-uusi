// node --test booking/supabase/functions/send-emails/mailer.test.mjs
// Ei verkkoa: allowlist on puhdas funktio, SMTP-lähetys on mockattu (gmail_smtp.ts ei lataudu).
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

let M = null;
try { M = await import("./mailer.ts"); } catch (e) { if (!/ERR_UNKNOWN_FILE_EXTENSION|Unknown file extension/.test(String(e?.code || e))) throw e; }
const skip = M ? false : "Node ei tue .ts-tuontia (tarvitaan Node >= 22.18)";

const LIST = ["testi@example.com", "toinen@example.com"];

test("allowlist: listalla oleva osoite ei estä", { skip }, () => {
  assert.equal(M.outboxAllowlistBlock("live", { to: "testi@example.com" }, LIST), null);
});

test("allowlist: osoite ei ole listalla", { skip }, () => {
  assert.equal(M.outboxAllowlistBlock("live", { to: "muu@example.com" }, LIST), "ei allowlistissa");
});

test("allowlist: tyhjä tai puuttuva lista ei rajaa", { skip }, () => {
  assert.equal(M.outboxAllowlistBlock("live", { to: "kuka@example.com" }, []), null);
  assert.equal(M.outboxAllowlistBlock("live", { to: "kuka@example.com" }, M.parseTestRecipients(undefined)), null);
  assert.equal(M.outboxAllowlistBlock("live", { to: "kuka@example.com" }, M.parseTestRecipients(null)), null);
  assert.equal(M.outboxAllowlistBlock("live", { to: "kuka@example.com" }, M.parseTestRecipients("testi@example.com")), null);
  assert.equal(M.outboxAllowlistBlock("live", { to: "kuka@example.com" }, M.parseTestRecipients(["", "  "])), null);
  assert.equal(M.outboxAllowlistBlock("live", { to: "kuka@example.com" }, M.parseTestRecipients(["ei-osoite"])), "ei allowlistissa");
});

test("allowlist: kirjainkoko ja välilyönnit", { skip }, () => {
  const parsed = M.parseTestRecipients(["  Testi@Example.COM  ", "TOINEN@example.com"]);
  assert.deepEqual(parsed, ["testi@example.com", "toinen@example.com"]);
  assert.equal(M.outboxAllowlistBlock("live", { to: "TESTI@example.com" }, parsed), null);
  assert.equal(M.outboxAllowlistBlock("live", { to: "Testi@Example.com" }, ["testi@example.com"]), null);
});

test("allowlist: usea vastaanottaja, yksikin puuttuva estää koko viestin", { skip }, () => {
  assert.equal(M.outboxAllowlistBlock("live", { to: "testi@example.com", cc: "toinen@example.com" }, LIST), null);
  assert.equal(M.outboxAllowlistBlock("live", { to: "testi@example.com", cc: "Nimi <toinen@example.com>" }, LIST), null);
  assert.equal(M.outboxAllowlistBlock("live", { to: "testi@example.com", bcc: "muu@example.com" }, LIST), "ei allowlistissa");
  assert.equal(M.outboxAllowlistBlock("live", { to: "testi@example.com", cc: ["toinen@example.com", "muu@example.com"] }, LIST), "ei allowlistissa");
  assert.equal(M.outboxAllowlistBlock("live", { to: "testi@example.com", cc: "Nimi <toinen@example.com>, Vieras <muu@example.com>" }, LIST), "ei allowlistissa");
  assert.equal(M.outboxAllowlistBlock("live", { to: "muu@example.com", cc: "testi@example.com" }, LIST), "ei allowlistissa");
});

test("allowlist: dry_run ja off eivät rajaa", { skip }, () => {
  assert.equal(M.outboxAllowlistBlock("dry_run", { to: "muu@example.com" }, LIST), null);
  assert.equal(M.outboxAllowlistBlock("off", { to: "muu@example.com" }, LIST), null);
});

test("transport: resend on oletus, gmail_smtp sallittu", { skip }, () => {
  assert.equal(M.resolveTransport(undefined), "resend");
  assert.equal(M.resolveTransport({}), "resend");
  assert.equal(M.resolveTransport({ transport: "resend" }), "resend");
  assert.equal(M.resolveTransport({ transport: "gmail" }), "resend");
  assert.equal(M.resolveTransport({ transport: "gmail_smtp" }), "gmail_smtp");
});

test("gmail smtp: mockattu lähetys, 465 TLS, from, reply_to, liitteet", { skip }, async () => {
  const calls = [];
  const pdf = M.decodeBase64("JVBERg==");
  const sent = await M.sendViaGmail(
    {
      to: "testi@example.com",
      cc: "toinen@example.com",
      subject: "Kuitti",
      text: "teksti",
      html: "<p>html</p>",
      replyTo: "savusauna@saunotus.fi",
      attachments: [{ filename: "kuitti-1.pdf", content: "JVBERg==" }],
    },
    { user: "  sauna.bot@gmail.com  ", pass: "app-salasana-16" },
    async (link, message) => {
      calls.push({ link, message });
      return { messageId: "<abc@smtp.gmail.com>" };
    },
  );
  assert.equal(sent.id, "<abc@smtp.gmail.com>");
  assert.equal(calls.length, 1);
  const { link, message } = calls[0];
  assert.equal(link.host, "smtp.gmail.com");
  assert.equal(link.port, 465);
  assert.equal(link.secure, true);
  assert.equal(link.auth.user, "sauna.bot@gmail.com");
  assert.equal(link.auth.pass, "app-salasana-16");
  assert.equal(message.from, "Sipoonjoen Perinnesauna <sauna.bot@gmail.com>");
  assert.equal(message.to, "testi@example.com");
  assert.deepEqual(message.cc, ["toinen@example.com"]);
  assert.equal(message.replyTo, "savusauna@saunotus.fi");
  assert.equal(message.attachments.length, 1);
  assert.equal(message.attachments[0].filename, "kuitti-1.pdf");
  assert.equal(message.attachments[0].contentType, "application/pdf");
  assert.deepEqual(message.attachments[0].content, pdf);
});

test("gmail smtp: salaisuudet puuttuvat → virhe, mockia ei kutsuta", { skip }, async () => {
  let called = 0;
  const send = async () => { called++; return { messageId: "x" }; };
  const mail = { to: "testi@example.com", subject: "s", text: "t", html: "h" };
  await assert.rejects(() => M.sendViaGmail(mail, { user: "", pass: "salaisuus" }, send), { message: "GMAIL_SMTP_* puuttuu" });
  await assert.rejects(() => M.sendViaGmail(mail, { user: "a@b.fi", pass: "" }, send), { message: "GMAIL_SMTP_* puuttuu" });
  await assert.rejects(() => M.sendViaGmail(mail, { user: null, pass: null }, send), { message: "GMAIL_SMTP_* puuttuu" });
  assert.equal(called, 0);
});

test("gmail smtp: virhe ei sisällä salasanaa eikä käyttäjää", { skip }, async () => {
  const pass = "app-salasana-16";
  const user = "sauna.bot@gmail.com";
  await assert.rejects(
    () => M.sendViaGmail(
      { to: "testi@example.com", subject: "s", text: "t", html: "h" },
      { user, pass },
      async () => { throw new Error(`535 ${user} rejected ${pass}`); },
    ),
    (err) => {
      assert.equal(err instanceof Error, true);
      assert.equal(err.message.includes(pass), false);
      assert.equal(err.message.includes(user), false);
      assert.match(err.message, /\[redacted\]/);
      return true;
    },
  );
});

test("nodemailer-versio on lukittu gmail_smtp.ts:ssä", () => {
  const src = readFileSync(new URL("./gmail_smtp.ts", import.meta.url), "utf8");
  assert.match(src, /from "npm:nodemailer@10\.1\.2"/);
  assert.equal(src.includes("console."), false);
});
