# fuel_costs.jl — Fuel-cost model: TTF gas and EUA carbon lookups (cached per day), SRMC base table, get_marginal_cost.
# Included by ../Generators.jl inside `module Euphemia` (definition order preserved).



# TTF gas price lookup (yfinance.ttf_f, populated by the ceres yfinance ETL).
# Cached per day because get_generators() calls get_marginal_cost once per generator.
const TTF_PRICE_CACHE = Dict{Dates.Date,Union{Float64,Nothing}}()

# Gas plant cost model constants
const GAS_PLANT_EFFICIENCY = 0.55   # CCGT-dominated fleet efficiency (LHV basis)
const GAS_EMISSION_FACTOR = 0.202   # tCO₂ per MWh of gas burned
const GAS_VOM_COST = 2.0            # €/MWh variable O&M

# EUA carbon price (€/tCO₂): approximate yearly averages of the EU ETS
# December-contract price. Fallback for dates before the daily feed's
# history starts (Nov 2021) and for transient DB failures — carbon is the
# dominant cost component for lignite/coal, and the yearly swing (2023 ≈ 84
# vs 2024 ≈ 65) moves their SRMC by ±15 €/MWh.
const EUA_PRICE_BY_YEAR = Dict(
    2019 => 25.0, 2020 => 25.0, 2021 => 54.0, 2022 => 81.0,
    2023 => 84.0, 2024 => 65.0, 2025 => 72.0, 2026 => 80.0
)
const EUA_PRICE_DEFAULT = 70.0

# Daily EUA carbon price lookup (yfinance.eua_co2, populated by the ceres
# yfinance ETL from the SparkChange Physical Carbon ETC "CO2.L", EUR closes).
# The ETC physically holds EU Allowances, so its close tracks EUA spot ~1:1.
# Cached per day because get_generators() calls get_marginal_cost once per
# generator.
const EUA_PRICE_CACHE = Dict{Dates.Date,Union{Float64,Nothing}}()

"""
    get_daily_eua_price(day::Dates.Date) -> Union{Float64,Nothing}

Most recent EUA close (€/tCO₂) strictly before `day`, from
`yfinance.eua_co2`. Looks back up to 10 days to bridge weekends and
holidays. Returns `nothing` when no data exists near `day` (e.g., before the
feed's history starts in Nov 2021), in which case `eua_price` falls back to
the yearly lookup.

Like `get_ttf_price`, uses strictly `date < day`: the day-ahead auction for
D clears around noon on D−1, when D's own close does not exist yet.
"""
function get_daily_eua_price(day::Dates.Date)
    haskey(EUA_PRICE_CACHE, day) && return EUA_PRICE_CACHE[day]

    df = try
        Euphemia.sql2df_with_retry(
            """
            SELECT close
            FROM yfinance.eua_co2
            WHERE date < \$1 AND date > \$1::date - INTERVAL '10 days'
              AND close IS NOT NULL
            ORDER BY date DESC
            LIMIT 1
            """,
            [day]
        )
    catch e
        # Transient DB failure: warn and fall back WITHOUT caching, so the
        # next call retries instead of pinning this date to the fallback
        @warn "EUA price lookup failed for $day, falling back to yearly average: $e"
        return nothing
    end

    price = (isempty(df) || ismissing(df.close[1])) ? nothing : Float64(df.close[1])
    if price === nothing
        @warn "No EUA price within 10 days before $day; using yearly average"
    end

    # Cache both hits and genuine data absence (but never transient errors)
    EUA_PRICE_CACHE[day] = price
    return price
end

function eua_price(day::Dates.Date)
    daily = get_daily_eua_price(day)
    return daily === nothing ? get(EUA_PRICE_BY_YEAR, year(day), EUA_PRICE_DEFAULT) : daily
end

