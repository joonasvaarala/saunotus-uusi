// Vastaanottajien allowlist ja Gmail SMTP -viestin kokoaminen. Ei verkkoa, ei Deno-API:a:
// node --test tuo tämän suoraan. Oikea SMTP-kutsu on gmail_smtp.ts (npm:nodemailer, versio lukittu).
// Salaisuuksia ei lueta eikä tulosteta täällä; kutsuja antaa ne ja ne kulkevat vain SMTP-authissa.

export const ALLOWLIST_ERROR = "ei allowlistissa";
export const GMAIL_SECRET_ERROR = "GMAIL_SMTP_* puuttuu";
export const GMAIL_SMTP_HOST = "smtp.gmail.com";
export const GMAIL_SMTP_PORT = 465;

const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

export type MailTransport = "resend" | "gmail_smtp";

export function resolveTransport(settings: { transport?: unknown } | null | undefined): MailTransport {
  return settings?.transport === "gmail_smtp" ? "gmail_smtp" : "resend";
}

/** Osoite lowercasena ja trimmattuna. "Nimi <a@b.fi>" → a@b.fi. Ei-osoite → null. */
export function normalizeEmail(raw: string): string | null {
  const trimmed = raw.trim();
  const angled = trimmed.match(/<([^<>]+)>/);
  const cand = (angled ? angled[1] : trimmed).trim().toLowerCase();
  return EMAIL_RE.test(cand) ? cand : null;
}

/**
 * integration_config.resend.settings.test_recipients.
 * Ei taulukkoa tai vain tyhjiä alkioita → ei rajausta.
 * Epätyhjä taulukko ilman yhtään osoitetta rajaa kaiken (ei vahingossa live-lähetystä).
 */
export function parseTestRecipients(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  const out: string[] = [];
  let nonempty = false;
  for (const item of raw) {
    if (typeof item !== "string") {
      if (item != null) nonempty = true;
      continue;
    }
    if (!item.trim()) continue;
    nonempty = true;
    const email = normalizeEmail(item);
    if (email) out.push(email);
  }
  if (nonempty && !out.length) return ["\0"];
  return out;
}

type Piece = { ok: true; email: string } | { ok: false };

function splitChunks(value: string): string[] {
  const chunks: string[] = [];
  let buf = "";
  let depth = 0;
  for (const ch of value) {
    if (ch === "<") depth++;
    else if (ch === ">" && depth) depth--;
    if ((ch === "," || ch === ";") && depth === 0) {
      chunks.push(buf);
      buf = "";
    } else buf += ch;
  }
  chunks.push(buf);
  return chunks;
}

/** Yksi kenttä (to/cc/bcc): merkkijono tai taulukko. Tyhjä ei ole vastaanottaja. Kelvoton ei-tyhjä arvo estää (ok:false). */
export function recipientPieces(value: unknown): Piece[] {
  if (value == null || value === "") return [];
  if (Array.isArray(value)) return value.flatMap(recipientPieces);
  if (typeof value !== "string") return [{ ok: false }];
  const out: Piece[] = [];
  for (const chunk of splitChunks(value)) {
    if (!chunk.trim()) continue;
    const email = normalizeEmail(chunk);
    out.push(email ? { ok: true, email } : { ok: false });
  }
  return out;
}

export function messageRecipients(row: { to?: unknown; cc?: unknown; bcc?: unknown } | null | undefined): Piece[] {
  if (!row) return [];
  return [row.to, row.cc, row.bcc].flatMap(recipientPieces);
}

/**
 * Live + epätyhjä lista: yksikin vastaanottaja (to/cc/bcc) listan ulkopuolella estää koko viestin.
 * Tyhjä lista tai muu mode kuin live → null (ei rajausta).
 */
