# TR/MK boundary book — Set A results: measured NO-SHIP (2026-08-05 night)

Scored exactly per the frozen prereg (`prereg-2026-08.md`, incl. Amendment 1's
fresh all-off baseline). Set A = 2026-07-08..07-21, both arms fresh on live
Postgres, announced inputs, 12,168 paired zone-hours, 0 failed days.

## Gates

| gate | result |
|---|---|
| **PRIMARY** false-collapse hours BG+GR (sim ≤ €20 & settled ≥ €60) −40% | base **82** → treat **70** = **−15%** → **FAIL** |
| zero new cap hours any zone | 0 → 0 → PASS |
| envelope ΔMAE ≤ +3.0 / Δcorr ≥ −0.05, all 39 | worst ΔMAE +0.13 (RO), worst Δcorr −0.008 (RS) → PASS |
| BG/GR day-MAE not worse by > 0.5 | GR **−0.61**, BG +0.04 → PASS |

Direction right everywhere it touches (GR −0.61 MAE; LT/LV −0.23 with corr
+0.018; HU −0.14), zero collateral — but the primary effect is ~a quarter of
the frozen bar. **Per the discipline: no Set B, branch stays unmerged, the
switch stays opt-in-experimental.**

## The lesson (what the 15% is telling us)

The book's export-demand floor sits at the TR-anchored willingness (€43.5–68.9
on the July anchor) over a demonstrated drain of ~150–500 MW per hour. It
lifts exactly the SHALLOW false-collapse hours (12 of 82). The remaining mass
has surplus far beyond the TR+MK interconnector scale — the sim clears at
€1–16 with the drain already exhausted. The false-collapse phenomenon is
therefore NOT primarily a TR/MK-absorption deficit; the census's other two
suspects — coupled GR/RO absorption behaviour and the domestic book's
deep-surplus floor (the cv31 solar-regime floor family, which does not cover
the SEE zones) — carry the mass. A SEE extension of the solar-regime-gated
floor, judged within its regime per the standing rule, is the natural
successor experiment; the TR/MK book remains available as a component (its
guards are clean and its flows leg was not the failure).

## What survives regardless of the gate

- The **census** (in the prereg): the TR/MK role split (TR import source, MK
  the firm export drain), the TL-capped/hydro-long TR price regime, and the
  chronic false-collapse counts (BG 67 h / 26 d over 45 days) are measured
  facts that any successor builds on.
- The **`epias.*` feed is live and wired**: the `:tr_trailing_mcp` anchor and
  its offline fallback are implemented, guarded, and byte-identical when off.
- Phase-1 gaps recorded: no publication stamps in `epias.*` (ETL item);
  `epias.*` absent from the extract (offline runs get the fallback anchor).

## Verification trail

Runner + scorer in the session scratchpad (`trmk/runner.jl`, `trmk/score.py`);
per-day CSVs for both arms; the all-off arm doubles as the byte-identity
evidence for the default path (it is the plain record path re-clear). The
stored-record pairing rejection (maxdelta 66.8 — extract-snapshot vs live
Postgres data drift) is Amendment 1's documented reason for the fresh
baseline.

## Full-year A/B (2025-08-01..2026-07-31, owner-requested before the ship call)

310,752 paired zone-hours (pipelined, epias-patched extract, fresh arms).
**Footprint MAE 29.52 → 29.56 (+0.04); false-collapse BG+GR −3%; target zones
worse (GR +0.47, RO +0.41, BG +0.24); the Set-B NO/SK/AT gains do not survive
the year (NO1 +0.02, SK +0.17, AT +0.11) — window-regime effects, the cv18
lesson now measured at 14-day scale too.**

Decompositions that settle both owner questions:

1. **The distant "gains" are bistability, not mechanism.** ES's whole-year
   corr +0.116 lives in ONE month (2026-07: base corr 0.466 → 0.899, max
   |arm-diff| = €2,990 — the BASE arm hit phantom-cap hours the treatment's
   tiny SEE perturbation avoided); IT-CSOUTH's +0.140 likewise (2026-04, max
   diff €2,997). Eleven of twelve months sit at dMAE ≈ 0.00. The coupled
   clear has near-degenerate branches around cap events; ANY small
   perturbation flips them — coin-luck, not signal. (This also retroactively
   discounts part of Set B's NO/SK/AT fortnight gains.)
2. **The target-zone damage is real and seasonal.** GR loses +2.25/+2.15 in
   Apr/May 2026 — TR's hydro-flood season, when the trailing-MCP anchor
   bottoms at €11–18 and the book floods GR with phantom cheap elasticity
   (65–78 hours/month with |Δ| > €20, sustained — mechanism, not luck).
3. **The theory the book encodes is empirically false on this border.** The
   census itself showed TR importing from BG at settled €270 while its own
   capped price sat at €73: TR/MK flows are SCHEDULED/bilateral, not
   price-responsive. The "dumb" :v3 analogue injection is the correct
   empirical model of a scheduled border; replacing it with rational
   arbitrage ladders replaces measurement with a theory the border violates.
   "Model the country" holds where the border clears through real auctions
   (GB/Viking); it fails where the flow is administrative.

**Final verdict: NO-SHIP confirmed at year scale, now with the mechanism of
its own failure measured.** The book stays opt-in-experimental; what ships
regardless: the epias feed in the extract builder, the `:tr_trailing_mcp`
anchor machinery, the pipeline switch forwarding, and the census. Successor
threads: the SEE solar-regime-floor extension (the false-collapse mass), and
the degenerate-branch/phantom-cap bistability revealed by the flip months
(base-arm ES July / IT-CSOUTH April caps) — its own diagnosis.
