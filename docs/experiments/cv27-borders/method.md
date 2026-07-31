# cv27 BORDER PROGRAM — frozen method (2026-07-30)

Turns the cv27 T1 finding (FBMC demonstrated-capability re-basing worth ~1 MAE
+0.02 corr on the footprint, but breaches DE_LU/AT under a global rule) into a
per-border capacity program. Accept/reject PER PHYSICAL BORDER (both directions
together — the measured DK2 asymmetry lesson).

## Phase 0 — border-list control (DONE, committed)
`src/Network.jl` T1 override extended with `EUPHEMIA_CV27_T1_BORDERS`:
- PRESENT in ENV → border-list mode: demonstrated-capability override applies
  ONLY to the listed directed borders ("A>B,B>A,..."), regardless of da_ever.
  Both physical directions symmetrized in code. Empty value = no borders = OFF.
- ABSENT → legacy T1b behaviour unchanged (guards stay bit-identical).
Polarity proven: DE_LU~NL arm moves ONLY DE_LU<->NL capacity (blend-sum
20295 -> demonstrated-sum 137840, both directions); every control border
Δ=0 (assert). SE2~SE3 probe revealed the key structural fact below.

**Isolation for arms:** an arm sets `EUPHEMIA_DISABLE_CV27_T2=1`,
`EUPHEMIA_DISABLE_CV27_T3=1`, `EUPHEMIA_CV27_T1_BORDERS="<border both dirs>"`
(CV27 master ON). vs cv26 baseline (`EUPHEMIA_DISABLE_CV27=1`) this differs
ONLY by the one border's capacity. Empty-border arm == cv26 (byte-identity
guard cell).

## Phase 1 — candidate borders (FROZEN, no measurement yet)
Enumerated from `offered_transfer_capacities_implicit` (2025-01-01+): directed
borders with a persistent Intraday-only regime (n_da==0 for >=30 days), both
endpoints in the 39-zone footprint. Ranked by expected leverage
`|demonstrated p95 − intraday-blend| × id-only-hours`, summed over both
directions per physical border.

**CRITICAL FILTER:** the T1 override only reaches the model on borders that
SURVIVE `flow_based_drop_borders` (dropped borders are replaced by observed
net-import flows, so overriding their ATC is inert — verified: SE2~SE3 override
fires on 40 rows but changes 0 final capacities). Dropped set (39-zone): all
Norwegian↔Nordic, FI–SE1/SE3, HU–AT/SK, BE–FR/NL/DE_LU, SE2–SE3, SE3–SE4,
SK–CZ/PL, AT–CZ/DE_LU/SI. Candidates = surviving borders only.

Top 12 surviving physical borders (frozen candidate set):

| # | border | lev(sum) | dirs (blend→p95) |
|---|--------|---------:|---|
| 1 | DE_LU~NL | 76.1M | NL>DE_LU 708→3916; DE_LU>NL 758→3076 |
| 2 | DE_LU~FR | 67.2M | DE_LU>FR 604→2371; FR>DE_LU 613→3722 |
| 3 | IT-CSOUTH~IT-SOUTH | 43.5M | CSOUTH>SOUTH 4939→1462; SOUTH>CSOUTH 2945→3732 |
| 4 | DE_LU~PL | 43.4M | PL>DE_LU 303→1551; DE_LU>PL 154→2056 |
| 5 | CH~FR | 40.8M | FR>CH 194→3541; CH>FR 3306→1599 |
| 6 | CZ~DE_LU | 40.2M | DE_LU>CZ 301→2103; CZ>DE_LU 653→1767 |
| 7 | CZ~PL | 32.5M | PL>CZ 288→1841; CZ>PL 165→972 |
| 8 | SE1~SE2 | 29.9M | SE1>SE2 588→2434; SE2>SE1 1796→1469 |
| 9 | IT-CNORTH~IT-NORTH | 29.2M | NORTH>CNORTH 2751→3548; CNORTH>NORTH 4550→2483 |
| 10 | DE_LU~DK2 | 19.0M | DK2>DE_LU 143→812; DE_LU>DK2 240→951 |
| 11 | DK1~SE3 | 16.8M | DK1>SE3 160→712; SE3>DK1 46→715 |
| 12 | IT-Calabria~IT-Sicily | 15.0M | Calabria>Sicily 874→1354; Sicily>Calabria 1869→879 |

## Phase 2 — per-border screening
Panel = 8 days: 1st+15th of 2025-01, 2025-05, 2025-07, 2026-01
(2025-01-01,15; 2025-05-01,15; 2025-07-01,15; 2026-01-01,15). All 8 are Set-A
days with existing cv26 baseline cells in `scratchpad/p7/cv26_*.tsv` (REUSED).
Each candidate: one arm (both directions), 8 cells. Fresh julia per (arm,day),
HiGHS, extract read-only, 6-way concurrency.

Gates per border (frozen), panel MAE/corr vs cv26 hourly (scored against
`entsoe.energy_prices` Day-ahead, same scorer family as cv27):
- (i) neither endpoint zone worsens MAE > +1.0;
- (ii) no OTHER zone worsens MAE > +2.0 or corr < −0.04;
- (iii) footprint aggregate MAE not worse than +0.05.
ACCEPT iff all three pass. Record verdict + numbers per border.

## Phase 3 — combination
Arm = union of accepted borders (all listed directed pairs), full 24-day Set A
(days in `scratchpad/run_cv27.sh`), cv26 baseline cells reused from p7.
Gates: inherited envelope (+3.0 MAE / −0.05 corr any zone), ZERO new cap hours
(sim ≥ 2999), aggregate beats cv26 (ΔMAE<0 AND Δcorr > −0.005).

## Phase 4 — Set B confirm (only if Phase 3 passes)
Union arm on Set B days (in run_cv27.sh), cv26 Set-B baseline run once. Final
report. Branch stays UNMERGED.
