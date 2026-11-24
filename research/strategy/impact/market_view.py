"""Market view (st-impact, part B): which markups do realised prices imply against our competitive book?

For a zone-hour we hold
  * the tagged pre-merge book of the zone (runs/baseline/<day>.tagged.csv.gz: owner_tag, strategy, price, quantity),
  * D0(p): MW the zone must absorb (as a price-taking injection) for its coupled price to be p — the inverse of the
    harness `residual_demand` curve (coupled response) or, as a fallback, the zone's own islanded curves,
  * our baseline price p_base and the realised SDAC price p_real.

Counterfactual: the zone's FLEXIBLE thermal capacity (orders labelled `srmc_base` / `peak_tranche_*`, the ones the
conduct ladder prices) is re-bid at a FLAT markup over its own SRMC: gmc x (1 + m). Must-run blocks, RES, hydro water
values, imports are untouched. The supply this adds at price p relative to the book is
    dS_m(p) = sum_i q_i [gmc_i (1+m) <= p]  -  S_book,set(p)
and the zone clears at p where D0(p) = dS_m(p) (same argument as the carve: the zone price depends on its net supply).
The implied markup m* at the realised price solves  sum_i q_i [gmc_i <= p_real/(1+m)] = S_book,set(p_real) + D0(p_real)
— the T-quantile of the set's SRMC ladder. The same at p_base (D0 = 0) gives the flat markup equivalent to the book's
own ladder (m_book). DEFAULT_MARKUP_FACTOR 1.1 (MPCC.jl:69) is inert since cv25 and is reported only as a reference.

SRMC per unit-hour: the book prices the first tranche at 0.95 x gmc (TRANCHES[1], zone_profiles.jl:238, scarcity not
applied to tranche 1, book_build.jl:1962), so gmc = price(srmc_base) / 0.95.
"""
from __future__ import annotations

import gzip
import re
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path.home() / "armada/em-team/strategy"
BASE = ROOT / "runs/baseline"
TRANCHE1_MULT = 0.95  # zone_profiles.jl:238 TRANCHES[1] = (0.55, 0.95)
NOMINAL_MARKUP_FACTOR = 1.1  # was MPCC.jl:69 DEFAULT_MARKUP_FACTOR, inert since cv25; deleted on main by #481 (reference only)
FLEX = re.compile(r"^(srmc_base|peak_tranche_\d+)$")

TECH = {
    "Fossil Gas": "gas", "Fossil Hard coal": "coal", "Fossil Brown coal/Lignite": "lignite",
    "Fossil Coal-derived gas": "coal", "Fossil Oil": "oil", "Fossil Oil shale": "oil", "Fossil Peat": "lignite",
    "Nuclear": "nuclear", "Biomass": "other", "Waste": "other", "Geothermal": "other", "Other": "other",
    "Hydro Pumped Storage": "hydro", "Hydro Water Reservoir": "hydro", "Hydro Run-of-river and pondage": "hydro",
    "Energy storage": "storage", "Solar": "res", "Wind Onshore": "res", "Wind Offshore": "res",
}
THERMAL = {"gas", "coal", "lignite", "oil", "nuclear", "other"}


def registry_fuel(con):
    """unit code -> ENTSO-E fuel label (generation and production unit codes)."""
    g = con.sql("select distinct generation_unit_code c, generation_unit_type t from entsoe.production_and_generation_units "
                "where generation_unit_code is not null").df()
    p = con.sql("select distinct production_unit_code c, production_unit_type t from entsoe.production_and_generation_units "
                "where production_unit_code is not null").df()
    d = dict(zip(p.c, p.t))
    d.update(dict(zip(g.c, g.t)))
    return d


