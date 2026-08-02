#!/usr/bin/env python3
"""fit-iteration 6 lockstep check: python de_school_holiday()/windchill() (features.py,
training authority) vs the Julia ml_de_school_holiday/ml_windchill dumped to
dnload_iter6_jl.json. School-holiday days must match EXACTLY (date set, the Easter
pattern); windchill to <1e-9 (float pow, the equivalence-harness feature tolerance)."""
import os, sys, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import features as F
SP=F.SP
jl=json.load(open(f"{SP}/dnload_iter6_jl.json"))
import pandas as pd
# school-holiday days 2024-2027
py_days=sorted(str(pd.Timestamp(d).date()) for d in pd.date_range("2024-01-01","2027-12-31")
               if F.de_school_holiday(pd.Timestamp(d)))
j_days=sorted(jl["school_days"])
school_ok=(py_days==j_days)
print(f"school_hol days py={len(py_days)} jl={len(j_days)} MATCH={school_ok}")
if not school_ok:
    print("  py-only:", sorted(set(py_days)-set(j_days))[:10])
    print("  jl-only:", sorted(set(j_days)-set(py_days))[:10])
# windchill grid
maxd=0.0
for rec in jl["windchill"]:
    T,v,jv=rec["T"],rec["v"],rec["wc"]
    pv=F.windchill(T,v)
    if pv!=pv and jv!=jv: continue    # both NaN
    maxd=max(maxd,abs(pv-jv))
wc_ok=maxd<1e-9
print(f"windchill grid max|Δ|={maxd:.3e} MATCH(<1e-9)={wc_ok}")
print("LOCKSTEP_OK" if (school_ok and wc_ok) else "LOCKSTEP_FAIL")
