# emit_input_corrections.jl — the cv32 daily emitter (follow-up declared in
# PR #318). Included by bin/daily_forecast.jl AFTER bin/ml_inputs.jl (reuses
# its weather fetch + feature construction + LightGBM text evaluator).
#
# For each delivery day it is given, scores the ACTUALS-TARGET solar models
# (bin/input_models_actuals/ — the R1 winners GR/RO/IT-Sicily/IT-Sardinia)
# on previous_day1 weather and inserts the resulting MW series into
# simulations.input_corrections; DK1 wind rows come from the trailing-debias
# rule in SQL (fc × trailing-30d median act/fc, 2-day lag, clip [0.5, 2]).
# Record parity: values reproduce the historical table's emission recipe
# (clip(ratio,0,1.3) × cap95, night clamp se<=0 — predict_winners.py), not
# ml_predict_solar's unclipped serve path.
# Vintage discipline: ON CONFLICT DO NOTHING — the FIRST (earliest, D-1
# morning) emission for a delivery hour wins; later runs never overwrite.
# Which zones are CONSUMED stays a src/profile decision (cv32: Sicily +
# Sardinia); emission covers all winners so future packages have history.
# Non-fatal by contract: callers wrap in try/catch — a failed emission must
# never block the forecast cycle.

const ACTUALS_MODELS_DIR = joinpath(@__DIR__, "input_models_actuals")

const _CORRECTION_SOLAR_ZONES = ["GR", "RO", "IT-Sicily", "IT-Sardinia"]

