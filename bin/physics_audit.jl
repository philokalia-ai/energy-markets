# Physics-consistency audit of the ingested ENTSO-E data — CLI runner.
#
# Runs Euphemia.run_physics_audit against the configured data store (live
# Postgres or a DuckDB extract — the normal auto-detection applies) and writes
# a JSON report + an optional CSV of the raw findings. STRICTLY READ-ONLY:
# only SELECTs are issued, nothing is ever written to the store.
#
# Usage (full history of the public extract):
#   EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_PATH=data/extracts/euphemia-public.duckdb \
#     START_DATE=2023-01-01 END_DATE=2026-07-01 \
#     OUT_JSON=physics-audit.json julia --project=. bin/physics_audit.jl
#
# Daily-CI shape (trailing window on the just-refreshed living extract, see
# .github/workflows/refresh-extract.yml):
#   AUDIT_BACK_DAYS=14 OUT_JSON=physics-audit.json julia --project=. bin/physics_audit.jl
#
# Env:
#   START_DATE / END_DATE  audit window [start, end), delivery timestamps UTC.
#                          Default: today-AUDIT_BACK_DAYS .. today+2 (the
#                          refresh carries D+1 delivery data).
#   AUDIT_BACK_DAYS        default window depth when START_DATE unset (14)
#   ZONES                  comma-separated zone filter (default: all)
#   CHECKS                 comma-separated check subset (default: all;
#                          names: solar_night, solar_day_missing, load_bounds,
#                          load_day_incomplete, resolution_mix, registry,
#                          unit_output, reservoir, flow_spike, price_caps)
#   OUT_JSON / OUT_CSV     report paths (default: physics-audit.json / none)
#   AUDIT_STRICT           "true" → exit 1 when any :error finding exists
#                          (default false: report-only, CI-non-fatal)

using Euphemia
using DataFrames
using Dates
using Printf

function main()
    back = parse(Int, get(ENV, "AUDIT_BACK_DAYS", "14"))
    d0 = Date(get(ENV, "START_DATE", string(Dates.today() - Day(back))))
    d1 = Date(get(ENV, "END_DATE", string(Dates.today() + Day(2))))
    zones_env = get(ENV, "ZONES", "")
    zones = isempty(zones_env) ? nothing : String.(strip.(split(zones_env, ",")))
    checks_env = get(ENV, "CHECKS", "")
    checks =
        isempty(checks_env) ? Euphemia.AUDIT_CHECKS :
        Symbol.(strip.(split(checks_env, ",")))
    out_json = get(ENV, "OUT_JSON", "physics-audit.json")
    out_csv = get(ENV, "OUT_CSV", "")
    strict = lowercase(get(ENV, "AUDIT_STRICT", "false")) == "true"

    println("Physics-consistency audit")
    println("  window : $d0 .. $d1")
    println("  zones  : ", zones === nothing ? "all" : join(zones, ","))
    println("  checks : ", join(string.(checks), ","))
    t0 = time()
    findings = run_physics_audit(d0, d1; zones = zones, checks = checks)
    @printf("  done in %.0f s — %d finding(s)\n\n", time() - t0, nrow(findings))

    s = audit_summary(findings)
    if isempty(s)
        println("  ✅ no findings — every selected invariant holds on this window")
    else
        for r in eachrow(sort(s, [:severity, :check]))
            @printf(
                "  %-7s %-28s %5d finding(s), %3d zone(s), total n=%d\n",
                r.severity,
                r.check,
                r.findings,
                r.zones,
                r.total_n
            )
        end
    end

    write_audit_json(
        findings,
        out_json;
        window_start = d0,
        window_end = d1,
        store = string(Euphemia.DATA_STORE[]),
        generated_at_utc = now(UTC),
    )
    println("\nWrote ", out_json)
    if !isempty(out_csv)
        open(out_csv, "w") do io
            println(io, join(string.(Euphemia.AUDIT_FINDING_COLS), ","))
            for r in eachrow(findings)
                vals = [
                    r.check,
                    r.severity,
                    r.zone,
                    r.period,
                    r.n,
                    r.value,
                    r.bound,
                    "\"" * replace(r.detail, "\"" => "\"\"") * "\"",
                ]
                println(io, join(string.(vals), ","))
            end
        end
        println("Wrote ", out_csv)
    end

    n_err = isempty(findings) ? 0 : nrow(findings[findings.severity .== "error", :])
    if strict && n_err > 0
        println("\nAUDIT_STRICT: $n_err :error finding(s) — exiting 1")
        return 1
    end
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
