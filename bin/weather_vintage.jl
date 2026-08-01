# D-1 vintage discipline for open-meteo forecast fetches — single definition,
# included by weather_res.jl AND weather_load.jl (idempotent: a plain function
# redefinition, no consts), so the two fetch layers cannot drift.

using Dates

"""
    openmeteo_vintage_lag(market_day::Date; asof::Date=Date(now(UTC))) -> Int

D-1-vintage discipline: for market day D the admissible weather input is the
forecast ISSUED on D-1 (or earlier, at longer leads). Returns `0` when running
on or before D-1 — the live forecast API's *current* run is then itself an
admissible vintage — and `1` when running on or after D: the previous-runs
API's `_previous_day1` variables are **per-timestamp** (for hour h of day D
they carry the value predicted by the run issued on D-1 — the semantics
measured and documented in `test/scripts/dn_load_fetch.py` and
`docs/experiments/dn-load-model/README.md`, NOT "the run N days before now"),
so a constant lag of 1 pins the D-1-issued vintage for ANY past day the API's
history covers (dense from ~2024-07 for gfs_seamless). Days beyond that
coverage degrade per-day (null hours → the zone-day goes ineligible loudly),
never by killing the run.

Deliberate looseness, documented: admissibility is Date-granular ("issued on
D-1"), not gate-granular — a lag-0 fetch late on D-1 may use a run initialized
after the 12:00 CET auction gate. The discipline excludes delivery-day
lookahead; it does not reconstruct the bidders' exact pre-gate information set.
"""
openmeteo_vintage_lag(market_day::Date; asof::Date=Date(now(UTC))) =
    asof <= market_day - Day(1) ? 0 : 1

"""
    openmeteo_retro_vintage_lag(lead_days::Int) -> Int

RETRO reconstruction discipline (docs/experiments/pregate-7lead.md): to
reconstruct "what the forecast would have said at lead `n` for a PAST delivery
day D", every weather feature must come from the run issued `n` days before D —
the open-meteo previous-runs API's `_previous_day{n}` variable (per-timestamp:
for hour h it carries the value predicted by the run issued issue-date(h) − n).
So the admissible vintage lag for a lead-`n` retro slice is simply `n`, clamped
to the API's 1..7 previous-runs coverage.

Unlike the LIVE lag (`openmeteo_vintage_lag`, 0/1 — a FUTURE day's current run
is already horizon-natural, and lag 0 IS the run issued D−lead), the retro lag
EQUALS the lead: for a past D the D−n-issued run is recovered only through
`_previous_day{n}`. Models were trained on `previous_day1`; serving day-n
vintages of the SAME variables is the declared convention whose skill cost the
per-lead scoreboard measures — that IS the validation.
"""
openmeteo_retro_vintage_lag(lead_days::Int) = clamp(lead_days, 1, 7)