export function outboxAllowlistBlock(
  mode: string,
  row: { to?: unknown; cc?: unknown; bcc?: unknown } | null | undefined,
  allowlist: readonly string[] | null | undefined,
): string | null {
  if (mode !== "live") return null;
  const allowed = new Set((allowlist ?? []).map((a) => a.trim().toLowerCase()).filter(Boolean));
  if (!allowed.size) return null;
  const recips = messageRecipients(row);
  if (!recips.length || recips.some((p) => !p.ok || !allowed.has(p.email))) return ALLOWLIST_ERROR;
  return null;
}

export function gmailSecretsMissing(secrets: { user?: string | null; pass?: string | null }): boolean {
  return !String(secrets.user ?? "").trim() || !secrets.pass;
}

export interface MailAttachment {
  filename: string;
  content: string;
}

export interface SmtpAuth {
  user: string;
  pass: string;
}

export interface SmtpLink {
  host: string;
  port: number;
  secure: boolean;
  auth: SmtpAuth;
}

export interface SmtpAttachment {
  filename: string;
  content: Uint8Array;
  contentType: string;
}

export interface SmtpMessage {
  from: string;
  to: string;
  cc?: string[];
  bcc?: string[];
  replyTo?: string;
  subject: string;
  text: string;
  html: string;
  attachments: SmtpAttachment[];
}

export type SmtpSend = (link: SmtpLink, message: SmtpMessage) => Promise<{ messageId?: string | null }>;

export interface GmailMail {
  to: string;
  cc?: unknown;
  bcc?: unknown;
  subject: string;
  text: string;
  html: string;
  replyTo?: string;
  attachments?: MailAttachment[];
}

export function gmailFromAddress(user: string): string {
  return `Sipoonjoen Perinnesauna <${user}>`;
}

export function decodeBase64(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** Virheilmoituksesta pois käyttäjä ja salasana, ennen kuin teksti päätyy email_outbox.last_erroriin. */
export function redactSecrets(message: string, secrets: readonly string[]): string {
  let out = message;
  for (const secret of secrets) {
    if (secret.length < 4) continue;
    out = out.split(secret).join("[redacted]");
  }
  return out.slice(0, 300);
}

function emailsOnly(value: unknown): string[] {
  return recipientPieces(value).flatMap((p) => (p.ok ? [p.email] : []));
}

/**
 * Gmail SMTP: smtp.gmail.com:465, TLS (secure). From on Gmail-osoite.
 * Puuttuvat salaisuudet → heitto GMAIL_SECRET_ERROR, send-funktiota ei kutsuta.
 * Kutsuja (index.ts) merkitsee failed; tämä ei kaada prosessia.
 */
export async function sendViaGmail(
  mail: GmailMail,
  secrets: { user?: string | null; pass?: string | null },
  send: SmtpSend,
): Promise<{ id: string | null }> {
  const user = String(secrets.user ?? "").trim();
  const pass = secrets.pass ?? "";
  if (gmailSecretsMissing({ user, pass })) throw new Error(GMAIL_SECRET_ERROR);
  const cc = emailsOnly(mail.cc);
  const bcc = emailsOnly(mail.bcc);
  try {
    const info = await send(
      { host: GMAIL_SMTP_HOST, port: GMAIL_SMTP_PORT, secure: true, auth: { user, pass } },
      {
        from: gmailFromAddress(user),
        to: mail.to,
        ...(cc.length ? { cc } : {}),
        ...(bcc.length ? { bcc } : {}),
        ...(mail.replyTo ? { replyTo: mail.replyTo } : {}),
        subject: mail.subject,
        text: mail.text,
        html: mail.html,
        attachments: (mail.attachments ?? []).map((a) => ({
          filename: a.filename,
          content: decodeBase64(a.content),
          contentType: "application/pdf",
        })),
      },
    );
    const id = info?.messageId ? String(info.messageId) : null;
    return { id };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    if (msg === GMAIL_SECRET_ERROR) throw e instanceof Error ? e : new Error(msg);
    throw new Error(redactSecrets(msg, [user, pass]));
  }
}
