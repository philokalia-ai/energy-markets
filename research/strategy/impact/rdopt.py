"""Strategic bidding against a residual-demand curve (st-impact, strategy research).

Pure numpy; no I/O. The Julia harness (`src/strategy/StrategyHarness.jl`, `residual_demand`) produces, per
(day, zone, period), the zone price when the company injects q MW price-taking. Everything here works on that curve.

Conventions
-----------
* A *residual demand* for the company is held on a PRICE grid: `D(p)` = MW the company can sell at price p
  (non-increasing in p). Its inverse `P(q)` = sup{p : D(p) >= q}.
* `D0` (no carve, from `residual_demand`) is the injection q at which the zone clears at p. The company's own
  portfolio replaces carved baseline supply `K(p)` (MW of carved book orders priced <= p), so the company faces
  D_c(p) = D0(p) + K(p)  (exact when the zone price depends only on its net supply curve; checked by reclear).
* A company *offer curve* is non-decreasing `x(p)` in [0, S]: MW offered at prices <= p.
  The market clears where x meets D_c. On a price grid p_0 < ... < p_{M-1} with x_j = x(p_j):
  the crossing interval is (p_{j-1}, p_j] where D(p_{j-1}) > x_{j-1} and D(p_j) <= x_j;
    if D(p_j) >= x_{j-1}: price p_j, dispatch D(p_j)        (company's horizontal step is marginal)
    else                : price P(x_{j-1}), dispatch x_{j-1} (others are marginal; company vertical)
* Cost: a step marginal-cost curve (blocks of MW with €/MWh), C(q) = integral of it. Fixed costs are out of scope
  for the portfolio slice (hourly divisible); stated in the report.
"""
from __future__ import annotations

import numpy as np

# ---------------------------------------------------------------------------------------------------------------
# monotone curve helpers


def monotone_nonincreasing(y):
    """Smallest-change fix of numerical noise: running minimum (a clear can return tiny non-monotone ties)."""
    return np.minimum.accumulate(np.asarray(y, dtype=float))


def inverse_nonincreasing(x_grid, y, y_query):
    """For y(x) non-increasing on increasing x_grid, return sup{x : y(x) >= y_query} with linear interpolation.

    Below the grid's lowest y -> x_grid[-1]; above the highest -> x_grid[0] (clamped; callers size grids)."""
    x_grid = np.asarray(x_grid, float)
    y = np.asarray(y, float)
    yq = np.atleast_1d(np.asarray(y_query, float))
    # number of points with y >= yq  (y non-increasing => -y non-decreasing)
    idx = np.searchsorted(-y, -yq, side="right")
    n = len(x_grid)
    a = np.clip(idx - 1, 0, n - 2)
    b = a + 1
    den = y[a] - y[b]
    frac = np.where(den > 0, (y[a] - yq) / np.where(den > 0, den, 1.0), 0.0)
    out = x_grid[a] + (x_grid[b] - x_grid[a]) * np.clip(frac, 0.0, 1.0)
    out = np.where(idx == 0, x_grid[0], np.where(idx == n, x_grid[-1], out))
    return out if np.ndim(y_query) else out[0]


class ResidualDemand:
    """Company residual demand on a price grid: D(p_j), non-increasing."""

    def __init__(self, p_grid, d):
        self.p = np.asarray(p_grid, float)
        assert np.all(np.diff(self.p) > 0), "price grid must be strictly increasing"
        self.d = monotone_nonincreasing(d)

    @classmethod
    def from_injection_curve(cls, q_inj, price, p_grid):
        """From the harness' `residual_demand` output: zone price when the company injects q (q increasing)."""
        q_inj = np.asarray(q_inj, float)
        pr = monotone_nonincreasing(price)
        return cls(p_grid, inverse_nonincreasing(q_inj, pr, p_grid))

    def D(self, p):
        return np.interp(p, self.p, self.d)

    def P(self, q):
        """Inverse demand sup{p : D(p) >= q}."""
        return inverse_nonincreasing(self.p, self.d, q)

    def area(self, u):
        """∫_0^u P(x) dx (u < 0: minus the integral from u to 0) — the welfare a price-taking injection u adds when
        every MW is cleared at its own marginal price (competitive dispatch)."""
        if not hasattr(self, "_aq"):
            qs = np.linspace(min(self.d.min(), 0.0), max(self.d.max(), 0.0), 4001)
            ps = self.P(qs)
            cum = np.concatenate([[0.0], np.cumsum(0.5 * (ps[1:] + ps[:-1]) * np.diff(qs))])
            self._aq, self._ac = qs, cum - np.interp(0.0, qs, cum)
        return np.interp(u, self._aq, self._ac)

    def shifted_price(self, e):
        """Scenario curve P_e(q) = P(q) + e, i.e. D_e(p) = D(p - e), on the same price grid."""
        return ResidualDemand(self.p, np.interp(self.p - e, self.p, self.d))

    def plus_supply(self, K):
        """D_c(p) = D(p) + K(p) for a carved supply curve K (callable on p or array on self.p)."""
        k = K(self.p) if callable(K) else np.asarray(K, float)
        return ResidualDemand(self.p, self.d + k)


