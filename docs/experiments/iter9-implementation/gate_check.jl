# iter9 G3 gate checker. Reads the per-window/per-arm/per-zone score TSV emitted
# by score_ab.jl (columns: window arm zone n corr mae bias sim_mean act_mean)
# and applies the PRE-REGISTERED G3 gates. Arm A = 39-zone control, B = 43-zone
# treatment. Prints a gate-by-gate verdict.
#
# Usage: julia gate_check.jl ab_scores.tsv
using Printf, Statistics

rows = NamedTuple[]
for (i, line) in enumerate(eachline(ARGS[1]))
    i == 1 && continue
    f = split(line, '\t')
    push!(rows, (win=f[1], arm=f[2], zone=f[3], n=parse(Int, f[4]),
        corr=parse(Float64, f[5]), mae=parse(Float64, f[6]), bias=parse(Float64, f[7])))
end

const FP39 = Set(split("AT BE BG CZ DE_LU DK1 DK2 EE ES FI FR GR HU LT LV NL NO1 NO2 NO3 NO4 NO5 PL PT RO RS SE1 SE2 SE3 SE4 SI SK IT-NORTH IT-CNORTH IT-CSOUTH IT-SOUTH IT-Calabria IT-Sicily IT-Sardinia CH"))
const NEW = ["AL", "HR", "ME", "MK"]
const NEW_GATE = Dict("MK" => 0.55, "ME" => 0.55, "HR" => 0.55, "AL" => 0.40)
const WINS = ["apr", "jul", "mar"]

get_row(win, arm, zone) = findfirst(r -> r.win == win && r.arm == arm && r.zone == zone, rows)

# Pooled (n-weighted) corr is not reconstructable from per-window corr, so pool
# by averaging per-window corr weighted by n; MAE pooled by n-weight. Report
# per-window as the primary evidence (that is where signal lives).
function pooled(arm, zone)
    rs = [rows[i] for w in WINS for i in (get_row(w, arm, zone) === nothing ? Int[] : [get_row(w, arm, zone)])]
    isempty(rs) && return nothing
    ntot = sum(r.n for r in rs)
    (corr=sum(r.corr * r.n for r in rs) / ntot, mae=sum(r.mae * r.n for r in rs) / ntot,
        bias=sum(r.bias * r.n for r in rs) / ntot, n=ntot)
end

println("="^78)
println("G3 GATE CHECK  (A = 39-zone control, B = 43-zone treatment)")
println("="^78)

# ---- Gate 1: new zones clear ----
println("\n[GATE 1] New zones clear their corr floors (pooled over all windows):")
g1 = true
for z in NEW
    p = pooled("B", z)
    if p === nothing
        @printf("  %-4s  NO DATA  -> FAIL\n", z); global g1 = false; continue
    end
    thr = NEW_GATE[z]
    ok = p.corr >= thr
    ok || (global g1 = false)
    @printf("  %-4s  corr=%.3f  mae=%.1f  bias=%+.1f  n=%d   floor %.2f  %s\n",
        z, p.corr, p.mae, p.bias, p.n, thr, ok ? "PASS" : "FAIL")
    print("        per-window: ")
    for w in WINS
        i = get_row(w, "B", z)
        i === nothing ? print("$w=NA ") : @printf("%s=%.2f(n%d) ", w, rows[i].corr, rows[i].n)
    end
    println()
end
println("  => GATE 1 ", g1 ? "PASS" : "FAIL")

# ---- Gate 2: no existing zone degrades > 0.03 corr or > 1.5 MAE ----
println("\n[GATE 2] No existing (39) zone degrades > 0.03 corr or > 1.5 MAE.")
println("         Reporting worst per-window degradation per zone.")
g2 = true
worst = NamedTuple[]
for z in sort(collect(FP39))
    for w in WINS
        ia = get_row(w, "A", z); ib = get_row(w, "B", z)
        (ia === nothing || ib === nothing) && continue
        dcorr = rows[ib].corr - rows[ia].corr
        dmae = rows[ib].mae - rows[ia].mae
        viol = (dcorr < -0.03) || (dmae > 1.5)
        viol && (global g2 = false)
        (viol || abs(dcorr) > 0.02 || abs(dmae) > 1.0) &&
            push!(worst, (zone=z, win=w, dcorr=dcorr, dmae=dmae, viol=viol))
    end
end
sort!(worst, by=r -> r.dcorr)
if isempty(worst)
    println("  (all 39 zones move < 0.02 corr and < 1.0 MAE in every window)")
else
    for r in worst
        @printf("  %-11s %s  Δcorr=%+.3f  ΔMAE=%+.2f  %s\n",
            r.zone, r.win, r.dcorr, r.dmae, r.viol ? "<-- VIOLATION" : "")
    end
end
println("  => GATE 2 ", g2 ? "PASS" : "FAIL")

# ---- Gate 3: HU control on July ----
println("\n[GATE 3] HU must not degrade on the July window:")
ia = get_row("jul", "A", "HU"); ib = get_row("jul", "B", "HU")
if ia === nothing || ib === nothing
    println("  HU July missing -> FAIL"); g3 = false
else
    dcorr = rows[ib].corr - rows[ia].corr; dmae = rows[ib].mae - rows[ia].mae
    g3 = (dcorr >= -0.03) && (dmae <= 1.5)
    @printf("  HU jul  A(corr=%.3f mae=%.1f)  B(corr=%.3f mae=%.1f)  Δcorr=%+.3f ΔMAE=%+.2f  %s\n",
        rows[ia].corr, rows[ia].mae, rows[ib].corr, rows[ib].mae, dcorr, dmae, g3 ? "PASS" : "FAIL")
end
println("  => GATE 3 ", g3 ? "PASS" : "FAIL")

println("\n", "="^78)
allpass = g1 && g2 && g3
println("OVERALL (gates 1-3): ", allpass ? "PASS" : "FAIL",
    "   (Gate 4 SEE bit-identity checked separately)")
println("="^78)
