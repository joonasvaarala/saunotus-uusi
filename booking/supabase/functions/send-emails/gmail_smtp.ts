// Gmail SMTP -kuljetus. Versio lukittu (10.1.2: uusin, joka on Deno 2:n 24 h riippuvuusviiveen yli; 10.1.3+ on sitä uudempi). Kutsutaan vain kun settings.transport = 'gmail_smtp'.
// Käyttäjä ja sovellussalasana tulevat argumentteina (Edge-salaisuudet GMAIL_SMTP_USER / GMAIL_SMTP_APP_PASSWORD).
// Niitä ei lokiteta (logger ja debug pois). Portti 465 + TLS; toimivuus Supabasen edge-ympäristössä varmistetaan tuotantokokeilulla, ei tässä.
import { Buffer } from "node:buffer";
import nodemailer from "npm:nodemailer@10.1.2";
import type { SmtpLink, SmtpMessage } from "./mailer.ts";

export async function gmailSmtpSend(link: SmtpLink, message: SmtpMessage): Promise<{ messageId?: string | null }> {
  const transporter = nodemailer.createTransport({
    host: link.host,
    port: link.port,
    secure: link.secure,
    auth: { user: link.auth.user, pass: link.auth.pass },
    logger: false,
    debug: false,
  });
  try {
    const info = await transporter.sendMail({
      from: message.from,
      to: message.to,
      cc: message.cc,
      bcc: message.bcc,
      replyTo: message.replyTo,
      subject: message.subject,
      text: message.text,
      html: message.html,
      attachments: message.attachments.map((a) => ({
        filename: a.filename,
        content: Buffer.from(a.content),
        contentType: a.contentType,
      })),
    });
    return { messageId: info?.messageId ?? null };
  } finally {
    try { transporter.close(); } catch { /* close ei saa peittää lähetysvirhettä */ }
  }
}
