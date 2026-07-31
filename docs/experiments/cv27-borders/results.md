# BORDER PROGRAM — STATUS

## Phase 0 — border-list control: DONE (commit 69e0972)
- `EUPHEMIA_CV27_T1_BORDERS` implemented in src/Network.jl. Present→border-list
  mode (both dirs symmetrized, da_ever ignored); empty=OFF; absent=legacy T1b.
- Polarity proven on DE_LU~NL (only that border moves; all controls Δ=0).
- Structural finding: dropped borders (flow_based_drop_borders) are INERT to the
  override (SE2~SE3 fires 40 rows, changes 0 final caps). Candidate set filtered
  to SURVIVING borders only.

## Phase 1 — candidates: FROZEN (see method.md)
Top 12 surviving Intraday-only borders by leverage: DE_LU~NL, DE_LU~FR,
IT-CSOUTH~IT-SOUTH, DE_LU~PL, CH~FR, CZ~DE_LU, CZ~PL, SE1~SE2,
IT-CNORTH~IT-NORTH, DE_LU~DK2, DK1~SE3, IT-Calabria~IT-Sicily.

## Phase 2 — per-border screening: IN PROGRESS
(verdicts appended below as cells complete)

### Phase 0 isolation guard: PASS
empty-border arm (T2/T3 off, T1 empty) == cv26 baseline on 2025-01-15,
936/936 rows, max|Δ|=0.00e+00 BYTE_IDENTICAL. Arm setup validated.

### Phase 2 launched 6-way (96 cells). Cell ~4-5 min. ETA ~70 min.

### Supervisor note re IT-internal borders (b03/b09/b12): RESOLVED — override DOES fire
Supervisor flagged that IT internals may carry Day-ahead rows (live Postgres:
IT-CNORTH>IT-NORTH avg DA 3,675 MW) making the arm a no-op. Checked directly on
the EXTRACT (the campaign's data store): IT-CSOUTH~IT-SOUTH, IT-CNORTH~IT-NORTH,
IT-Calabria~IT-Sicily all have n_da==0 on every panel day (da_hrs=0/24). Cell
logs confirm each IT arm fires "🔁 cv27 T1: 48 Day-ahead-free border-hours"
(=2 dirs × 24h, one border) — identical count to DE_LU~NL. So on the extract the
override is ACTIVE on IT internals; they are NOT no-ops. Extract vs live DA
availability differs (extract windows/omits some DA rows), but the entire program
— baselines, arms, scoring — is internally consistent on the extract. No
candidate promotion required.

## Phase 2 — per-border verdicts (panel 8 days, 7488 cells/arm, vs cv26)
cv26 baseline panel agg MAE = 31.40.

| border | verdict | endpoint MAE Δ | agg Δ | cap-dir note (cv29) |
|--------|---------|----------------|-------|----------------------|
| DE_LU~FR | ACCEPT | DE_LU +0.26, FR −0.90 | −0.06 | both dirs increase |
| CH~FR | ACCEPT | CH −5.77 (corr +0.237!), FR −0.42 | −0.13 | **CH>FR REDUCES 3306→1599** |
| CZ~PL | ACCEPT | CZ −3.70, PL −0.87 | −0.17 | both dirs increase |
| SE1~SE2 | ACCEPT | SE1 −2.11, SE2 −0.53 | −0.07 | **SE2>SE1 REDUCES 1796→1469** |
| IT-CNORTH~IT-NORTH | ACCEPT | CN −1.36, N +0.44 | −0.17 | **CN>N REDUCES 4550→2483** |
| DK1~SE3 | ACCEPT | DK1 −3.03, SE3 −1.60 | −0.03 | both dirs increase |
| IT-Calabria~IT-Sicily | ACCEPT | Cal +0.50, Sic +0.29 | −0.00 | **Cal<>Sic one dir REDUCES 1869→879** |
| DE_LU~NL | REJECT | DE_LU **+1.75** (>+1.0) | +0.08 | gate(i) fail |
| IT-CSOUTH~IT-SOUTH | REJECT | IT-CSOUTH **+1.70**, corr −0.036 | −0.24 | gate(i) fail |
| DE_LU~PL | REJECT | DE_LU **+2.87** | −0.05 | gate(i) fail |
| CZ~DE_LU | REJECT | DE_LU **+1.39** | +0.02 | gate(i) fail |
| DE_LU~DK2 | REJECT | endpoints OK, **EE breach** dMAE+1.37/dcorr−0.088 | +0.00 | gate(ii) fail |

Structural read: every DE_LU-touching import border EXCEPT DE_LU~FR degrades DE_LU
(reproduces the cv27 global-T1 DE_LU +3.7 breach at the per-border level); DE_LU~FR
is the exception (DE_LU only +0.26, both zones' corr up). 4 accepted borders REDUCE
capacity on one direction vs the intraday blend (cv29 scrutiny flag) yet still
improve their endpoints and add zero caps at panel scale — the Phase-3 caps gate
is the decisive check for these.

ACCEPTED SET (7): DE_LU~FR, CH~FR, CZ~PL, SE1~SE2, IT-CNORTH~IT-NORTH, DK1~SE3,
IT-Calabria~IT-Sicily.

## Phase 3 — combination (union of 7) on full 24-day Set A: LAUNCHED (10-way)

## Phase 3 — combination (union of 7) on full 24-day Set A: PASS
cells=22,464. cv26 MAE 31.58 corr 0.692 → combo MAE 31.14 corr 0.701
(ΔMAE −0.44, Δcorr +0.009). Envelope breaches: 0. New cap hours (≥2999): 0
(cv26 total 0, combo total 0). cv29 scrutiny: the 4 capacity-reducing borders
(CH>FR, SE2>SE1, IT-CNORTH>IT-NORTH, one IT-Cal/Sic dir) added ZERO cap hours and
no envelope breach — reduction did not manufacture scarcity here.
GATES: aggregate PASS, envelope PASS, caps PASS -> PHASE3 PASS.
Top wins: SE3 35.3→33.0 (corr .586→.651), DK1 26.0→24.1 (.799→.839),
CZ 34.7→32.9 (.605→.666), CH 32.2→31.4 (.623→.735), FR 25.0→23.7, IT-family −1..−1.5.
Mild costs (within envelope): AT +0.78 MAE (corr .806→.833), SK +1.21 (corr up).

## Phase 4 — Set B confirm: LAUNCHED

## Phase 4 — Set B confirm: PASS
cells=21,489. cv26 MAE 28.58 corr 0.454 → combo MAE 28.17 corr 0.450
(ΔMAE −0.41, Δcorr −0.004). Envelope breaches: 0. Caps: 6 both, 0 new.
GATE aggregate (ΔMAE<0 & Δcorr>−0.005): PASS (Δcorr −0.004 is inside the gate by
0.001 — a near-miss on correlation; MAE clearly better). Set B is a lower-corr
regime (harder mid-month days). 2/24 combo days truncated (2025-05-04→2h,
2026-05-25→21h) BUT the cv26 baseline truncates IDENTICALLY (missing D-1 load
hours at source — documented cv24/cv25 partial-day issue, not treatment-induced);
scorer intersects cells so the comparison is fair.
Set B wins: FR −2.47, SE1 −2.28 (corr .563→.673), IT-family −1.0..−1.3, SE3 −1.8.
Costs (within envelope): CH +1.15, AT +1.06.

## FINAL: SHIP the 7-border program (see final report). Branch UNMERGED.
