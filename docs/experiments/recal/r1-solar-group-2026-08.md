# R1 continental solar group — instrument scorecard (2026-08-09)

Extension of the R1 instrumentation to the cv31 collapse group (DE_LU / FR /
PL / BE / CZ / CH — the zones where the solar-regime floor is active and
solar-input accuracy is first-class for the collapse question). Same recipe
as r1-results / r1-iberia: actuals-target LightGBM on previous_day1 GFS
(train 2024-07..2026-06-14, valid 2026-06-15..07-27), scored vs per-type
hourly actuals, against the TSO D-1 fc and the linear packs.

| zone-target | TSO fc MAE | actuals-ML MAE | winner |
|---|---|---|---|
| DE_LU solar | **769.9** (corr 0.997) | 1,429.4 | TSO fc |
| DE_LU wind | **1,421.7** | 2,074.7 (pack) | TSO fc |
| FR solar | **393.3** (corr 0.993) | 936.3 | TSO fc |
| FR wind | **515.1** | 976.1 | TSO fc |
| PL solar | 486.3 | **426.3** (corr 0.986) | **actuals-ML (−12%)** |
| PL wind | **388.6** | 436.0 | TSO fc |
| BE solar | **202.1** | 343.3 | TSO fc |
| BE wind | **186.6** | 312.9 (pack) | TSO fc |
| CZ solar | **90.8** | 120.6 | TSO fc |
| CH solar | **98.2** | 146.9 | TSO fc |

(CZ/CH wind: no scorable rows in the valid window — not instrumented.)

## Verdict

The mature continental TSOs publish excellent D-1 RES forecasts — DE_LU solar
corr 0.997 is the best basis in the fleet, and the whole floor group except
Poland is already best-served by the raw fc. **The single winner is PL solar
(−12%)**: Poland joins the winner set (GR/RO/IT-Sicily/IT-Sardinia solar,
DK1 wind).

Per the ratified adoption principle ("if it improves even a little we keep
it, provided it is knowable the previous day") the PL series is D-1-legal and
worth emitting; per the co-adaptation rule it is NOT consumed until a PL
mechanism package validates it at year scale (the cv32 GR/RO/DK1 lesson: their
correction series sit in the table awaiting joint packages; PL joins that
queue). Emission requires only adding PL to the emitter's zone list + the
model file — deferred to the next emitter revision together with any owner
call on scope.

## Cumulative R1 map (13 zones instrumented)

- **ML wins solar**: GR (−48%), IT-Sicily (−45%), IT-Sardinia (−32%), RO (−19%), PL (−12%)
- **Debias wins wind**: DK1 (−21%)
- **TSO fc already best**: NL, ES, PT, DE_LU, FR, BE, CZ, CH (all targets tested)

The pattern: peripheral/less-mature TSOs (GR, RO, islands, PL) leave solar
signal on the table; the mature continental core and Iberia do not. The
collapse-question input risk is therefore concentrated where the floor is
NOT active today (except PL) — the floor group's inputs are sound, and the
remaining collapse residual is the quantity/commitment deficit the
market-implied experiment measured (+2.5 GW for GR).
