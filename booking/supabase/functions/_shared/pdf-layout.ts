import { rgb, type Color, type PDFFont } from "npm:pdf-lib@1.17.1";

/** pdf-lib StandardFonts käyttää WinAnsi-merkistöä. */
export const pdfSan = (value: unknown): string =>
  String(value ?? "").replace(/[^\u0020-\u007E\u00A0-\u00FF\u20AC\u2013\u2014\u2018\u2019\u201C\u201D\u2022\u2026]/g, "?");

export function wrapPdfText(value: unknown, font: PDFFont, size: number, maxWidth: number): string[] {
  const out: string[] = [];
  let current = "";
  for (const word of pdfSan(value).split(/\s+/).filter(Boolean)) {
    const next = current ? `${current} ${word}` : word;
    if (current && font.widthOfTextAtSize(next, size) > maxWidth) {
      out.push(current);
      current = word;
    } else current = next;
  }
  if (current) out.push(current);
  return out;
}

export async function fetchPdfLogo(url?: string | null): Promise<Uint8Array | null> {
  if (!url) return null;
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 4000);
    const response = await fetch(url, { signal: controller.signal });
    clearTimeout(timeout);
    if (!response.ok) return null;
    const bytes = new Uint8Array(await response.arrayBuffer());
    return bytes.length > 0 && bytes.length < 2_000_000 ? bytes : null;
  } catch {
    return null;
  }
}

const fromHex = (hex: string): Color => {
  const n = Number.parseInt(hex.slice(1), 16);
  return rgb(((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255);
};

/** Sama pääpaletti kuin src/styles.css. */
export const PDF_BRAND = {
  green: fromHex("#2B3A30"),
  cream: fromHex("#F4EFE7"),
  brown: fromHex("#7A5530"),
  ink: fromHex("#2F2923"),
  text: fromHex("#4F443A"),
  muted: fromHex("#6B5E52"),
  white: rgb(1, 1, 1),
} as const;
