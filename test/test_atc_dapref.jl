# cv26 ATC Day-ahead preference (fix/atc-dayahead-only): the implicit
# offered-capacity table mixes Intraday rows (often 0 MW) into Day-ahead
# border-hours; per border-hour the build must prefer the Day-ahead average
# and fall back to the all-rows average only where no Day-ahead row exists.
# Extract-based (skips without it); the switch is read at call time and none
# of the consumers memoize (audited in the #233 review), so in-process
# polarity flips are valid here.
using Test, Dates

const _EXTRACT = joinpath(dirname(@__DIR__), "data", "extracts", "euphemia-live.duckdb")

if !isfile(_EXTRACT)
    @info "test_atc_dapref: extract not present — skipping" _EXTRACT
else
    using Euphemia, DataFrames

    @testset "ATC Day-ahead preference (cv26)" begin
        day = Date(2025, 8, 22)   # the EE phantom-cap day: DA 800/908 vs Intraday≈0

        # raw truth from the extract, computed independently of the code under test
        raw = Euphemia.sql2df_with_retry(
            """
            SELECT AVG(capacity_mw) FILTER (WHERE contract_type = 'Day-ahead') AS da,
                   AVG(capacity_mw) AS blend
            FROM entsoe.offered_transfer_capacities_implicit
            WHERE in_map_code = 'EE' AND out_map_code = 'LV'
              AND date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
              AND date_time_utc < ((\$1::date + 1)::timestamp AT TIME ZONE 'UTC')
              AND EXTRACT(HOUR FROM date_time_utc) = 9
            """, [day])
        da, blend = Float64(raw.da[1]), Float64(raw.blend[1])
        @test da > 2 * blend        # the contamination this fix exists for

        had = get(ENV, "EUPHEMIA_DISABLE_ATC_DAPREF", nothing)
        try
            # (a) preference ON (default): the network build carries the DA value
            delete!(ENV, "EUPHEMIA_DISABLE_ATC_DAPREF")
            df_on = Euphemia.Network._fetch_atc_aggregated(day,
                "offered_transfer_capacities_implicit", ["EE"])
            lv_on = only(df_on[(df_on.source_zone .== "LV") .& (df_on.sink_zone .== "EE") .&
                               (df_on.time_period .== 10), :capacity])
            @test lv_on ≈ 800.0 atol = 1e-6   # the h09 UTC Day-ahead row

            # (b) intraday-only border-hour: preference falls back to the blend
            # (SE2->NO3 has no Day-ahead rows in 2025 — FBMC border)
            df_no3 = Euphemia.Network._fetch_atc_aggregated(day,
                "offered_transfer_capacities_implicit", ["NO3"])
            se2 = df_no3[(df_no3.source_zone .== "SE2") .& (df_no3.sink_zone .== "NO3"), :]
            raw2 = Euphemia.sql2df_with_retry(
                """
                SELECT count(*) FILTER (WHERE contract_type = 'Day-ahead') AS nda,
                       AVG(capacity_mw) AS blend
                FROM entsoe.offered_transfer_capacities_implicit
                WHERE in_map_code = 'NO3' AND out_map_code = 'SE2'
                  AND date_time_utc >= (\$1::date::timestamp AT TIME ZONE 'UTC')
                  AND date_time_utc < ((\$1::date + 1)::timestamp AT TIME ZONE 'UTC')
                  AND EXTRACT(HOUR FROM date_time_utc) = 9
                """, [day])
            @test Int(raw2.nda[1]) == 0                     # genuinely DA-free
            @test only(se2[se2.time_period .== 10, :capacity]) ≈ Float64(raw2.blend[1]) atol = 1e-6

            # (c) switch OFF reproduces the pre-fix blend
            ENV["EUPHEMIA_DISABLE_ATC_DAPREF"] = "1"
            df_off = Euphemia.Network._fetch_atc_aggregated(day,
                "offered_transfer_capacities_implicit", ["EE"])
            lv_off = only(df_off[(df_off.source_zone .== "LV") .& (df_off.sink_zone .== "EE") .&
                                 (df_off.time_period .== 10), :capacity])
            @test lv_off ≈ blend atol = 1e-6      # h09 all-rows blend, exactly
            @test lv_off < 0.5 * lv_on

            # the scarcity-credit consumer sees the same preference
            delete!(ENV, "EUPHEMIA_DISABLE_ATC_DAPREF")
            atc_on = Euphemia.MeritOrderBook.get_import_atc_capacity("EE", day)
            ENV["EUPHEMIA_DISABLE_ATC_DAPREF"] = "1"
            atc_off = Euphemia.MeritOrderBook.get_import_atc_capacity("EE", day)
            @test get(atc_on, 9, 0.0) > 2 * get(atc_off, 9, 0.0)
        finally
            had === nothing ? delete!(ENV, "EUPHEMIA_DISABLE_ATC_DAPREF") :
                              (ENV["EUPHEMIA_DISABLE_ATC_DAPREF"] = had)
        end
    end
end
