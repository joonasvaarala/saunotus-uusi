// booking_153: henkilökunnan vuoroilmoitus sähköpostina (email_outbox.kind = 'staff_shift_notice').
// Teksti tulee valmiina tietokannasta (vuorotarjousmoottori, allekirjoitus "Tapio"); tämä vain kääri sen.
// Erillinen tiedosto, jotta booking_154:n templates.ts/texts.ts-muutoksiin ei kosketa.
// Värit: tausta #F4EFE7, teksti #2B3A30, linkki #7A5530 (kontrasti taustaa vasten yli 4.5:1). Ei sinistä, ei emojeja.

export const STAFF_NOTICE_KIND = "staff_shift_notice";

export type StaffNoticePayload = { subject?: string | null; text?: string | null; link_url?: string | null };
export type StaffNoticeMail = { subject: string; text: string; html: string };

const esc = (s: string) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");

function safeHttps(raw: string | null | undefined): string | null {
  if (!raw) return null;
  try {
    const u = new URL(raw);
    return u.protocol === "https:" ? u.toString() : null;
  } catch {
    return null;
  }
}

function linkify(line: string): string {
  return line.split(/(https:\/\/[^\s<>"']+)/g).map((part, i) => {
    if (i % 2 === 1) {
      const url = safeHttps(part);
      if (url) return `<a href="${esc(url)}" style="color:#7A5530;text-decoration:underline">${esc(part)}</a>`;
    }
    return esc(part);
  }).join("");
}

export function renderStaffNotice(p: StaffNoticePayload | null | undefined): StaffNoticeMail | null {
  const subject = String(p?.subject ?? "").replace(/[\r\n]+/g, " ").trim().slice(0, 200);
  const text = String(p?.text ?? "").replace(/\u0000/g, "").trim();
  if (!subject || !text) return null;
  const link = safeHttps(p?.link_url ?? null);
  const fullText = link && !text.includes(link) ? `${text}\n\n${link}` : text;
  const rows = fullText.split("\n").map((line) => line.trim() ? `<p style="margin:0 0 10px">${linkify(line)}</p>` : "").join("");
  const html = `<!doctype html><html lang="fi"><head><meta charset="utf-8"><meta name="robots" content="noindex"><title>${esc(subject)}</title></head>` +
    `<body style="margin:0;padding:0;background:#F4EFE7"><div style="max-width:560px;margin:0 auto;padding:24px;font-family:Georgia,serif;font-size:16px;line-height:1.5;color:#2B3A30">` +
    `${rows}</div></body></html>`;
  return { subject, text: fullText, html };
}
