# energy-markets
![DayAheadMarketBiddingZoneDAG_eng](https://github.com/user-attachments/assets/36fa28b2-04b2-4a98-b633-9d9cef683b22)

## Scenario building

The merit-order pricing path supports counterfactual "what if" scenarios: start
from a real market day, perturb demand, supply, or bidding behaviour, and clear
the market again to see the price impact. Four optional hooks on
`generate_energy_prices` / `create_merit_order_book` (all default `nothing`;
with no hooks the result is identical to the plain backtest):

| Hook | Signature | Models |
|------|-----------|--------|
| `load_modifier` | `(timeslot, load_mw) -> load_mw'` | Demand shifts — electrification, a heat wave, industrial closures |
| `renewable_modifier` | `(timeslot, mw) -> mw'` | RES build-out or shortfall — e.g. +300 MW of solar |
| `extra_orders` | `ctx -> Vector{SimpleOrder}` | New participants — a new plant (supply), ships requesting shore power (cap-priced demand) |
| `strategist` | `ctx -> Vector{(SimpleOrder, owner_tag)}` | Bidding behaviour — e.g. an incumbent marking up its units; receives every order tagged with its owning unit plus a unit→firm map |

```julia
using Euphemia, Dates

# "What if GR had 300 MW more solar on 2026-01-26?"
solar = (ts, v) -> (8 <= parse(Int, ts[10:11]) <= 17) ? v + 300.0 : v
prices = generate_energy_prices("GR", Date(2026, 1, 26);
    order_method=:merit_order, save_to_db=false, renewable_modifier=solar)

# "What if the incumbent PPC marked up all its offers 20%?"
ppc = ctx -> [(o.type == :supply && get(ctx.firm_of, tag, "") == "PPC" ?
                  SimpleOrder(o.type, o.price * 1.2, o.quantity, o.zone, o.date_time, o.resolution_code) : o,
               tag) for (o, tag) in ctx.tagged_orders]
prices = generate_energy_prices("GR", Date(2026, 1, 26);
    order_method=:merit_order, save_to_db=false, strategist=ppc)
```

Scenarios can run fully offline against a self-contained DuckDB extract
(no Postgres needed) — build one with `bin/build_duckdb_extract.jl` and select
it with `configure_data_store!(backend=:duckdb, duckdb_path=...)` or
`EUPHEMIA_DATA_STORE=duckdb`. See the **"Data stores and scenario hooks"**
section in [CLAUDE.md](CLAUDE.md) for the full reference (hook semantics,
extract builder, v1 limitations: read-only DuckDB, single-zone only).

Data Sources:
- Installed Capacity: ENTSO-e [transparency platform](https://www.entsoe.eu/data/transparency-platform/)
- Installed Wind Farms, coords: ELETAEN
- Power Grid lines, nodes: ENTSO-e [map](https://www.entsoe.eu/data/map/), Open Street Maps
- Natural Gas TTFS: [yahoo finance](https://finance.yahoo.com/quote/TTF%3DF/history/) (TBD), EnEx
- Natural Gas Flows
- CO2 tarrifs
- Buildings / Industry / Population Approximations: Overture
- Load - Renewable Energy Sources Output: Weather
- Market Participants: [EnEx](https://www.enexgroup.gr/el/commodities-members-list) (For Greece)