# ---------------------------------------------------------------------------------------------------------------
# cost


class StepCost:
    """Marginal-cost ladder: blocks (mw_i, mc_i) sorted by mc. Capacity S = sum mw_i."""

    def __init__(self, mw, mc):
        o = np.argsort(mc, kind="stable")
        self.mw = np.asarray(mw, float)[o]
        self.mc = np.asarray(mc, float)[o]
        self.cum = np.concatenate([[0.0], np.cumsum(self.mw)])
        self.S = float(self.cum[-1])

    def C(self, q):
        """Total variable cost of producing q (0 <= q <= S), merit-order within the portfolio."""
        q = np.clip(np.asarray(q, float), 0.0, self.S)
        sold = np.clip(q[..., None] - self.cum[:-1], 0.0, self.mw)
        return (sold * self.mc).sum(-1)

    def truthful_offer(self, p):
        """x(p) = MW with mc <= p (bid at marginal cost)."""
        p = np.asarray(p, float)
        return (self.mw * (self.mc <= p[..., None])).sum(-1)


# ---------------------------------------------------------------------------------------------------------------
# clearing an offer curve against a residual demand


def clear_offer(rd: ResidualDemand, x_on_grid):
    """Clear the offer curve x (given on rd.p, non-decreasing) against rd. Returns (price, dispatch)."""
    x = np.maximum.accumulate(np.asarray(x_on_grid, float))
    d = rd.d
    cross = np.nonzero(d <= x)[0]
    if len(cross) == 0:  # company never covers demand on the grid: price above grid top, dispatch x_top
        return float(rd.P(x[-1])), float(x[-1])
    j = cross[0]
    if j == 0:
        return float(rd.p[0]), float(d[0])
    if d[j] >= x[j - 1]:
        return float(rd.p[j]), float(d[j])
    return float(rd.P(x[j - 1])), float(x[j - 1])


def offer_profit(rd, x_on_grid, cost: StepCost):
    p, q = clear_offer(rd, x_on_grid)
    return p * q - float(cost.C(q)), p, q


# ---------------------------------------------------------------------------------------------------------------
# per-hour Cournot (choose q against P(q))


def cournot(rd: ResidualDemand, cost: StepCost, n_q=401):
    """argmax_{0<=q<=S} P(q) q - C(q) on a fine q grid (+ the cost-ladder kinks). Returns (q*, P(q*), profit)."""
    qs = np.unique(np.concatenate([np.linspace(0, cost.S, n_q), cost.cum]))
    pr = rd.P(qs)
    prof = pr * qs - cost.C(qs)
    i = int(np.argmax(prof))
    return float(qs[i]), float(pr[i]), float(prof[i])


def truthful(rd: ResidualDemand, cost: StepCost):
    x = cost.truthful_offer(rd.p)
    return offer_profit(rd, x, cost)


# ---------------------------------------------------------------------------------------------------------------
# optimal monotone step offer against a set of residual-demand scenarios (Anderson-Philpott style DP)


