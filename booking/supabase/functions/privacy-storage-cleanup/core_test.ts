// deno test: privacy-storage-cleanup/core.ts (booking_160)
import { assertEquals } from "jsr:@std/assert@1";
import { chunk, planRemoval, validItem } from "./core.ts";

const items = (n: number, bucket = "receipts") => Array.from({ length: n }, (_, i) => ({ bucket, path: `K-2019-${i}.pdf` }));

Deno.test("disabled: ei poistoa", () => {
  assertEquals(planRemoval({ enabled: false, dry_run: false, items: items(3) }, false).mode, "disabled");
  assertEquals(planRemoval(null, false).mode, "disabled");
  assertEquals(planRemoval({ enabled: "true", dry_run: false, items: [] }, false).mode, "disabled");
});

Deno.test("dry_run: oletus, asetus tai pyyntö", () => {
  assertEquals(planRemoval({ enabled: true, items: items(1) }, false).mode, "dry_run");
  assertEquals(planRemoval({ enabled: true, dry_run: true, items: items(1) }, false).mode, "dry_run");
  assertEquals(planRemoval({ enabled: true, dry_run: "false", items: items(1) }, false).mode, "dry_run");
  assertEquals(planRemoval({ enabled: true, dry_run: false, items: items(1) }, true).mode, "dry_run");
  assertEquals(planRemoval({ enabled: true, dry_run: false, items: items(1) }, false).mode, "remove");
});

Deno.test("erät 100 kpl säiliöittäin, duplikaatit pois", () => {
  const p = planRemoval({ enabled: true, dry_run: false, total: 251, items: [...items(250), ...items(1, "invoices"), items(1)[0]] }, false);
  assertEquals(p.batches.map((b) => [b.bucket, b.paths.length]), [["invoices", 1], ["receipts", 100], ["receipts", 100], ["receipts", 50]]);
  assertEquals(p.total, 251);
});

Deno.test("vaaralliset polut ja julkiset säiliöt hylätään", () => {
  assertEquals(validItem({ bucket: "receipts", path: "../x.pdf" }), false);
  assertEquals(validItem({ bucket: "receipts", path: "/x.pdf" }), false);
  assertEquals(validItem({ bucket: "receipts", path: "a//x.pdf" }), false);
  assertEquals(validItem({ bucket: "product-images", path: "x.jpg" }), false);
  assertEquals(validItem({ bucket: "article-images", path: "x.jpg" }), false);
  assertEquals(validItem({ bucket: "receipts", path: 5 }), false);
  assertEquals(validItem({ bucket: "receipts", path: "K-2019-1.pdf" }), true);
  const p = planRemoval({ enabled: true, dry_run: false, items: [{ bucket: "product-images", path: "a.jpg" }, { bucket: "receipts", path: "../a" }, ...items(1)] }, false);
  assertEquals(p.rejected, 2);
  assertEquals(p.batches, [{ bucket: "receipts", paths: ["K-2019-0.pdf"] }]);
});

Deno.test("chunk", () => {
  assertEquals(chunk([1, 2, 3], 2), [[1, 2], [3]]);
  assertEquals(chunk([], 2), []);
});