def tech_of(tag: str, fuel: dict) -> str:
    if tag in fuel and fuel[tag] in TECH:
        return TECH[fuel[tag]]
    m = re.match(r"^(AGG|OUT)-[^-]+(?:-[A-Z]+)?-(.+)$", tag)  # AGG-<zone>-Fossil_Gas, OUT-DE_LU-Fossil_Brown_coal/Lignite
    if m:
        lab = m.group(2).replace("_", " ")
        for k, v in TECH.items():
            if lab == k:
                return v
    return {"RES": "res", "IMPORT": "import", "BACKSTOP": "import", "EXTRA": "extra"}.get(tag, "unknown")


def load_tagged(day: str, zones, fuel: dict) -> pd.DataFrame:
    df = pd.read_csv(BASE / f"{day}.tagged.csv.gz", parse_dates=["date_time_utc"])
    df = df[df.zone.isin(zones)].copy()
    df["hour"] = df.date_time_utc.dt.hour
    df["tech"] = [tech_of(t, fuel) for t in df.owner_tag]
    df["fuel"] = [fuel.get(t, "") or ("Hydro Pumped Storage" if "Pumped" in t else "") for t in df.owner_tag]
    df["flex"] = df.strategy.str.match(FLEX) & df.tech.isin(THERMAL)
    gmc = (df[df.strategy == "srmc_base"].groupby(["zone", "hour", "owner_tag"]).price.first() / TRANCHE1_MULT)
    df = df.join(gmc.rename("gmc"), on=["zone", "hour", "owner_tag"])
    return df


def supply_le(orders: pd.DataFrame, p: float) -> float:
    return float(orders.quantity[(orders.type == "supply") & (orders.price <= p)].sum())


def ladder_quantile(gmc, q, T):
    """Threshold SRMC c* with capacity sum q[gmc <= c*] = T, linear within the capacity-weighted ladder.
    Returns (c*, flag): flag 'lo' (T<=0, all must leave: censored), 'hi' (T>=total), '' ok."""
    o = np.argsort(gmc)
    g, w = np.asarray(gmc)[o], np.asarray(q)[o]
    cum = np.cumsum(w)
    if T <= 0:
        return g[0], "lo"
    if T >= cum[-1]:
        return g[-1], "hi"
    i = int(np.searchsorted(cum, T))
    prev = cum[i - 1] if i > 0 else 0.0
    gprev = g[i - 1] if i > 0 else g[0]
    return gprev + (g[i] - gprev) * (T - prev) / max(w[i], 1e-9), ""


def implied_markup(zh: pd.DataFrame, D0, p_target: float, techs=None):
    """Flat markup over SRMC on the flexible thermal set (optionally restricted to `techs`) that makes the zone clear
    at p_target. D0: callable p -> MW. Returns (m, flag, set_MW)."""
    s = zh[zh.flex & zh.gmc.notna() & (zh.type == "supply")]
    if techs is not None:
        s = s[s.tech.isin(techs)]
    if s.empty or p_target <= 0:
        return np.nan, "empty", 0.0
    T = supply_le(s, p_target) + float(D0(p_target))
    # m depends on the unit level, so collapse the set to units (gmc, total MW)
    u = s.groupby("owner_tag").agg(gmc=("gmc", "first"), q=("quantity", "sum"))
    u = u[u.gmc > 0]
    if u.empty:
        return np.nan, "empty", 0.0
    c, flag = ladder_quantile(u.gmc.values, u.q.values, T)
    return p_target / c - 1.0, flag, float(u.q.sum())


def marginal_tech(zh: pd.DataFrame, p_base: float, rel=0.02, abs_eur=1.0) -> str:
    """Technology of the zone's supply order priced closest to p_base (within 2% + 1 €), else 'coupled'."""
    s = zh[zh.type == "supply"]
    if s.empty:
        return "coupled"
    d = (s.price - p_base).abs()
    i = d.idxmin()
    if d[i] > rel * abs(p_base) + abs_eur:
        return "coupled"
    # several techs at the same price -> the one with the most MW there
    at = s[(s.price - s.price[i]).abs() < 1e-6]
    return at.groupby("tech").quantity.sum().idxmax()


