# Regulatory-floor variant — prereg DRAFT (2026-08-10; freezes at merge)

Owner decision (2026-08-10): build the support-scheme reading of the collapse
depth as an INDEPENDENT, parallel-analyzable track — **the canonical record
stays purely competitive**, and the regulatory variant lives under its own
labels so every analysis can compare the two worlds side by side. (The
round-2 finding this answers: the deep-collapse residual — model −20 vs
settled −80..−300 — is bid-side, set by support-scheme negative bidding;
docs/experiments/continental-collapse/round2-results-2026-08.md.)

## The two worlds, both first-class

- **World C (competitive, canonical)**: the existing record. Support schemes
  appear only as the generic price-taker/floor behaviour (cv31 −20). Its
  gap to settled prices in deep-collapse hours is a MEASURED residual.
- **World R (regulatory)**: identical book except the deep-tranche floor per
  zone derives from PUBLISHED support-scheme parameters (premium/strike
  levels × the negative-price rules × the fleet vintage split — the desk
  research underway provides the sourced table). Own `clearing_mode` labels;
  never written to the canonical record path; compared to World C with the
  standard label-vs-label tooling.

## Mechanism (World R, switch-gated) — REVISED per the desk research

The research ([support-schemes-2026-08.md](support-schemes-2026-08.md))
kills the single-number floor: the correct ex-ante object is a per-zone
NEGATIVE LADDER of three sourced blocks, replacing the flat −20 in regime
hours:

1. **Legacy inelastic block**: share `w_a` of the RES forecast (legacy
   FiT/OA vintages) priced at the exchange floor −500 — volume, rarely
   marginal (FR OA ≈ 40% of supported energy; DE pre-2016 vintages).
2. **Elastic premium block**: share `w_b` priced at −(premium level) from
   the sourced table (DE ~−50, PL strike-based, BE offshore −90..−138,
   NL-old −premium), truncated where N-hour rules apply — v1 ignores
   streak dynamics and DECLARES this simplification (v2 could condition on
   expected streak length).
3. **New-vintage block**: share `w_c` at ≈ 0 (DE ≥Feb-2025, NL 2023+).

Zone exceptions the research forces: **CH gets NO regulatory floor** (no
per-MWh subsidy — its census wall must be non-subsidy physics), and **FR's
ladder is bimodal (0 / −500)** with no premium band. Vintage shares come
from installation-year splits (declared estimates where no official split
exists — the flagged gaps are listed in the research doc). Every number
carries its citation. Switch: `EUPHEMIA_ENABLE_REGFLOOR` (+ zone list),
default OFF; all-off byte-identical guard.

## Evaluation (frozen at ratification, after the desk research lands)

- Arms: World-C base (reuse `cv34_baseFY`) vs World-R, full year, ISO-week
  A/B split, paired-by-day bootstrap (the round-2 significance recipe).
- **Primary (regime-conditional)**: deep-collapse DEPTH error (mean |model −
  settled| over settled ≤ −50 hours, the six floor zones) improves ≥ 30%
  on A AND B; within-regime MAE not worse than +0.2; phantom rate not up;
  envelope/caps guards standard.
- Deliverable regardless of gates: the World-C vs World-R comparison table —
  the owner's ask is the ANALYSIS of both, not only a ship decision. If
  World R passes its gates it becomes a maintained parallel label (and a
  candidate for the product's "regulatory view"); the canonical record
  remains World C either way.

## Status

- [ ] Desk research: sourced per-country support-scheme table (agent running)
- [ ] D_z derivation committed with citations
- [ ] Prereg ratified (freezes at merge)
- [ ] Implementation + identity guard
- [ ] World-R year run → A/B scoring → the two-world comparison report
