# Solar shape fix: per-hour-of-day slopes on GHI (captures systematic
# tilt/curtailment/aggregation shape the single slope misses).
using CSV, DataFrames, Dates, Statistics, Printf, LinearAlgebra
pts(x) = eltype(x) <: DateTime ? x : DateTime.(replace.(String.(x), " " => "T"))
dafc = CSV.read("da_forecast.csv", DataFrame); dafc.h = pts(dafc.h)
actual = CSV.read("actual.csv", DataFrame); actual.h = pts(actual.h)
sf = sort(rename(unstack(filter(r->r.production_type=="Solar", dafc), :h, :production_type, :mw), "Solar"=>:sol_fc), :h)
sa = sort(rename(unstack(filter(r->r.production_type=="Solar", actual), :h, :production_type, :mw), "Solar"=>:sol_act), :h)
c = CSV.read("solar_prev.csv", DataFrame); c.h = pts(c.h)
w = sort(unstack(c[:, [:city_id,:h,:shortwave_radiation_previous_day1]], :h, :city_id, :shortwave_radiation_previous_day1), :h)
sites = [n for n in names(w) if n != "h"]
d = dropmissing(innerjoin(innerjoin(sf, sa, on=:h), w, on=:h)); sort!(d, :h)
g = [mean(skipmissing(r)) for r in eachrow(Matrix(d[:, sites]))]
LAT=38.0*pi/180; LON=23.7
sinel(ts)=(doy=dayofyear(ts); dec=0.409*sin(2pi*(doy+284)/365); H=(hour(ts)+LON/15-12)*15*pi/180; max(sin(LAT)*sin(dec)+cos(LAT)*cos(dec)*cos(H),0.0))
se = sinel.(d.h)
hod = hour.(d.h)
H = reduce(hcat, [Float64.(hod .== k) .* g for k in 3:19])       # per-hour GHI slope
Hc = reduce(hcat, [Float64.(hod .== k) for k in 3:19])           # per-hour offset
F = hcat(ones(length(g)), g, se, g.*se, sqrt.(max.(g,0)), H, Hc)
istr = d.h .< DateTime(2026,4,1); iste = .!istr
rdg(X,y,l) = (A = X'*X + l*I(size(X,2)); A[1,1] -= l; A \ (X'*y))
for (nm, y) in [("-> DAfc", collect(Float64,d.sol_fc)), ("-> actual", collect(Float64,d.sol_act))]
    for lam in (1.0, 10.0)
        b = rdg(F[istr,:], y[istr], lam)
        pr = max.(F[iste,:]*b, 0.0)
        @printf("hod-cal %-10s λ=%-4g OOS corr=%.3f  MAE=%6.1f  bias=%+.0f\n", nm, lam, cor(pr,y[iste]), mean(abs.(pr.-y[iste])), mean(pr.-y[iste]))
    end
end
# save best (λ=1, DAfc target) for a possible v3 combined pred
b = rdg(F[istr,:], collect(Float64,d.sol_fc)[istr], 1.0)
CSV.write("sol_pred_hod.csv", DataFrame(h=d.h[iste], sol_pred=max.(F[iste,:]*b, 0.0)))