def optimal_offer(scenarios, weights, cost: StepCost, n_q=81, anchor=None, eps=1e-6):
    """Expected-profit-maximising non-decreasing step offer x(p) on the common price grid of `scenarios`.

    scenarios: list of ResidualDemand on the SAME price grid; weights sum to 1.
    State: x_j in a quantity grid Q (n_q points on [0, S]). DP over price index j:
      V_j(x) = max_{x' <= x} V_{j-1}(x') + sum_k w_k [D_k(p_{j-1}) > x'] [D_k(p_j) <= x] r_k(j, x')
    with r_k(j, x') the profit if scenario k crosses in (p_{j-1}, p_j] (see module doc). Scenarios that never cross
    clear above the grid top at P_k(x_{M-1}) with dispatch x_{M-1}. Exact for the discretised problem.
    anchor: an offer curve on the price grid (default: truthful) that breaks ties: many curves are optimal against
    the scenarios (only the crossings are pinned), so a penalty eps x |x_j - anchor_j| (€ per MW per grid point,
    tiny) picks the one that stays truthful wherever deviating does not pay. Without it, the curve away from the
    crossings is arbitrary and its realised-price score is noise.
    Returns (x_on_grid, expected_profit) (profit without the tie-break penalty).
    """
    p = scenarios[0].p
    M = len(p)
    K = len(scenarios)
    w = np.asarray(weights, float)
    Q = np.linspace(0.0, cost.S, n_q)
    Dk = np.stack([s.d for s in scenarios])  # K x M
    # profit if scenario k crosses at j with previous level x' (index over Q): K x M x N
    Cq = cost.C(Q)
    # case A: price p_j, dispatch D_k(p_j) (needs D_k(p_j) >= x')
    dA = np.minimum(Dk, cost.S)
    rA = p[None, :] * dA - cost.C(dA)  # K x M
    # case B: price P_k(x'), dispatch x'
    PkQ = np.stack([s.P(Q) for s in scenarios])  # K x N
    rB = PkQ * Q[None, :] - Cq[None, :]  # K x N
    NEG = -1e18
    # j = 0: crossing at the grid bottom when D_k(p_0) <= x_0
    V = np.zeros(n_q)
    ind0 = (Dk[:, 0][:, None] <= Q[None, :])  # K x N
    anc = cost.truthful_offer(p) if anchor is None else np.asarray(anchor, float)
    pen = lambda j: eps * np.abs(Q - anc[j])  # noqa: E731
    V = (w[:, None] * ind0 * rA[:, 0][:, None]).sum(0) - pen(0)
    back = np.zeros((M, n_q), dtype=np.int32)
    back[0] = np.arange(n_q)
    for j in range(1, M):
        alive = Dk[:, j - 1][:, None] > Q[None, :]  # K x N   (over x')
        caseA = Dk[:, j][:, None] >= Q[None, :]  # K x N   (over x')
        rk = np.where(caseA, rA[:, j][:, None], rB)  # K x N
        M1 = (w[:, None] * alive * rk).T  # N(x') x K
        M2 = (Dk[:, j][:, None] <= Q[None, :]).astype(float)  # K x N(x)
        A = M1 @ M2  # N(x') x N(x)
        tot = V[:, None] + A
        tot = np.where(Q[:, None] <= Q[None, :], tot, NEG)  # monotone: x' <= x
        back[j] = np.argmax(tot, axis=0)
        V = tot[back[j], np.arange(n_q)] - pen(j)
    # scenarios never crossing on the grid: dispatch x_{M-1}, price P_k(x_{M-1})
    never = Dk[:, -1][:, None] > Q[None, :]
    V = V + (w[:, None] * never * rB).sum(0)
    i = int(np.argmax(V))
    best = float(V[i])
    idx = np.empty(M, dtype=np.int32)
    idx[-1] = i
    for j in range(M - 1, 0, -1):
        idx[j - 1] = back[j][idx[j]]
    x = Q[idx]
    return x, expected_profit(scenarios, weights, x, cost)


def expected_profit(scenarios, weights, x_on_grid, cost):
    return float(sum(w * offer_profit(s, x_on_grid, cost)[0] for s, w in zip(scenarios, weights)))


# ---------------------------------------------------------------------------------------------------------------
# simple parametric arms (all expressed as offer curves on the price grid)


def markup_offer(p_grid, cost: StepCost, m):
    """Every block offered at (1+m) x mc (m >= 0); mc <= 0 blocks keep mc + m*|mc|."""
    price = cost.mc + m * np.abs(cost.mc)
    return (cost.mw * (price <= np.asarray(p_grid)[:, None])).sum(-1)