def D0_islanded(zh: pd.DataFrame, p_base: float):
    """Fallback D0 with fixed net imports: the zone's own supply and demand around p_base (no coupling response)."""
    sup = zh[zh.type == "supply"].sort_values("price")
    dem = zh[zh.type == "demand"].sort_values("price")
    sp, sq = sup.price.values, np.cumsum(sup.quantity.values)
    dp, dq = dem.price.values[::-1], np.cumsum(dem.quantity.values[::-1])

    def S(p):
        i = np.searchsorted(sp, p, side="right")
        return sq[i - 1] if i > 0 else 0.0

    def D(p):  # demand with bid >= p
        i = np.searchsorted(-dp, -p, side="right")
        return dq[i - 1] if i > 0 else 0.0

    S0, Dm0 = S(p_base), D(p_base)
    # injection that clears at p: -(S(p)-S0) + (D(p)-Dm0)
    return lambda p: -(S(p) - S0) + (D(p) - Dm0)


def D0_from_rd(rd_points):
    """rd_points: [(q, price)] from residual_demand for one period -> D0(p) = sup{q : P0(q) >= p} (linear)."""
    q = np.array([a for a, _ in rd_points], float)
    pr = np.minimum.accumulate(np.array([b for _, b in rd_points], float))
    from rdopt import inverse_nonincreasing  # noqa: E402 (same directory)

    return lambda p: inverse_nonincreasing(q, pr, p)


def read_gz_lines(path):
    with gzip.open(path, "rt") as f:
        return f.read().splitlines()


def price_with_markup(zh: pd.DataFrame, D0, m: float, p_ref: float, techs=None, lo=-500.0, hi=4000.0, step=0.25):
    """Zone price when the flexible thermal set (optionally only `techs`) is re-bid at gmc x (1+m): the root of
    D0(p) = dS_m(p) nearest p_ref on a 0.25 €/MWh scan (dS_m = repriced-set supply minus the book's set supply)."""
    s = zh[zh.flex & zh.gmc.notna() & (zh.type == "supply")]
    if techs is not None:
        s = s[s.tech.isin(techs)]
    u = s.groupby("owner_tag").agg(gmc=("gmc", "first"), q=("quantity", "sum"))
    bp, bq = np.sort(s.price.values), s.quantity.values[np.argsort(s.price.values)]
    bcum = np.concatenate([[0.0], np.cumsum(bq)])
    np_ = (u.gmc.values * (1.0 + m))
    o = np.argsort(np_)
    mp, mcum = np_[o], np.concatenate([[0.0], np.cumsum(u.q.values[o])])
    g = np.arange(lo, hi, step)
    dS = mcum[np.searchsorted(mp, g, side="right")] - bcum[np.searchsorted(bp, g, side="right")]
    v = D0(g)
    if np.ndim(v) == 0:  # scalar-only D0 (islanded)
        v = np.array([D0(p) for p in g])
    f = np.asarray(v, float) - dS  # >0: excess demand at p -> price higher
    sgn = np.sign(f)
    idx = np.nonzero((sgn[:-1] > 0) & (sgn[1:] <= 0))[0]
    if len(idx) == 0:
        return np.nan
    roots = g[idx + 1]
    return float(roots[np.argmin(np.abs(roots - p_ref))])


def md(df, index=True, floatfmt="{:.2f}"):
    """Markdown table without tabulate (not in the venv)."""
    d = df.reset_index() if index else df
    cols = [" / ".join(map(str, c)) if isinstance(c, tuple) else str(c) for c in d.columns]
    f = lambda v: floatfmt.format(v) if isinstance(v, (float, np.floating)) and not np.isnan(v) else ("" if (isinstance(v, float) and np.isnan(v)) else str(v))  # noqa: E731
    lines = ["| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
    lines += ["| " + " | ".join(f(v) for v in row) + " |" for row in d.itertuples(index=False)]
    return "\n".join(lines)
