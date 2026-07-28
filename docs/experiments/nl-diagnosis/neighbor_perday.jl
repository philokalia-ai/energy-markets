using CSV, DataFrames, Statistics, Dates, Printf
SP=ENV["SP"]; ab=CSV.read(joinpath(SP,"ab2.csv"),DataFrame)
set=CSV.read(joinpath(SP,"settled_neighbors.csv"),DataFrame)
sd=Dict((string(r.zone),DateTime(r.utc))=>Float64(r.settled) for r in eachrow(set))
ab.dt=[DateTime(String(t),dateformat"yyyymmdd-HHMM") for t in ab.ts]
ab.mset=[get(sd,(String(r.zone),r.dt),missing) for r in eachrow(ab)]
dropmissing!(ab,:mset)
WIN=["2025-11-01","2025-11-15","2025-12-01","2026-01-01","2026-01-15","2026-02-01","2026-02-15"]
for z in ["FR","BE","DE_LU","NO2","DK1"]
  println("### $z winter per-day ###")
  for dd in WIN
    a=ab[(ab.zone.==z).&(ab.arm.=="A_off").&(string.(ab.day).==dd),:]
    b=ab[(ab.zone.==z).&(ab.arm.=="B_on").&(string.(ab.day).==dd),:]
    (nrow(a)<3||nrow(b)<3)&&continue
    ca=cor(a.price,a.mset); cb=cor(b.price,b.mset)
    ma=mean(abs.(a.price.-a.mset)); mb=mean(abs.(b.price.-b.mset))
    @printf("  %s %s dC=%+.3f (%.3f->%.3f) dMAE=%+.2f\n",dd,z,cb-ca,ca,cb,mb-ma)
  end
end
