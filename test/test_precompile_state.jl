# The precompile workload (src/precompile_workload.jl) runs at package-precompile time, and any
# module-level state it leaves is serialized into the package image. A FRESH process right after
# `using Euphemia` must therefore see pristine state: every cache/memo empty, every process-wide
# record and setting at its default, no lock held, no workload variable left behind.
# Runs the check in a subprocess (this test process has already run other tests).
#
# Standalone:  julia --project=. test/test_precompile_state.jl

using Test

const _PS_SCRIPT = raw"""
using Euphemia
function mods(m, seen=Set{Module}())
    m in seen && return seen
    push!(seen, m)
    for n in names(m; all=true)
        isdefined(m, n) || continue
        v = getfield(m, n)
        v isa Module && parentmodule(v) === m && v !== m && mods(v, seen)
    end
    seen
end
bad = String[]
for m in mods(Euphemia), n in names(m; all=true)
    isdefined(m, n) || continue
    v = try getfield(m, n) catch; continue end
    s = string(n)
    startswith(s, "_pw_") && push!(bad, "$m.$s: workload variable left in the module")
    if (v isa AbstractDict || v isa AbstractSet) && occursin(r"CACHE|MEMO|CHECKED|LOCKS"i, s)
        isempty(v) || push!(bad, "$m.$s: $(length(v)) entries after load")
    end
    v isa Base.AbstractLock && islocked(v) && push!(bad, "$m.$s: lock held after load")
    if v isa Base.RefValue && occursin(r"WARNED"i, s)
        v[] === false || push!(bad, "$m.$s = $(v[])")
    end
end
M = Euphemia.MPCC
M.LAST_COMPLEX_INFO[] === nothing || push!(bad, "MPCC.LAST_COMPLEX_INFO is set after load")
M.LP_CERT_COUNTS[] == (certified = 0, fallback = 0) || push!(bad, "MPCC.LP_CERT_COUNTS = $(M.LP_CERT_COUNTS[])")
B = Euphemia.MeritOrderBook
B.BOOK_SINK[] === nothing || push!(bad, "MeritOrderBook.BOOK_SINK is set after load")
B.FLEET_TRUTH_OVERRIDE[] === nothing || push!(bad, "MeritOrderBook.FLEET_TRUTH_OVERRIDE is set after load")
println("PSTATE ", isempty(bad) ? "CLEAN" : join(bad, " | "))
"""

@testset "fresh process: no state left by the precompile workload" begin
    out = read(`$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) -e $_PS_SCRIPT`, String)
    line = something(findlast(l -> startswith(l, "PSTATE "), split(out, '\n')), 0)
    @test line != 0
    line == 0 || @test split(out, '\n')[line] == "PSTATE CLEAN"
end
