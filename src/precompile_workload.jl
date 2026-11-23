# Precompile workload (perf-96): compile the clearing path at package-precompile time instead of
# on the first call of every process. A cold daily-forecast / record process spent most of its
# first MPCC solve compiling (master LP, per-period JuMP models, LP certificate, fix-and-reprice).
# The workload clears a tiny DB-free three-zone book through the same entry points the pipelines
# use (mz_solve_pass, mz_extract_anchor_inputs), so the native code for those call trees is cached
# in the package image. It reads no data store; a failure is swallowed (no benefit, never a broken
# precompile).
#
# Module-level state is serialized into the package image, so the workload must leave none: its
# data lives inside _precompile_clear (no globals), and the two process-wide records the solve
# writes (MPCC.LAST_COMPLEX_INFO, MPCC.LP_CERT_COUNTS) are restored afterwards.
# test/test_precompile_state.jl checks a fresh process for leftovers.
using PrecompileTools: @compile_workload

function _precompile_clear()
    day = Dates.Date(2026, 1, 15)
    zones = ["A", "B", "C"]
    dts = [Dates.DateTime(day) + Dates.Hour(h) for h in 0:3]
    periods = [Dates.format(t, "yyyymmdd-HHMM") for t in dts]
    orders = MarketOrders.MarketOrder[]
    for (zi, z) in enumerate(zones), (hi, t) in enumerate(dts)
        zs = Symbol(z)
        for (p, q) in ((5.0 + zi, 300.0), (60.0 + 5zi + hi, 400.0), (150.0 + 10zi, 500.0))
            push!(orders, MarketOrders.SimpleOrder(:supply, p, q, zs, t, 60))
        end
        push!(orders, MarketOrders.SimpleOrder(:demand, 3000.0, 600.0 + 50hi, zs, t, 60))
        push!(orders, MarketOrders.SimpleOrder(:demand, 40.0, 150.0, zs, t, 60))
        zi == 1 && push!(orders,
            MarketOrders.LinkedHourlyOrder(:supply, 45.0, 200.0, zs, t, 60, "ESTOR:A", 300.0))
    end
    fwd = Dict{Tuple{String,String,String},Float64}()
    bwd = Dict{Tuple{String,String,String},Float64}()
    for h in 1:24, (a, b) in (("A", "B"), ("B", "C"))
        fwd[(a, b, string(h))] = 250.0
        bwd[(a, b, string(h))] = 250.0
    end
    tc = Network.TransferCapacity(zones, [string(h) for h in 1:24], fwd, bwd)
    ob = MPCC.MPCCOrderBook(orders, zones, periods, (-500.0, 3000.0), tc)
    r = mz_solve_pass(ob; optimizer="highs", silent=true, decompose_periods=true)
    mz_extract_anchor_inputs(ob, r; apply_zone_profiles=false)
    return nothing
end

@compile_workload begin
    saved_info, saved_counts = MPCC.LAST_COMPLEX_INFO[], MPCC.LP_CERT_COUNTS[]
    try
        redirect_stdout(_precompile_clear, devnull)
    catch
    finally
        MPCC.LAST_COMPLEX_INFO[] = saved_info
        MPCC.LP_CERT_COUNTS[] = saved_counts
    end
end
