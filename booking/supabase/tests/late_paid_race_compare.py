"""LOCAL ONLY. Vertaa late_paid_race.py baseline- ja fix-ajon tuloksia: fix ei saa tuoda uusia virheitä; ainoa sallittu ero on, että
baseline herätti perutun tilauksen (revived_cancelled_order) ja fix pitää sen peruttuna + audit + ei vahvistusviestiä."""
import json, sys
B = {l["key"]: l for l in map(json.loads, open(sys.argv[1]))}; F = {l["key"]: l for l in map(json.loads, open(sys.argv[2]))}
bad = 0
for k in B:
    b, f = B[k], F.get(k, {})
    if "harness_error" in b or "harness_error" in f: print("HARNESS", k, b.get("harness_error"), f.get("harness_error")); bad += 1; continue
    cb, cf = b["class"], f["class"]
    new_err = [e for e in cf["errors"] if e not in cb["errors"]]
    if cb["revived_cancelled_order"]:
        ok = (not new_err and cf["order"] == "cancelled" and cf["late_audit"] == 1 and cf["confirm_mail"] == 0 and cf["pay_class"] == cb["pay_class"]
              and cf["paid_n"] == cb["paid_n"] and cf["res"] == cb["res"] and not cf["revived_cancelled_order"])
        tag = "FIXED"
    else:
        ok = not new_err and cf == cb
        tag = "SAME"
    if cf["interleave_proven"] is False or cb["interleave_proven"] is False: ok = False; tag += "/INTERLEAVE_NOT_PROVEN"
    print(("PASS " if ok else "FAIL ") + f"{tag:8} {k:22} base={json.dumps(cb, ensure_ascii=False)}\n{'':32}fix ={json.dumps(cf, ensure_ascii=False)}")
    bad += not ok
print(f"COMPARE {'OK' if not bad else 'FAIL'} cases={len(B)} bad={bad}"); sys.exit(1 if bad else 0)
