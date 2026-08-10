# Continental package (cv34) — Set A results (2026-08-10): NO A-PASS

Prereg: [prereg-draft-2026-08.md](prereg-draft-2026-08.md) (frozen at merge,
#325). Seven leave-one-out arms, 39-zone coupled clear, offline extract, Set A
2025-08-01..2026-01-31, labels `cv34_{base,t1,t2,t3a,t3b,t4,combo}A`; 164
common days. Evaluation regime: share ≥ 0.4 (FR: 0.3), declared pre-scoring.

## Gate table (six floor zones, within regime)

| arm | MAE | bias | deep capture (n=10) | FR hit (n=61) | phantoms | outside MAE |
|---|---|---|---|---|---|---|
| base | 22.22 | +17.6 | 50.0% | 11.5% | 0 | 20.94 |
| T1 θ_FR | 22.20 | +17.5 | 50.0% | 11.5% | 0 | 20.94 |
| T2 tier −80 | 22.11 | +17.2 | 50.0% | 9.8% | 0 | 20.94 |
| T3a pump η=.7 | 25.89 | +22.7 | **0.0%** | **3.3%** | 0 | 20.96 |
| T3b pump η=.6 | 25.54 | +22.1 | 0.0% | 3.3% | 0 | 20.96 |
| T4 wall | 22.27 | +17.5 | 50.0% | 11.5% | 0 | 20.94 |
| combo | 25.95 | +22.6 | 0.0% | 3.3% | 0 | 20.96 |

Envelope: zero breaches, zero new caps, footprint |dMAE| ≤ 0.05 everywhere.
Per-zone phantom "increases" in T1/T4 are ±1-hour knife-edge flips in IT
zones the levers never touch (branch noise, quarantine class; measured
141→142 etc.).

**No arm meets P1 (−1.0 six-zone regime MAE; best: T2 −0.11). Per the frozen
protocol there is no A-pass and Set B is not scored.** Branch
`feat/cv34-levers` stays unmerged as the archive.

## The two findings that matter

1. **The calendar A/B split starves Set A of the regime.** The deep-collapse
   family holds **10 hours** in the entire Aug–Jan window (vs ~170
   full-year); FR collapse hours: 61, and winter FR collapses sit below even
   θ=0.3 (they are wind/nuclear events, not solar). T1/T2/T4 measure as
   no-ops on A not because they are wrong but because their season is
   absent — the mirror image of the IT-package seasonal-gate lesson, now
   recorded for the harness: **spring-regime packages need regime-balanced
   evaluation windows (split by regime-hour count, not by calendar), frozen
   as such in the successor prereg.**
2. **T3's failure is the package's most valuable measurement.** Pumping
   demand at η × evening value LIFTS the model price exactly where the real
   market collapsed (deep capture 50% → 0%): the mechanism double-counts,
   because ENTSO-E's D-1 **total load forecast already includes
   pumped-storage consumption** — the pumps' demand is in the book's demand
   side before we add it again. The real design is **incremental**: model
   only the delta between demonstrated pumping capability and the
   fc-embedded expected pumping (or decompose the load's pumping component
   and make THAT price-responsive). The owner's η-pricing survives intact;
   the quantity basis was wrong. Redesign goes to the successor prereg.

## Status

NO-SHIP as measured on this prereg (no A-pass, no B scoring). Successor
prereg requirements: regime-balanced windows; T3 as incremental pumping;
T1/T2/T4 carried over unchanged (benign, unmeasured in their season).
Arms retained in results.duckdb.
