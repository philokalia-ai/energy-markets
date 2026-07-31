# STRATEGY — what this program is and how it advances

**The claim** (owner, #227): a competitive counterfactual of the EU day-ahead
market built from **ex-ante inputs** with a **transparent bidding methodology**;
parameters are allowed when they are *nameable market characteristics*,
calibrated on Set A and **validated out-of-sample** on Set B. ("No-fit" was
retired for this sharper claim.)

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

**Boundaries**: conduct residuals (PL import premium, near-cap withheld
tails) are measured and reported, never reproduced. HiGHS is the
reproducibility solver (records/confirms); Gurobi is a dev-iteration tool.
