// Ryhmän välilehdet (Kassa ja talous, Tuotteet, Tilat ja sulut, Asetukset). Sama kuvio kuin Tilaukset/Varaukset:
// yksi päänavigaation kohta, välilehdet sivun yläreunassa. Vanha osoite (#/pikakassa, #/kayttajat, …) valitsee välilehden.
import { h } from '../ui.js';
import { navText } from '../nav-texts.js';
import { navGroupById, visibleGroupTabs, selectGroupTab } from '../admin-navigation.js';

export async function render({ ctx, refs, reload, query, rest, groupId, tabId, loadView }) {
  const group = navGroupById(groupId);
  const can = (p) => ctx.can(p);
  const tabs = visibleGroupTabs(group, can);
  const selected = selectGroupTab(group, tabId, can);
  const heading = h('h1', { text: navText(group.labelKey) });
  const tablist = h('div', { class: 'tl-tabs', role: 'tablist', 'aria-label': navText(group.labelKey), 'data-testid': 'nav-group-tabs', hidden: tabs.length < 2 });
  const host = h('div', { class: 'nav-group', 'data-testid': `nav-group-${group.id}`, 'data-active-tab': selected?.id || '' }, heading, tablist);
  const panel = h('section', { class: 'nav-group-panel', role: 'tabpanel', 'data-testid': 'nav-group-panel', 'aria-labelledby': selected ? `nav-group-tab-${selected.id}` : null });
  host.append(panel);
  tabs.forEach((tab, i) => {
    const on = tab.id === selected?.id;
    const b = h('button', { type: 'button', role: 'tab', class: 'tl-tabbtn', id: `nav-group-tab-${tab.id}`, 'aria-selected': String(on),
      'aria-controls': 'nav-group-panel', tabindex: on ? '0' : '-1', 'data-testid': `nav-group-tab-${tab.id}`,
      onclick: () => { const next = `#/${tab.path}`; if (location.hash.split('?')[0] !== next) location.hash = next; },
      onkeydown: (e) => {
        const j = { ArrowRight: i + 1, ArrowLeft: i - 1, Home: 0, End: tabs.length - 1 }[e.key];
        if (j == null) return;
        e.preventDefault();
        const dest = tabs[(j + tabs.length) % tabs.length];
        location.hash = `#/${dest.path}`;
      } }, navText(tab.labelKey));
    tablist.append(b);
  });
  if (!selected) return host;
  panel.append(h('p', { class: 'muted', text: navText('ui.admin.nav.loading') }));
  try {
    const mod = await loadView(selected.view);
    const out = await mod.render({ ctx, refs, reload, query, rest });
    panel.replaceChildren(...[].concat(out).filter(Boolean));
  } catch (err) {
    panel.replaceChildren(h('p', { class: 'err', role: 'alert', text: navText('ui.admin.nav.load_failed', { error: err?.message || String(err) }) }));
  }
  return host;
}