def withhold_offer(p_grid, cost: StepCost, q):
    """Offer only the cheapest q MW at mc (physical withholding of S-q)."""
    x = cost.truthful_offer(p_grid)
    return np.minimum(x, q)


# ---------------------------------------------------------------------------------------------------------------
# energy-limited assets: shifting volume between hours (hydro reservoir / storage), DP over stored energy


def energy_dp(rds, e0, e_cap, p_max_dis, p_max_ch, eta, value_end, n_e=121, n_u=None, impact=True, var_cost=0.0,
              de=None, pt_prices=None, objective="revenue"):
    """Choose hourly net injection u_t (discharge > 0, charge < 0) to maximise
         sum_t [P_t(u_t) u_t - var_cost * max(u_t,0)] + value_end * e_T
    with storage e_{t+1} = e_t - u_t (discharge) / e_t - eta * u_t (charge, u_t < 0), 0 <= e <= e_cap.
    `rds[t]` = company residual demand of hour t (ResidualDemand). impact=False -> price-taker at P_t(0).
    Hydro: p_max_ch = 0, e0 = budget, value_end = water value. Returns (u, e_path, objective).
    impact=False: price-taker at pt_prices[t] (default P_t(0)). de: energy grid step (overrides n_e).
    objective="welfare" (with impact): maximise Σ ∫_0^{u_t} P_t — the competitive outcome of legs priced at opportunity
    cost and cleared by the market (the schedule is then price-taker optimal at the prices it causes); "revenue" =
    Σ P_t(u_t) u_t, the impact-aware (volume-reducing) schedule.
    DP on an energy grid; u restricted to moves between grid points (exact on the grid).
    """
    T = len(rds)
    if de is not None:  # energy step that divides the power limits (so full-power moves are representable)
        E = np.arange(0.0, e_cap + de / 2, de)
        n_e = len(E)
    else:
        E = np.linspace(0.0, e_cap, n_e)
    Vn = value_end * E
    pol = np.zeros((T, n_e), dtype=np.int32)
    for t in range(T - 1, -1, -1):
        rd = rds[t]
        V = np.full(n_e, -1e18)
        for a in range(n_e):
            # move from E[a] to E[b]
            dE = E[a] - E  # >0 discharge energy, <0 charge energy (stored)
            u = np.where(dE >= 0, dE, dE / eta)  # grid injection (charge draws more than stored)
            ok = (u <= p_max_dis + 1e-9) & (-u <= p_max_ch + 1e-9)
            if impact and objective == "welfare":   # competitive dispatch: every MW at its own marginal price
                gain = rd.area(u)
            else:
                pr = rd.P(u) if impact else np.full_like(u, rd.P(0.0) if pt_prices is None else pt_prices[t])
                gain = pr * u
            val = gain - var_cost * np.maximum(u, 0.0) + Vn
            val = np.where(ok, val, -1e18)
            b = int(np.argmax(val))
            V[a] = val[b]
            pol[t, a] = b
        Vn = V
    a = int(np.argmin(np.abs(E - e0)))
    obj = float(Vn[a])
    path = [E[a]]
    us = []
    for t in range(T):
        b = pol[t, a]
        dE = E[a] - E[b]
        us.append(dE if dE >= 0 else dE / eta)
        a = b
        path.append(E[a])
    return np.array(us), np.array(path), obj


def energy_value(rds, u, var_cost=0.0, prices=None):
    """Profit of a fixed schedule u: at each curve's P_t(u_t) (impact) or at given prices (price-taker)."""
    if prices is None:
        pr = np.array([rd.P(x) for rd, x in zip(rds, u)])
    else:
        pr = np.asarray(prices, float)
    return float((pr * u - var_cost * np.maximum(u, 0.0)).sum())


# ---------------------------------------------------------------------------------------------------------------
# day-block bootstrap


def block_bootstrap_ci(values_by_day, n=10000, alpha=0.10, seed=12345):
    """Mean over days and its percentile interval resampling whole days (each day = one block)."""
    v = np.asarray(values_by_day, float)
    rng = np.random.default_rng(seed)
    bs = v[rng.integers(0, len(v), size=(n, len(v)))].mean(1)
    return float(v.mean()), float(np.quantile(bs, alpha / 2)), float(np.quantile(bs, 1 - alpha / 2))
