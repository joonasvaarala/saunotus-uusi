// deno test -A --no-lock --node-modules-dir=none booking/supabase/functions/send-emails/staff_notice_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import { renderStaffNotice } from "./staff_notice.ts";

Deno.test("staff_shift_notice: teksti sellaisenaan, html escapattu, linkki vain https", () => {
  const m = renderStaffNotice({ subject: "Työvuoroilmoitus – Tapio", text: "Hei Otto.\nLämmitysvuoro <b>ilman tekijää</b>.\nhttps://example.test/a?token=x&y=1\n\n–Tapio" });
  assert(m);
  assertEquals(m.subject, "Työvuoroilmoitus – Tapio");
  assert(m.text.endsWith("–Tapio"));
  assert(!m.html.includes("<b>") && m.html.includes("&lt;b&gt;"));
  assert(m.html.includes('href="https://example.test/a?token=x&amp;y=1"'));
  assert(m.html.includes("#F4EFE7") && m.html.includes("#2B3A30") && !/blue|#00f|#0000ff/i.test(m.html));
  const j = renderStaffNotice({ subject: "S", text: "javascript:alert(1) http://x.test", link_url: "javascript:alert(1)" });
  assert(j && !j.html.includes("href"));
  assertEquals(renderStaffNotice({ subject: "", text: "x" }), null);
  assertEquals(renderStaffNotice(null), null);
  const l = renderStaffNotice({ subject: "S", text: "Hei", link_url: "https://joonasvaarala.github.io/saunotus-uusi/vuoro/oma/?token=abc" });
  assert(l && l.text.endsWith("?token=abc"));
});
