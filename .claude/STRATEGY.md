# STRATEGY — what this program is and how it advances

**The claim** (owner, #227): a competitive counterfactual of the EU day-ahead
market built from **ex-ante inputs** with a **transparent bidding methodology**;
parameters are allowed when they are *nameable market characteristics*,
calibrated on Set A and **validated out-of-sample** on Set B. ("No-fit" was
retired for this sharper claim.)

**The six pillars** (owner-ratified 2026-08, docs/six-pillars.md is the
authority): (1) the SOLVER — coupled 39-zone clearing, validated EXACT on
real published GME/OMIE books (€0.00; docs/experiments/pubbooks-clearing/);
(2-4) next-day LOAD / SOLAR / WIND predictions — the FITTED pillars
(per-zone-winner ML + linear packs, docs/predictions.md); (5) ORDER-BOOK
CONSTRUCTION from named ex-ante characteristics — constructed, never fitted
to prices; (6) OUT-OF-EU behaviors (GB/UA elastic boundary books; TR/AL/MK
fixed injections — a decision, not a gap). Fitted vs constructed is the
epistemology of the whole program and the site's global TRACK SWITCH:
*Predicted* (our inputs end-to-end — trust in the model) vs *As announced*
(ENTSO-E D-1 inputs — the fair evaluation of the bid mechanism); their gap
is the measured INPUT COST, and comparisons pair the SAME code_version only.

**The product surfaces**: (1) the RECORD — full-history backfill at a
code_version, published to Postgres/Metabase + site; ENTSO-E D-1 inputs +
ex-ante flows; the basis for scenario work (cold ironing etc.). (2) the
FORECAST — daily pre-gate prediction; `entsoe` reference track (post-gate
inputs, measures the mechanism) vs `weather` ex-ante track (all inputs ours —
the honest product). Vintages are immutable; slices never mix code_versions.

**How progress happens** (measured order of returns):
1. *Bug classes first* — input contamination and physics errors gave the
   largest jumps (canonical ATC; Day-ahead preference; ex-ante flows). Suspect
   data before inventing mechanisms.
2. *Mechanisms as bordered/zone-scoped programs* — global rules break
   calibrated equilibria (DE_LU lesson); per-border/zone screening with tied
   directions and frozen gates ships (cv27).
3. *Regimes next* — mechanisms that only exist under a regime (solar surplus,
   nuclear outage, hydro state, mix anomaly) are gated and judged WITHIN it;
   the regime axis differs per zone-group. The regime's frequency GROWS with
   the solar buildout: 2026-right beats 2023-average.
4. *The collapse question*: near RES-coverage the price answer is binary
   ("will middays collapse ≤€5?"); input accuracy there defines signal
   usefulness, and input + expression mechanism (≤0 floor, export capability)
   must ship together.

**Infrastructure posture**: the data we depend on lives locally — the
infra k3s runs open-meteo's download-gfs pipeline (previous_day1..7 served
from localhost; pankgeorg/infra #27/#28), fetchers are local-first with
public fallback, and every fetched vintage persists to data/gfs_vintages/.
No external rate limit may ever again pace a retrain or backfill.

**Boundaries**: conduct residuals (PL import premium, near-cap withheld
tails) are measured and reported, never reproduced. HiGHS is the
reproducibility solver (records/confirms); Gurobi is a dev-iteration tool.
