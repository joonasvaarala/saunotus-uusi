// ?mock=1&img=1|2. Oletus tyhjä, jotta muut kokeilut eivät saa kuvia.
// img=2 on sama tuote uudella polulla ja updated_atilla (välimuistin versio vaihtuu).
const MOCK_IMAGE_IDS = [[1, 'yleinensauna'], [2, 'miestensauna-2'], [3, 'naistensauna'], [4, 'hiljainen-sauna'], [7, 'saunarituaali-ja-savusaunavuoro'], [10, 'saunahoito-2'], [11, 'saunotus-2'], [12, 'syvasaunotus'], [25, 'oma-saunavuoro']];

export function mockProductImages(search = '') {
  const ver = new URLSearchParams(search).get('img');
  if (ver !== '1' && ver !== '2') return [];
  const token = ver === '2' ? 'newimg2' : 'oldimg1';
  const updated_at = ver === '2' ? '2026-10-28T18:00:00.000Z' : '2026-10-01T00:00:00.000Z';
  return MOCK_IMAGE_IDS.map(([product_id, slug]) => ({ product_id, slug, path: `products/${product_id}-${token}.webp`, alt: null, updated_at }));
}
