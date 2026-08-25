# cv34 — the ex-ante conventions (owner decisions 2026-08-25)

After the two bug sweeps (#342, #343) five items were left that were not bugs
but conventions only the owner could set. Decided 2026-08-25 ("go with the
suggested fixes, then run a full evaluation, bump CV"). This is the record of
what each one now means in code, the one-off migrations that were run, and the
evaluation. cv34 was the number the continental-collapse prereg draft had
designated; that package moves to cv35.

## B1. Outage versions as known at the gate

ENTSO-E outage messages are versioned; until cv33 the LATEST version counted,
including versions published after the D-1 12:00 CET auction (a same-day forced
trip published at 15:00 reached that day's book: 2026-04-03 DE_LU 1.9 GW, GR
837 MW, RS 349 MW of future knowledge). Now: for delivery days **from
2025-10-01** the version that counts is the latest one **published before D-1
10:00 UTC** (the 12:00 CET/CEST gate, conservative). The seam is where
`version_publication_timestamp_utc` becomes a real TSO time (the ETL captured
it from 2025-09-28; before that the column holds ingestion time, so no vintage
filter is possible). Both directions move: a same-day forced outage no longer
disappears from the fleet, and an outage **cancelled after the gate** now
correctly still counts. 2026-04-03 fleets vs cv33: FR +225 MW, DE_LU −1,022 MW,
GR +105 MW, RS unchanged. Before the seam the record is D-0 knowledge for
outages and says so here.

## B2. Fuel and carbon closes strictly before D-1

The D-1 close (17:30) does not exist at the 12:00 gate; the last close that
does is D-2's. `get_ttf_price`, `eua_price` and the UKA lookup read
`date < D − 1 day`. 2026-04-03: TTF 47.51 (the 04-01 close) instead of 50.04
(04-02); gas SRMC 114.2 instead of ~118. Mean |Δ| between consecutive closes
over 2023+ is 1.3 €/MWh gas ≈ 2.3 €/MWh_el on the gas SRMC (p90 4.9, crisis
days up to 23).

## B3. The `entsoe` track's persistence leads are labelled

`bin/horizon_forecast.jl` fills leads 2–7 of the "As announced" track with the
T-7 lead-1 slice (weekly persistence). They were stamped `input_mode='entsoe'`
and the running cv — indistinguishable from a model clear. Now
`input_mode='entsoe_persist'`; the site's track switch matches the `entsoe*`
prefix so they still render on the As-announced track, labelled. One-off
relabel run 2026-08-25 on live: 247,008 `forecast_prices` rows and 9,341
`forecast_scores` rows moved from `entsoe` to `entsoe_persist` at leads ≥ 2.

## B4. The lead ladder measures weather decay only — declared, and unpooled

`docs/experiments/pregate-7lead.md` §2b states it: only the weather is
vintage-honest at lead n; flows, analogue pool, fuel, outages, capability
windows and the AR load features are delivery-day anchored (retro) or absent
(live). Live and retro rows are no longer pooled: `forecast_scores` PK now
includes `is_retro` (migrated live, 0.5 s), `upsert_score!` conflicts on it,
the discovery's NOT-EXISTS matches on it, and the summary reports
`<mode>/retro` rows separately. Making the other inputs vintage-aware is a
separate project.

## B5. `energy_prices` unique key re-keyed

The live constraint had grown an `optimizer` column that no writer populates;
NULLs are distinct, so it rejected nothing. Pre-check found 0 duplicate groups
on the intended key; the migration (`ensure_energy_prices_table`, catalog-first,
skips loudly if duplicates exist) dropped it and added
`UNIQUE (date_time_utc, bidding_zone, contract_type, order_method,
clearing_mode, code_version)`. Ran live 2026-08-25 in 23.6 s.

## C. Import backstop sized against the MPCC's own border capacity

`get_import_backstop` re-derived the endogenous-border ATC from the offered-ATC
tables without the cv27 demonstrated capability, the border drops or the as-of
filter, so on cv27 borders in Day-ahead-free hours it read ~0 while the flow
variables delivered the p95 capability — the backstop and the flows supplied
the same MW (CH~FR, IT-CNORTH~IT-NORTH, DK1~SE3). The coupled path now hands
the enriched network's per-hour import capacity over the zone's endogenous
borders into the backstop. `EUPHEMIA_DISABLE_BACKSTOP_ATC_SYNC` restores the
re-query — the leave-one-out arm of the evaluation. The scarcity credit's
`get_import_atc_capacity` is left as is: its scope (all borders, including
out-of-footprint) differs, so a direct substitution would not be the same
quantity.

## Evaluation

See §Evaluation below (filled in after the run).
