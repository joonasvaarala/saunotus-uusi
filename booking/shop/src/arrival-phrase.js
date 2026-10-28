// Saapumisaika viestissä: "klo 31.10.2026 16:30" → "31.10.2026 klo 16.30".
// Jos lause alkaa "Saavu klo …", tulokseksi jää "Saavu 31.10.2026 klo 16.30".

export function fixArrivalPhrase(text, lang = 'fi') {
  return String(text ?? '').replace(/klo\s+(\d{1,2}\.\d{1,2}\.\d{4})\s+(\d{1,2}):(\d{2})/g, (_, date, h, m) => (
    lang === 'en' ? `${date} at ${h}:${m}` : `${date} klo ${h}.${m}`
  ));
}

/** Vanha tuotekuvauksen virke, jos se on kopioitu ohjeeseen. */
export function fixSwimwearPhrase(text) {
  return String(text ?? '')
    .replace(/Torstain vuorolla uima-asu on vapaaehtoinen\.?/g, 'Torstain vuorolla saunotaan uima-asussa.')
    .replace(/On the Thursday session, swimwear is optional\.?/gi, 'On the Thursday session, swimwear is worn.');
}

export function fixCustomerPhrase(text, lang = 'fi') {
  return fixSwimwearPhrase(fixArrivalPhrase(text, lang));
}
