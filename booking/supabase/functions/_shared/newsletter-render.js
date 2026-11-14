// booking_259: one safe, structured bot-supplied style package; shared by preview and mailer.
// Plain text only. No raw HTML, CSS, scripts or design editor.
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const color = (value, fallback) => /^#[0-9a-f]{6}$/i.test(value || '') ? value : fallback;
export function newsletterUrl(value) {
  if (typeof value !== 'string' || value.length > 1000 || /[\s<>"']/.test(value)) return '';
  try { const u = new URL(value); return u.protocol === 'https:' && u.hostname && !u.username && !u.password ? u.href : ''; } catch { return ''; }
}
export function renderNewsletter(data) {
  if (!data || !String(data.subject || '').trim() || !String(data.body || '').trim()) return null;
  const subject = String(data.subject).replace(/[\r\n]+/g, ' ').trim();
  const s = data.style || {}, en = data.locale === 'en';
  const unsub = newsletterUrl(data.unsubscribe_url);
  if (!unsub) return null; // marketing always needs a working opt-out
  const image = newsletterUrl(s.image_url), cta = newsletterUrl(s.cta_url);
  const label = String(en ? s.cta_en || '' : s.cta_fi || '');
  const bg = color(s.background, '#f4f1e9'), fg = color(s.foreground, '#24332c'), accent = color(s.accent, '#465e4b');
  const editorial = s.layout === 'editorial';
  const optout = en ? 'Unsubscribe from newsletters' : 'Peruuta uutiskirjeet';
  const paragraphs = String(data.body).split(/\n\s*\n/).map(p => `<p style="margin:0 0 20px;line-height:1.65">${esc(p).replace(/\n/g, '<br>')}</p>`).join('');
  const html = `<!doctype html><html lang="${en?'en':'fi'}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head><body style="margin:0;background:${bg};color:${fg}"><table role="presentation" width="100%" cellspacing="0" cellpadding="0"><tr><td align="center" style="padding:24px 12px"><table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:640px"><tr><td style="padding:28px;font-family:Georgia,serif;border-top:4px solid ${accent}"><p style="font:14px Arial,sans-serif;letter-spacing:2px;margin:0 0 24px">SIPOONJOEN PERINNESAUNA</p>${image?`<img src="${esc(image)}" alt="" width="584" style="display:block;width:100%;height:auto;margin:0 0 28px">`:''}<h1 style="font-size:${editorial?'38':'30'}px;line-height:1.2;margin:0 0 28px;color:${fg}">${esc(subject)}</h1><div style="font-size:18px">${paragraphs}</div>${cta&&label?`<p style="margin:28px 0"><a href="${esc(cta)}" style="display:inline-block;padding:14px 22px;background:${accent};color:#ffffff;text-decoration:none;font:16px Arial,sans-serif">${esc(label)}</a></p>`:''}<hr style="border:0;border-top:1px solid ${accent};margin:32px 0"><p style="font:13px Arial,sans-serif">Sipoonjoen perinnesauna · Havuhattu Oy</p><p style="font:13px Arial,sans-serif"><a href="${esc(unsub)}" style="color:${fg}">${esc(optout)}</a></p></td></tr></table></td></tr></table></body></html>`;
  const text = `${subject}\n\n${data.body}${cta&&label?`\n\n${label}: ${cta}`:''}\n\nSipoonjoen perinnesauna · Havuhattu Oy\n${optout}: ${unsub}`;
  return { subject, text, html };
}
