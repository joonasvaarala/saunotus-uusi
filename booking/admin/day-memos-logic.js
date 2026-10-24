// Kompaktin tiedotteen katkelma. Ei katkaise HTML:ää, koska teksti tulostetaan textContentina.
export function firstSentence(value, max = 120) {
  const text = String(value ?? '').trim();
  if (!text) return '';
  const firstLine = text.split(/\r?\n/, 1)[0].trim();
  const sentence = /[.!?]/.exec(firstLine);
  const preview = sentence ? firstLine.slice(0, sentence.index + 1) : firstLine;
  const limit = Number.isFinite(max) ? Math.max(1, Math.floor(max)) : 120;
  return preview.length > limit ? `${preview.slice(0, limit - 1).trimEnd()}…` : preview;
}
