// Joonas 21.11.2026: Pikakassa myös Talous-valikosta. Linkki samaan reittiin (#/pikakassa), oikeus pos.use; nykyinen sijainti säilyy.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolveAdminPath, navGroupById, visibleGroupTabs, visibleGroupLinks, groupAllowed } from '../admin/admin-navigation.js';

const cash = navGroupById('cash');
const can = (perms) => (p) => perms.includes(p);

test('Talous-valikossa Pikakassa-linkki vain pos.use-oikeudella', () => {
  assert.deepEqual(visibleGroupLinks(cash, can(['payments.manage', 'pos.use'])).map((l) => [l.path, l.labelKey]), [['pikakassa', 'ui.admin.nav.pos']]);
  assert.deepEqual(visibleGroupLinks(cash, can(['payments.manage'])), []);
});

test('linkki ei ole välilehti eikä muuta reititystä tai ryhmän näkyvyyttä', () => {
  assert.equal(visibleGroupTabs(cash, can(['payments.manage', 'invoices.manage', 'pos.use'])).some((t) => t.path === 'pikakassa'), false);
  assert.deepEqual(resolveAdminPath('pikakassa'), { path: 'pikakassa', legacyReservations: false, groupId: null, tabId: null });
  assert.equal(groupAllowed(cash, can(['pos.use'])), false);
});

test('nav-group piirtää linkin samaan reittiin', () => {
  const src = readFileSync(new URL('../admin/views/nav-group.js', import.meta.url), 'utf8');
  assert.match(src, /href: `#\/\$\{l\.path\}`, testid: `nav-group-link-\$\{l\.id\}`/);
  assert.match(src, /groupTabs\.length \+ groupLinks\.length < 2/);
});
