# Continental collapse package (cv34 target) — prereg DRAFT (2026-08-10)

Freezes at merge, before any scored run. Evidence base:
[census-2026-08.md](census-2026-08.md) (three pathologies, four named walls,
all measured on the coupled path). Owner directives incorporated (2026-08-10):
target version **v34** (owner-designated; v33 stays unused), pumped-storage
demand priced at **η × the estimated later-today value** with η ∈ {0.6, 0.7}
as the declared A/B points, candidate scope = every zone with demonstrated
pumping (not only CH), Norway included where measurable (NO2/NO5).

## Levers (each an isolated switch; leave-one-out attribution)

- **T1 — zonal gate for FR**: θ_FR = 0.3 (vs the group default 0.4). One
  declared parameter. Evidence: FR deep collapses cluster at share 0.31–0.33,
  0% reach 0.4; a 0.3 threshold covers nearly all while staying above FR's
  normal midday share.
- **T2 — deep-tier floor** (DE_LU/PL/BE families): when the solar share also
  clears θ2 = 0.7, the regime floor deepens from −20 to −80 (the deep-collapse
  settled median range). Two declared parameters (θ2, floor2), both named
  from the census distribution, frozen here.
- **T3 — surplus pumping demand** (the owner's mechanism): in regime hours,
  each qualifying zone gains an elastic DEMAND order — quantity = trailing-30d
  p95 of observed pumped-storage consumption (`actual_consumption_mw`,
  ex-ante, 2-day lag), price = **η × (pass-1 estimate of the same day's
  evening value)** (max of the zone's pass-1 hourly prices, the two-pass
  anchor pattern; pumping zones join the pass-2 rebuild set). η ∈ {0.6, 0.7}.
  Candidates (demonstrated p95 pumping, trailing year): DE_LU 5.2 GW, ES 3.9,
  FR 3.0, PT 2.3, AT 1.5, IT-NORTH 1.3, CZ 1.0, PL 0.9, BE 0.7, SK 0.6,
  IT-Sicily 0.5, IT-CSOUTH 0.5, LT 0.4, **NO2 0.4, NO5 0.3**, GR 0.35,
  IT-Sardinia 0.2.
  **CH exception (honest data gap)**: ENTSO-E carries no CH pumping
  consumption despite ~4 GW installed. Two exploratory sub-arms, at most one
  ships: (a) proxy capability = installed pumping × the neighbours' trailing
  utilization pattern; (b) supply-side instead — regime-conditional
  water-value yield (the anchored reservoir block prices at the floor
  in-regime). Whichever survives its arm.
- **T4 — thermal valley wall** (CZ/PL): the valley-continuation family,
  re-gated with the GR selectivity lesson: the continuation tranche fires
  only where the **pass-1 coupled price itself ≤ €5** (the model's own
  surplus signal replaces the blunt share×window gate — phantom control by
  construction). Quantity recipe unchanged from the GR archive (overnight-
  runner test, p25 committed MW).

## Frozen evaluation (per the R-harness)

- Arms on the offline extract, fresh coupled baselines, Set A
  2025-08-01..2026-01-31 derive → Set B 2026-02-01..2026-07-28 scored once on
  an A-pass. Leave-one-out: base, T1, T2, T3(η=0.6), T3(η=0.7), T4, combo.
- **Primary (regime-conditional, per zone family)**: within-regime MAE of the
  six floor zones improves ≥ 1.0 on A AND B; deep-collapse capture (model ≤
  −20 when settled ≤ −50) ≥ +20 points on the D/PL/BE family; FR collapse
  hit-rate (model ≤5 when settled ≤5) ≥ +15 points.
- **Falsifiers**: phantom-collapse rate (model ≤5, settled >20) not up in ANY
  zone (the GR lesson, hard); envelope ±3.0 MAE / −0.05 corr on all 39; zero
  new non-quarantine cap hours; outside-regime |ΔMAE| ≈ 0 by construction.
- SEE byte-identity guard: all-off == baseline bit-identical.

## Status

- [x] Census (steps 1–3, coupled path) — merged record
- [x] Pumping-capability coverage measured (table above; CH gap named)
- [ ] Prereg ratified (freezes at merge)
- [ ] Implementation behind per-lever switches + identity guard
- [ ] Set A leave-one-out → A-pass decision → Set B once
- [ ] Ship/no-ship on the numbers → cv34 record refill decision
