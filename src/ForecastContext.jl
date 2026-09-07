# ForecastContext.jl — the as-of input contract (issue #368, phase 1).
#
# A `ForecastContext` says WHEN a book is being built: the delivery day, the
# issuance instant (`as_of_utc`) before which every input must have been
# published, and the lead. It is installed with `with_context(f, ctx)` as a
# dynamic scope (Base.ScopedValues, inherited by spawned tasks) so the readers
# do not need new positional arguments; `current_context()` returns `nothing`
# outside any scope, and every reader keeps its legacy SQL and cache key in
# that case — the cv37 record stays bit-identical.
#
# Inside a context the readers that CAN honour a publication cutoff do so
# (generation and transmission outages, the fuel closes, the trailing
# actual-generation windows) and every reader records what it could verify
# in the audit (`asof_audit()`), per source, using the statuses of
# docs/experiments/asof-contract/README.md §4:
#
#   :verified        stamp present, real, and <= as_of
#   :post_gate       stamp present and real, but AFTER as_of (the stored
#                    revision post-dates issuance; the pre-gate value is not
#                    in the store)
#   :unverifiable    no meaningful stamp for this field
#   :legacy_stamp    the stamp is an ETL/backfill time, not a publication time
#   :latency_policy  no stamp; the window was truncated by a documented
#                    source latency instead
#
# Nothing here changes a value the legacy path returns; the context changes
# (a) which outage versions count, (b) which fuel close is read for leads > 1,
# (c) where the trailing actual-generation windows end, and (d) the cache keys
# of the readers it touches, so a later issuance built in the same process can
# never be served to an earlier one.

using Base.ScopedValues: ScopedValue, with

# ---------------------------------------------------------------------------
# EU DST rule (Directive 2000/84/EC): summer time from the last Sunday of March
# 01:00 UTC to the last Sunday of October 01:00 UTC. TimeZones.jl is
# deliberately not a project dependency (see bin/forecast_common.jl, which
# carries the same pure rule for the Athens market day).
# ---------------------------------------------------------------------------
function _last_sunday(year::Int, month::Int)
    d = Dates.Date(year, month, Dates.daysinmonth(Dates.Date(year, month)))
    return d - Dates.Day(Dates.dayofweek(d) % 7)
end

_eu_dst_window(year::Int) = (
    Dates.DateTime(_last_sunday(year, 3)) + Dates.Hour(1),
    Dates.DateTime(_last_sunday(year, 10)) + Dates.Hour(1),
)

"Whether EU summer time is in force at UTC instant `t`."
function is_eu_summer_time_utc(t::Dates.DateTime)
    s, e = _eu_dst_window(Dates.year(t))
    return s <= t < e
end

"""
    auction_gate_utc(delivery::Date; rule=:fixed_10utc) -> DateTime

UTC instant of the SDAC day-ahead gate closure for delivery day `delivery`
(12:00 CET/CEST on D-1).

- `:fixed_10utc` — D-1 10:00 UTC always. This is the convention the cv34
  outage gate and the D-2 fuel close were built on: exact in summer, one hour
  conservative in winter. Default, so a context reproduces the record.
- `:auction_local` — 12:00 Europe/Brussels: D-1 10:00 UTC under CEST,
  D-1 11:00 UTC under CET. The DST regime is the one in force at the gate
  instant itself (the clocks change at 01:00 UTC on the transition Sunday, so
  a D-1 that IS the transition Sunday is already in the new regime by noon).
"""
function auction_gate_utc(delivery::Dates.Date; rule::Symbol = :fixed_10utc)
    d1 = Dates.DateTime(delivery - Dates.Day(1))
    rule === :fixed_10utc && return d1 + Dates.Hour(10)
    rule === :auction_local || throw(
        ArgumentError("unknown gate rule $rule (expected :fixed_10utc or :auction_local)"),
    )
    summer = is_eu_summer_time_utc(d1 + Dates.Hour(10))
    return d1 + Dates.Hour(summer ? 10 : 11)
end

# ---------------------------------------------------------------------------
# The context
# ---------------------------------------------------------------------------
struct ForecastContext
    delivery::Dates.Date        # delivery day (UTC day of the book)
    as_of_utc::Dates.DateTime   # issuance: every input must be published <= this
    lead::Int                   # 1 = the D-1 auction; 2..7 = the forecast ladder
    gate_rule::Symbol           # :fixed_10utc | :auction_local (how as_of was derived)
    label::String               # free text carried into logs/manifests
end

"""
    gate_context(delivery; rule=:fixed_10utc, label="") -> ForecastContext

Lead-1 context: issuance = the auction gate of `delivery`.
"""
gate_context(delivery::Dates.Date; rule::Symbol = :fixed_10utc, label::String = "") =
    ForecastContext(delivery, auction_gate_utc(delivery; rule = rule), 1, rule, label)

"""
    issuance_context(delivery, lead; issue_time=Time(6,30), label="") -> ForecastContext

Lead-`lead` context: issuance = `delivery - lead` at `issue_time` UTC (the
06:30 UTC daily run; `bin/daily_forecast.jl` stamps `retro_of_utc` the same
way). `lead == 1` delegates to `gate_context` so the D-1 auction keeps the
gate as its cutoff, not the morning run.
"""
function issuance_context(
    delivery::Dates.Date,
    lead::Int;
    issue_time::Dates.Time = Dates.Time(6, 30),
    rule::Symbol = :fixed_10utc,
    label::String = "",
)
    lead >= 1 || throw(ArgumentError("lead must be >= 1, got $lead"))
    lead == 1 && return gate_context(delivery; rule = rule, label = label)
    as_of =
        Dates.DateTime(delivery - Dates.Day(lead)) +
        Dates.Hour(Dates.hour(issue_time)) +
        Dates.Minute(Dates.minute(issue_time))
    return ForecastContext(delivery, as_of, lead, rule, label)
