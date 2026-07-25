#!/usr/bin/env python3
"""Evaluate the cv22 combined-confirm gates from results_price_ab.tsv.

Gates:
- ua2 HU July gain reproduces: HU july MAE improvement >= 10.5 (>=70% of -15)
  and corr improvement > 0.
- No zone degrades >0.03 corr or >1.5 MAE in any window, EXCEPT the pre-accepted
  ua2 residuals: HU march evening (eve_mae), RO/BG march (~+1 MAE).
"""
import os
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
r = pd.read_csv(os.path.join(HERE, "results_price_ab.tsv"), sep="\t")
b = r[r.arm == "base"].set_index(["window", "zone"])
c = r[r.arm == "cv22"].set_index(["window", "zone"])
j = b.join(c, lsuffix="_b", rsuffix="_c")
j["dmae"] = j.mae_c - j.mae_b
j["dcorr"] = j.corr_c - j.corr_b

print("=== HU July gate ===")
hu = j.loc[("july2026_failure", "HU")]
print(f"HU july MAE {hu.mae_b:.2f} -> {hu.mae_c:.2f} (Δ{hu.dmae:+.2f}); "
      f"corr {hu.corr_b:.2f} -> {hu.corr_c:.2f} (Δ{hu.dcorr:+.2f})")
gate_hu = (hu.dmae <= -10.5) and (hu.dcorr > 0)
print("HU July gate:", "PASS" if gate_hu else "FAIL")

# Accepted degradations (documented): (window, zone, metric)
ACCEPTED = {("march2026_stable", "HU", "eve"),
            ("march2026_stable", "RO", "mae"),
            ("march2026_stable", "BG", "mae")}
print("\n=== Degradation scan (>0.03 corr or >1.5 MAE) ===")
viol = []
for (w, z), row in j.iterrows():
    bad_mae = row.dmae > 1.5 and (w, z, "mae") not in ACCEPTED
    bad_corr = row.dcorr < -0.03
    if bad_mae or bad_corr:
        viol.append((w, z, row.dmae, row.dcorr))
        print(f"  VIOLATION {w:22} {z:12} dMAE={row.dmae:+.2f} dcorr={row.dcorr:+.3f}")
if not viol:
    print("  none (excluding accepted HU-March-eve / RO,BG-March-MAE residuals)")

# Report the accepted residuals explicitly
print("\n=== Accepted ua2 residuals (documented) ===")
for w, z in [("march2026_stable", "RO"), ("march2026_stable", "BG")]:
    if (w, z) in j.index:
        print(f"  {z} {w} MAE Δ{j.loc[(w,z)].dmae:+.2f}")
if ("march2026_stable", "HU") in j.index:
    hm = j.loc[("march2026_stable", "HU")]
    print(f"  HU march eve_mae {hm.eve_mae_b:.2f} -> {hm.eve_mae_c:.2f} "
          f"(Δ{hm.eve_mae_c - hm.eve_mae_b:+.2f})")

print("\nOVERALL:", "PASS" if gate_hu and not viol else "REVIEW")
