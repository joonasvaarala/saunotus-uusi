// Tuotekuvan valmistelu selaimessa: tyyppi- ja kokotarkistus sekä skaalaus (max 1600 px) → WebP (tai JPEG). Tallennettu tiedosto on aina ≤ 2 MB (bucketin raja).
export const IMG_TYPES = ['image/jpeg', 'image/png', 'image/webp'];
export const IMG_MAX_INPUT = 15 * 1048576;     // alkuperäinen enintään 15 Mt (puhelimen kuva); skaalattu tulos ≤ 2 Mt
export const IMG_MAX_OUT = 2 * 1048576;
const MAX_SIDE = 1600;

const load = (blob) => new Promise((ok, no) => {
  const url = URL.createObjectURL(blob), im = new Image();
  im.onload = () => ok({ im, url }); im.onerror = () => { URL.revokeObjectURL(url); no(new Error('Kuvaa ei voi lukea (tiedosto on vioittunut tai ei ole kuva)')); }; im.src = url;
});
const toBlob = (cv, type, q) => new Promise((ok) => cv.toBlob(ok, type, q));

export async function prepareImage(file) {
  if (!IMG_TYPES.includes(file.type)) throw new Error('Sallitut kuvatyypit: JPEG, PNG ja WebP');
  if (file.size > IMG_MAX_INPUT) throw new Error(`Tiedosto on liian suuri (${(file.size / 1048576).toFixed(1)} Mt, enintään ${IMG_MAX_INPUT / 1048576} Mt)`);
  const { im, url } = await load(file);
  try {
    const w0 = im.naturalWidth, h0 = im.naturalHeight;
    if (w0 < 400 || h0 < 250) throw new Error(`Kuva on liian pieni (${w0}×${h0}); vähintään 400×250 px`);
    const k = Math.min(1, MAX_SIDE / Math.max(w0, h0)), w = Math.round(w0 * k), hh = Math.round(h0 * k);
    const cv = document.createElement('canvas'); cv.width = w; cv.height = hh;
    cv.getContext('2d').drawImage(im, 0, 0, w, hh);
    for (const [type, ext] of [['image/webp', 'webp'], ['image/jpeg', 'jpg']]) {
      for (const q of [0.86, 0.72, 0.6]) {
        const blob = await toBlob(cv, type, q);
        if (blob && blob.type === type && blob.size <= IMG_MAX_OUT) return { blob, ext, w, h: hh, url: URL.createObjectURL(blob) };
      }
    }
    throw new Error('Kuvaa ei saatu pienennettyä alle 2 Mt:n');
  } finally { URL.revokeObjectURL(url); }
}