end

const CURRENT_CONTEXT = ScopedValue{Union{Nothing,ForecastContext}}(nothing)

"The active `ForecastContext`, or `nothing` on the legacy path."
current_context() = CURRENT_CONTEXT[]

"""
    with_context(f, ctx::ForecastContext)

Run `f()` with `ctx` as the active context. Scoped: nested calls see the
innermost context, tasks spawned inside inherit it, and it is gone when `f`
returns — a later issuance built afterwards in the same process cannot see it.
"""
with_context(f, ctx::ForecastContext) = with(f, CURRENT_CONTEXT => ctx)

"""
    ctx_key() -> Union{Nothing,DateTime}

What the readers add to their cache keys: the issuance instant, or `nothing`
on the legacy path. Two contexts with the same `as_of_utc` are the same input
vintage by definition, so they may share cache entries.
"""
ctx_key() = (c = current_context(); c === nothing ? nothing : c.as_of_utc)

# ---------------------------------------------------------------------------
# Source stamp calendar: from which DELIVERY date a source's publication stamp
# is a real publication time rather than an ETL/backfill time. Measured in
# docs/experiments/asof-contract (scripts 02/05). A delivery before the date
# classifies as :legacy_stamp; a source with no date classifies as
# :unverifiable whatever the stamp says.
# ---------------------------------------------------------------------------
const SOURCE_STAMP_REAL_FROM = Dict{String,Dates.Date}(
    "load_forecast_d1" => Dates.Date(2025, 11, 1),   # entsoe.day_ahead_total_load_forecast.update_time_utc
    "outages_generation" => Dates.Date(2025, 10, 1),   # version_publication_timestamp_utc (cv34 seam)
    "outages_transmission" => Dates.Date(2025, 10, 1),
    "atc_offered_implicit" => Dates.Date(2026, 1, 1),
    "aggregated_generation" => Dates.Date(2026, 1, 1),
    "jao_maxbex" => Dates.Date(2026, 8, 23),   # last_modified_utc populated
    # "res_forecast_d1": no entry — the row's update_time_utc tracks the
    # intraday/current columns, so the D-1 column's publication is unknowable.
    # "hydro_fill": no entry in phase 1 — weekly stamps not yet audited by year.
)

# Publication latency applied where no stamp is used: aggregated generation
# per type is published ~45 min after the hour (median, 2026), so at issuance
# the last complete hour available is as_of - 1 h.
const AGG_GEN_PUBLICATION_LATENCY = Dates.Hour(1)

"""
    stamp_status(source, stamp, ctx) -> Symbol

Classify one stored revision for `source` given its publication stamp (a
`DateTime` in UTC, or `missing`/`nothing`) under context `ctx`.
"""
function stamp_status(source::AbstractString, stamp, ctx::ForecastContext)
    real_from = get(SOURCE_STAMP_REAL_FROM, String(source), nothing)
    real_from === nothing && return :unverifiable
    ctx.delivery < real_from && return :legacy_stamp
    (stamp === missing || stamp === nothing) && return :unverifiable
    return Dates.DateTime(stamp) <= ctx.as_of_utc ? :verified : :post_gate
end

# ---------------------------------------------------------------------------
# Audit accumulator: source -> status -> count. Process-wide, reset by the
# caller per run (`reset_asof_audit!`). Recorded only inside a context.
# ---------------------------------------------------------------------------
const _ASOF_AUDIT = Dict{String,Dict{Symbol,Int}}()
const _ASOF_AUDIT_LOCK = ReentrantLock()

function record_asof_status!(source::AbstractString, status::Symbol, n::Int = 1)
    current_context() === nothing && return nothing
    lock(_ASOF_AUDIT_LOCK) do
        d = get!(_ASOF_AUDIT, String(source), Dict{Symbol,Int}())
        d[status] = get(d, status, 0) + n
    end
    return nothing
end

"Snapshot of the audit counts: source => (status => rows)."
function asof_audit()
    lock(_ASOF_AUDIT_LOCK) do
        return Dict(k => copy(v) for (k, v) in _ASOF_AUDIT)
    end
end

function reset_asof_audit!()
    lock(_ASOF_AUDIT_LOCK) do
        empty!(_ASOF_AUDIT)
    end
    return nothing
end

"""
    asof_audit_table() -> DataFrame

The audit as a flat table (source, status, rows) — what a run manifest carries.
"""
function asof_audit_table()
    rows = NamedTuple{(:source, :status, :rows),Tuple{String,Symbol,Int}}[]
    for (src, d) in sort(collect(asof_audit()); by = first),
        (st, n) in sort(collect(d); by = x -> string(first(x)))

        push!(rows, (source = src, status = st, rows = n))
    end
    return DataFrames.DataFrame(rows)
end

"""
    classify_stamps!(source, stamps) -> Dict{Symbol,Int}

Classify a column of publication stamps under the active context and record
the counts. No-op (empty Dict) on the legacy path.
"""
function classify_stamps!(source::AbstractString, stamps)
    ctx = current_context()
    ctx === nothing && return Dict{Symbol,Int}()
    counts = Dict{Symbol,Int}()
    for s in stamps
        st = stamp_status(source, s, ctx)
        counts[st] = get(counts, st, 0) + 1
    end
    for (st, n) in counts
        record_asof_status!(source, st, n)
    end
    return counts
end