"""
    get_ttf_price(day::Dates.Date) -> Union{Float64,Nothing}

Most recent TTF front-month futures close (€/MWh) strictly before `day`, from
`yfinance.ttf_f`. Looks back up to 10 days to bridge weekends and holidays.
Returns `nothing` when no data exists near `day` (e.g., before the table's
history starts), in which case callers should fall back to stylized costs.

For a market date D this returns the close of the last trading day before D,
which is the price information available at day-ahead auction time.
"""
function get_ttf_price(day::Dates.Date)
    haskey(TTF_PRICE_CACHE, day) && return TTF_PRICE_CACHE[day]

    # Strictly before the delivery day: the day-ahead auction for D clears
    # around noon on D-1, when D's own close does not exist yet. Using
    # `date <= day` would leak future information into backtests.
    df = try
        Euphemia.sql2df_with_retry(
            """
            SELECT close
            FROM yfinance.ttf_f
            WHERE date < \$1 AND date > \$1::date - INTERVAL '10 days'
              AND close IS NOT NULL
            ORDER BY date DESC
            LIMIT 1
            """,
            [day]
        )
    catch e
        # Transient DB failure: warn and fall back WITHOUT caching, so the
        # next call retries instead of pinning this date to the fallback
        @warn "TTF price lookup failed for $day, falling back to stylized gas cost: $e"
        return nothing
    end

    # NULL closes arrive as `missing` — treat like absent data
    price = (isempty(df) || ismissing(df.close[1])) ? nothing : Float64(df.close[1])
    if price === nothing
        @warn "No TTF price within 10 days before $day; using stylized gas cost"
    end

    # Cache both hits and genuine data absence (but never transient errors)
    TTF_PRICE_CACHE[day] = price
    return price
end

function get_marginal_cost(day::Dates.Date, fuel_type::String, bidding_zone::String="GR")
    # Gas-fired units: use real TTF fuel prices when available.
    # marginal cost = fuel cost / efficiency + carbon cost + variable O&M
    # No bid markup here — the bidding layer applies its own markup_factor.
    if fuel_type == "Fossil Gas"
        ttf = get_ttf_price(day)
        if ttf !== nothing
            fuel_cost = ttf / GAS_PLANT_EFFICIENCY
            carbon_cost = GAS_EMISSION_FACTOR / GAS_PLANT_EFFICIENCY * eua_price(day)
            return fuel_cost + carbon_cost + GAS_VOM_COST
        end
    end

    base = get(FUEL_SRMC_BASE, fuel_type, 105.0 - 0.367 * EUA_PRICE_DEFAULT)
    ef = get(FUEL_EMISSION_FACTOR_EL, fuel_type, fuel_type in ("Fossil Gas", "Other") ? 0.367 : 0.0)
    return base + ef * eua_price(day)
end

# Non-carbon SRMC component (fuel/efficiency + VOM, €/MWh electric) and
# electrical emission factors (tCO₂/MWh_el). Full SRMC = base + EF × EUA(t).
# No bid markup — bidding strategy is applied in the order book layer, not
# here (the UC objective also uses these costs and should see true costs).
#
# e.g. Lignite (GR): fuel+VOM ≈ €25, EF ≈ 1.25 → 25 + 1.25×70 ≈ 112 at EUA 70
#      Hard coal: ~€14/MWh_th at η=0.40 → 37 + 0.90×70 ≈ 100
#      Oil (HFO): ~€40/MWh_th at η=0.38 → 103 + 0.75×70 ≈ 155
const FUEL_SRMC_BASE = Dict(
    "Hydro Water Reservoir" => 12.0,           # O&M only; water value applied in bidding layer
    "Hydro Run-of-river and pondage" => 3.0,  # Must-run, near-zero variable cost
    "Hydro Pumped Storage" => 60.0,            # Pumping energy cost at off-peak prices
    "Fossil Brown coal/Lignite" => 25.0,       # Mined fuel + VOM; carbon dominates via EF
    "Fossil Gas" => 105.0 - 0.367 * 70.0,      # Fallback only — TTF path is preferred
    "Nuclear" => 10.0,                         # Fuel cycle cost
    "Fossil Oil" => 103.0,                     # HFO/diesel fuel + VOM
    "Fossil Hard coal" => 37.0,                # API2-level coal + VOM
    "Fossil Coal-derived gas" => 47.0,
    "Wind Onshore" => 1.0,
    "Wind Offshore" => 2.0,
    "Solar" => 1.0,
    "Biomass" => 60.0,                         # Fuel cost, no carbon
    "Waste" => 25.0,                           # Gate fees offset fuel cost
    "Geothermal" => 20.0,
    "Energy storage" => 90.0,                  # Charging-cost opportunity proxy
    "Other" => 110.0 - 0.367 * 70.0            # Assume gas-like when unknown
)

const FUEL_EMISSION_FACTOR_EL = Dict(
    "Fossil Brown coal/Lignite" => 1.25,
    "Fossil Hard coal" => 0.90,
    "Fossil Oil" => 0.75,
    "Fossil Coal-derived gas" => 0.90,
    "Fossil Gas" => 0.367,   # 0.202 tCO₂/MWh_th at η=0.55 (fallback path)
    "Other" => 0.367
)

