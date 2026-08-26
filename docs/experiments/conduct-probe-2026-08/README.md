# Conduct probe (2026-08-26): is the residual physics or conduct?

Owner mode: explore ("think outside the box"), approved "Let's go". Budget:
one pass — dataset + probe models + book inversion, **no re-clearing**.

## Reframing

The program's purpose is evidence about market conduct; cv35 put the
counterfactual on the market's own network (JAO flow-based capacities), so the
residual `settled − counterfactual` is now worth studying as an object, not
chasing as error. The recalibration (recal-2026-08) showed bidding knobs are
inert on import-set zones — so WHAT is the remaining residual? Two independent
probes:

1. **Feature probe (GBM)**: per zone, predict the residual from ex-ante
   features; measure the incremental out-of-sample R² of *conduct* features
   (top-firm share, HHI, RSI, pivotality) over *physics* features (calendar,
   load, RES/import shares, margin, fuels, net position, JAO headroom).
   Grouped 5-fold CV by day. Residual predictable from physics → missing
   mechanism; predictable only with conduct features → markup candidate.
2. **Book inversion**: for each zone-hour, clear the zone's captured
   competitive order book standalone at the *actual* net position; implied
   markup = settled − that price. Studied via *within-zone* structure (peak
   premium vs own off-peak, seasonal), never levels.

## Data and coverage

- 48/52 Wednesdays 2025-07..2026-06 (4 missing book days: 2025-11-12,
  2026-03-18, 2026-06-03, 2026-06-24); 39 zones; 44,928 zone-hours; all with
  settled, cv35 counterfactual (`ab_jao_np`), and actual net position joined.
- Books: `data/web/v1/books/*.parquet` — **cv31 vintage** (per-unit tagged
  ladders; the counterfactual price is cv35 — a stated vintage mismatch,
  second-order for supply-curve shape).
- Actual net positions: `entsoe.physical_flows` BZN↔BZN.
- Firm attribution (`simulations.unit_firms`): **tier 1** = GR 99%, HU 88%,
  BG/RS 86%, FR 83%, RO 75% of named MW; Italy/ES/DE partial (39–61%);
  elsewhere zero → conduct features fall back to owner(unit)-level
  concentration, a lower bound. **Caveat**: non-tier-1 zones lean on synthetic
  `AGG-*` fleet-completion units, so firm-level claims are tier-1 only.

## Known artifacts (stated before results)

- The standalone inversion overstates p_comp for anchored/exporting zones
  (FR nuclear anchor, IT-Calabria) → markup LEVELS are biased low there; only
  within-zone temporal structure is used.
- The pivotal-hours markup split is contaminated by the same artifact (p_comp
  explodes exactly in tight hours) → not used for verdicts.
- `resid` inherits cv35's model error; a conduct verdict needs BOTH probes to
  agree and the physics R² to be low.

## Implied-markup structure (probe 2)

Within-zone peak premium of implied markup (evening 16–19 UTC vs own
off-peak), top of the table: **HU +137** (winter premium +105), **DK2 +63**
(winter +123), **PL +57**, **DK1 +57**, **DE_LU +52**, **EE +47** (winter
+150), **RS +45**. Bottom (negative, consistent with the known IT/ES over-bid
finding): IT zones −64..−124, BG −92, SI −46, FR −42. Full table:
`probe_markup_structure.csv`.

## Feature probe (probe 1)

(pending — filled by the GBM run)
