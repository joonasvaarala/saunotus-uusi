// Arvostelujen järjestys: uusin ensin `published`-kentän (ISO) mukaan. Ilman `published`-arvoa oleva (esim. käsin
// lisätty) katsotaan uusimmaksi ja pysyy tiedostojärjestyksessä. Vakaa lajittelu.
const ts = (r) => (r.published && !Number.isNaN(Date.parse(r.published)) ? Date.parse(r.published) : Infinity);
export const sortReviews = (list) => list.map((r, i) => [r, i]).sort((a, b) => (ts(b[0]) === ts(a[0]) ? a[1] - b[1] : ts(b[0]) > ts(a[0]) ? 1 : -1)).map((x) => x[0]);
