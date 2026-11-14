// ⋯-valikko (details/summary). Erotettu order-view.js:stä, jotta päivänäkymä voi käyttää samaa valikkoa ilman koko tilausnäkymää.
import { h } from '../ui.js';
import { placeOverflowMenu } from '../order-view-logic.js';

/** Yksinkertainen ⋯-valikko (details/summary, näppäimistöllä käytettävä). items: [[key, label, onclick]].
 * prefer 'end' = oikeareuna nappiin (otsikko), 'start' = vasen reuna (varausrivi). Avoinna valikko kiinnitetään
 * ruutuun (position:fixed), jotta se ei jää sivupalkin alle eikä leikkaudu ruudun reunasta. */
export function overflowMenu(items, label, testid, { prefer = 'end' } = {}) {
  const list = h('div', { class: 'ov-menu-list', role: 'menu' }, items.map(([key, text, onclick]) => h('button', { type: 'button', role: 'menuitem', class: 'ov-menu-item', 'data-testid': `${testid}-${key}`, text,
    onclick: (e) => { d.open = false; onclick(e); } })));
  const d = h('details', { class: 'ov-menu', 'data-testid': testid },
    h('summary', { class: 'btn sm ov-menu-btn', 'aria-label': label, title: label }, '⋯'),
    list);
  const clear = () => { for (const p of ['position', 'left', 'right', 'top', 'max-width', 'width', 'z-index']) list.style.removeProperty(p); };
  const place = () => {
    if (!d.open) { clear(); return; }
    const btn = d.querySelector('summary');
    const placed = placeOverflowMenu(btn.getBoundingClientRect(), { width: list.offsetWidth, height: list.offsetHeight }, { width: window.innerWidth, height: window.innerHeight }, { prefer });
    list.style.position = 'fixed';
    list.style.left = `${placed.left}px`;
    list.style.right = 'auto';
    list.style.top = `${placed.top}px`;
    list.style.maxWidth = `${placed.maxWidth}px`;
    list.style.zIndex = '60';
  };
  const onWin = () => { if (d.open) place(); };
  d.addEventListener('toggle', () => {
    place();
    if (d.open) {
      window.addEventListener('resize', onWin);
      window.addEventListener('scroll', onWin, true);
    } else {
      window.removeEventListener('resize', onWin);
      window.removeEventListener('scroll', onWin, true);
    }
  });
  d.addEventListener('keydown', (e) => { if (e.key === 'Escape' && d.open) { e.stopPropagation(); d.open = false; d.querySelector('summary').focus(); } });
  return d;
}