"""
    emit_input_corrections!(day; dry_run=false) -> n_rows or rows

Score the correction models for delivery `day` and insert into
simulations.input_corrections (Postgres). `dry_run=true` computes and returns
the rows (`Vector{Tuple{zone,target,hour,mw,tag}}`) without touching the DB —
used by the parity smoke test against the historical table.
"""
function emit_input_corrections!(day::Date; dry_run::Bool=false)
    meta_path = joinpath(ACTUALS_MODELS_DIR, "meta.json")
    isfile(meta_path) || (println("  cv32 emit: no actuals models dir — skip"); return dry_run ? [] : 0)
    ameta = JSON.parsefile(meta_path)
    out = Tuple{String,String,DateTime,Float64,String}[]
    # ── solar zones via actuals-target models ──────────────────────────────
    geom = ml_geom()
    for z in _CORRECTION_SOLAR_ZONES
        haskey(ameta, "$(z)_solar") || continue
        isfile(joinpath(ACTUALS_MODELS_DIR, "$(z)_solar.txt")) || continue
        model = parse_lgb_model(joinpath(ACTUALS_MODELS_DIR, "$(z)_solar.txt"))
        cells = [(Float64(c[1]), Float64(c[2])) for c in geom[z]["cells"]]
        lat0, lon0 = ml_zone_centroid(geom, z)
        rweather = fetch_ml_res_weather(cells, [day]; vintage_lag=1)
        ragg = ml_res_agg(cells, rweather)
        cap = ml_capacity_p95([z], [day])
        c95 = get(get(cap, (z, :solar), Dict{Date,Float64}()), day, NaN)
        isnan(c95) && (println("  cv32 emit: $z cap95 missing — skip"); continue)
        n_before = length(out)
        for h in DateTime(day):Hour(1):DateTime(day) + Hour(23)
            ra = get(ragg, h, nothing)
            ra === nothing && continue
            ghi, cloud, pres, v100m = ra
            feats = ml_res_features(h, lat0, lon0, ghi, cloud, pres, v100m, c95, NaN)
            x = ml_feature_vector(model, feats)
            p = lgb_predict(model, x)
            isnan(p) && continue
            # record parity: the historical table was emitted with
            # clip(ratio,0,1.3)×cap95 and night clamp se<=0 (predict_winners.py)
            mw = clamp(p, 0.0, 1.3) * c95
            feats["se"] <= 0.0 && (mw = 0.0)
            push!(out, (z, "solar", h, round(max(mw, 0.0), digits=1), "$(z)_solar@actuals-v1"))
        end
        length(out) == n_before && println("  cv32 emit: $z produced no rows (weather gap?)")
    end
    # ── DK1 wind via the trailing-debias rule (pure SQL) ───────────────────
    # Record recipe (transcribed from the winner-corrections emission): hourly
    # fc basis = per-type hourly AVG summed across Wind types; daily ratio =
    # Σact/Σfc over hours where BOTH exist; r(D) = median of the daily ratios
    # over D-31..D-2 (rolling(30).shift(2)), needs ≥15 valid days, clipped
    # [0.5, 2.0]; corrected = hourly fc × r(D). Actuals basis identical
    # (per-type hourly AVG then SUM — never SUM raw PT15M rows).
    df = Euphemia.sql2df_with_retry("""
        WITH fc_t AS (
            SELECT production_type AS pt, date_trunc('hour', date_time_utc) AS h,
                   AVG(day_ahead_generation_forecast_mw) AS mw
            FROM entsoe.generation_forecasts_for_wind_and_solar
            WHERE area_map_code = 'DK1' AND area_type_code LIKE 'BZN%'
              AND production_type LIKE 'Wind%'
              AND day_ahead_generation_forecast_mw IS NOT NULL
              AND date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
              AND date_time_utc < ((\$1::date + 1)::timestamp AT TIME ZONE 'UTC')
            GROUP BY 1, 2),
        fch AS (SELECT h, SUM(mw) AS fmw FROM fc_t GROUP BY 1),
        hfc_t AS (
            SELECT production_type AS pt, date_trunc('hour', date_time_utc) AS h,
                   AVG(day_ahead_generation_forecast_mw) AS mw
            FROM entsoe.generation_forecasts_for_wind_and_solar
            WHERE area_map_code = 'DK1' AND area_type_code LIKE 'BZN%'
              AND production_type LIKE 'Wind%'
              AND day_ahead_generation_forecast_mw IS NOT NULL
              AND date_time_utc >= ((\$1::date - 31)::timestamp AT TIME ZONE 'UTC')
              AND date_time_utc < ((\$1::date - 1)::timestamp AT TIME ZONE 'UTC')
            GROUP BY 1, 2),
        hfc AS (SELECT h, SUM(mw) AS fmw FROM hfc_t GROUP BY 1),
        hact_t AS (
            SELECT production_type AS pt, date_trunc('hour', date_time_utc) AS h,
                   AVG(actual_generation_output_mw) AS mw
            FROM entsoe.aggregated_generation_per_type
            WHERE area_map_code = 'DK1' AND area_type_code LIKE 'BZN%'
              AND production_type LIKE 'Wind%'
              AND actual_generation_output_mw IS NOT NULL
              AND date_time_utc >= ((\$1::date - 31)::timestamp AT TIME ZONE 'UTC')
              AND date_time_utc < ((\$1::date - 1)::timestamp AT TIME ZONE 'UTC')
            GROUP BY 1, 2),
        hact AS (SELECT h, SUM(mw) AS amw FROM hact_t GROUP BY 1),
        hd AS (
            SELECT CAST(hfc.h AS date) AS d, SUM(hfc.fmw) AS fmw, SUM(hact.amw) AS amw
            FROM hfc JOIN hact ON hact.h = hfc.h
            GROUP BY 1),
        r AS (
            SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY amw / fmw) AS med,
                   COUNT(*) AS n
            FROM hd WHERE fmw > 0)
        SELECT fch.h AS h,
               fch.fmw * GREATEST(LEAST((SELECT med FROM r), 2.0), 0.5) AS mw
        FROM fch
        WHERE (SELECT n FROM r) >= 15
        """, Any[day])
    for r in eachrow(df)
        ismissing(r.mw) && continue
        push!(out, ("DK1", "wind", DateTime(r.h), round(Float64(r.mw), digits=1),
                    "DK1_wind@fc-debias-v1"))
    end
    dry_run && return out
    isempty(out) || Euphemia.withdb() do cnx
        for (z, tgt, h, mw, tag) in out
            LibPQ.execute(cnx, """
                INSERT INTO simulations.input_corrections
                    (bidding_zone, target, date_time_utc, corrected_mw, model_tag)
                VALUES (\$1, \$2, \$3, \$4, \$5)
                ON CONFLICT DO NOTHING
            """, Any[z, tgt, h, mw, tag])
        end
    end
    println("  🛠️  cv32 emit: $(length(out)) correction row(s) for $day")
    return length(out)
end
