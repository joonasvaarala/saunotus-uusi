// Ryhmän välilehdet (Kassa ja talous, Tuotteet, Tilat ja sulut, Asetukset). Sama kuvio kuin Tilaukset/Varaukset:
// yksi päänavigaation kohta, välilehdet sivun yläreunassa. Vanha osoite (#/pikakassa, #/kayttajat, …) valitsee välilehden.
import { h, tabs, skeleton } from '../ui.js';
import { navText } from '../nav-texts.js';
import { navGroupById, visibleGroupTabs, selectGroupTab } from '../admin-navigation.js';

export async function render({ ctx, refs, reload, query, rest, groupId, tabId, loadView }) {
  const group = navGroupById(groupId);
  const can = (p) => ctx.can(p);
  const groupTabs = visibleGroupTabs(group, can);
  const selected = selectGroupTab(group, tabId, can);
  const heading = h('h1', { text: navText(group.labelKey) });
  const tablist = tabs({ label: navText(group.labelKey), testid: 'nav-group-tabs', idPrefix: 'nav-group-tab', hidden: groupTabs.length < 2, selected: selected?.id,
    items: groupTabs.map((tab) => ({ id: tab.id, text: navText(tab.labelKey), href: `#/${tab.path}`, controls: 'nav-group-panel', testid: `nav-group-tab-${tab.id}` })) });
  const host = h('div', { class: 'nav-group', 'data-testid': `nav-group-${group.id}`, 'data-active-tab': selected?.id || '' }, heading, tablist);
  const panel = h('section', { class: 'nav-group-panel', role: 'tabpanel', id: 'nav-group-panel', 'data-testid': 'nav-group-panel', 'aria-labelledby': selected ? `nav-group-tab-${selected.id}` : null });
  host.append(panel);
  if (!selected) return host;
  panel.append(skeleton(navText('ui.admin.nav.loading')));
  try {
    const mod = await loadView(selected.view);
    const out = await mod.render({ ctx, refs, reload, query, rest });
    panel.replaceChildren(...[].concat(out).filter(Boolean));
    oneH1(panel, [heading.textContent, navText(selected.labelKey)]);
  } catch (err) {
    panel.replaceChildren(h('p', { class: 'err', role: 'alert', text: navText('ui.admin.nav.load_failed', { error: err?.message || String(err) }) }));
  }
  return host;
}

/** YHT-03: sivulla yksi H1 (ryhmän nimi). Näkymän oma H1 samalla nimellä kuin ryhmä tai välilehti poistetaan, muut muuttuvat H2:ksi. */
export function oneH1(panel, names) {
  const same = new Set(names.map((x) => String(x || '').trim().toLowerCase()));
  for (const el of [...panel.querySelectorAll('h1')]) {
    if (same.has(el.textContent.trim().toLowerCase())) { el.remove(); continue; }
    const h2 = document.createElement('h2');
    for (const a of el.attributes) h2.setAttribute(a.name, a.value);
    h2.classList.add('view-title');
    h2.append(...el.childNodes);
    el.replaceWith(h2);
  }
}
