"""Synthetic-curve tests for rdopt (run: python -I test_rdopt.py from this directory's parent via path arg)."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import numpy as np  # noqa: E402

import rdopt as R  # noqa: E402

PG = np.linspace(-50.0, 400.0, 451)  # 1 €/MWh price grid


def linear_rd(a, b, shift_q=0.0):
    """Inverse demand P(q) = a - b q  <=>  D(p) = (a - p)/b (+ shift)."""
    return R.ResidualDemand(PG, (a - PG) / b + shift_q)


def approx(x, y, tol):
    assert abs(x - y) <= tol, (x, y, tol)


def test_inverse_roundtrip():
    q = np.linspace(-2000, 2000, 41)
    price = 120 - 0.03 * q
    rd = R.ResidualDemand.from_injection_curve(q, price, PG)
    for qq in (-1500, 0.0, 800.0):
        approx(rd.P(qq), 120 - 0.03 * qq, 1e-6)
    approx(rd.D(90.0), 1000.0, 1e-6)


def test_cournot_linear():
    a, b, c = 200.0, 0.05, 80.0  # €/MWh, €/MWh per MW
    rd = linear_rd(a, b)
    cost = R.StepCost([5000.0], [c])
    q, p, pi = R.cournot(rd, cost, n_q=5001)
    approx(q, (a - c) / (2 * b), 2.0)  # 1200 MW
    approx(p, (a + c) / 2, 0.1)
    tp, tpr, tq = R.truthful(rd, cost)
    approx(tpr, c, 1e-6)
    approx(tq, (a - c) / b, 1e-6)
    approx(tp, 0.0, 1e-3)
    # capacity binds: S below the Cournot quantity -> sell S, truthful = Cournot
    small = R.StepCost([500.0], [c])
    q, p, pi = R.cournot(rd, small)
    approx(q, 500.0, 1e-9)
    t = R.truthful(rd, small)
    approx(t[0], pi, 1e-6)


def test_clear_offer_bruteforce():
    rng = np.random.default_rng(1)
    # stepwise residual demand (a merit order of others)
    rd = R.ResidualDemand(PG, np.clip(3000 - 12 * np.floor(PG / 10) * 10, 0, None))
    for _ in range(200):
        x = np.maximum.accumulate(rng.uniform(0, 3000, len(PG)) * (rng.uniform(size=len(PG)) < 0.05))
        p, q = R.clear_offer(rd, x)
        # brute force on a very fine price grid: crossing where x(p) >= D(p) first
        fine = np.linspace(PG[0], PG[-1], 45001)
        xf = x[np.clip(np.searchsorted(PG, fine, side="right") - 1, 0, None)]
        df = rd.D(fine)
        k = np.nonzero(xf >= df - 1e-9)[0]
        if len(k) == 0:
            continue
        pf = fine[k[0]]
        assert abs(p - pf) <= 0.02 + 1e-9 or abs(q - df[k[0]]) < 1.0, (p, pf, q, df[k[0]])


def test_dp_single_scenario_equals_cournot():
    a, b, c = 200.0, 0.05, 80.0
    rd = linear_rd(a, b)
    cost = R.StepCost([3000.0], [c])
    x, ev = R.optimal_offer([rd], [1.0], cost, n_q=301)
    _, _, pi = R.cournot(rd, cost, n_q=5001)
    approx(ev, pi, 0.002 * pi)
    # realised on the curve
    pr, p, q = R.offer_profit(rd, x, cost)
    approx(pr, ev, 1e-6 * pi + 1e-6)


def test_dp_supply_function_linear_shocks():
    """Monopolist, linear demand with additive quantity shocks, constant mc: the ex-post optimal points lie on
    x(p) = (p - c)/b (Klemperer-Meyer); the DP curve must capture ~all of the ex-post optimum expectation and beat
    the forecast-only (Cournot-at-mean) offer."""
    a, b, c = 200.0, 0.05, 80.0
    shocks = np.linspace(-600, 600, 25)
    scen = [linear_rd(a, b, s) for s in shocks]
    w = np.full(len(scen), 1 / len(scen))
    cost = R.StepCost([4000.0], [c])
    x, ev = R.optimal_offer(scen, w, cost, n_q=201)
    expost = np.mean([R.cournot(s, cost, n_q=4001)[2] for s in scen])
    assert ev >= 0.995 * expost, (ev, expost)
    x1, _ = R.optimal_offer([linear_rd(a, b)], [1.0], cost, n_q=201)
    ev1 = R.expected_profit(scen, w, x1, cost)
    assert ev > ev1, (ev, ev1)
    # the cleared points (only those are pinned by a step offer) lie on x(p) = (p - c)/b
    for s in scen:
        p, q = R.clear_offer(s, x)
        approx(q, (p - c) / b, 0.03 * 4000)


def test_dp_tiebreak_stays_truthful_off_crossing():
    """Small portfolio facing a flat (price-taking) curve: the optimum is truthful, and the DP curve must equal the
    truthful offer at every price (not only at the forecast crossing)."""
    rd = linear_rd(150.0, 1e-5)
    cost = R.StepCost([50.0, 50.0], [80.0, 120.0])
    x, _ = R.optimal_offer([rd], [1.0], cost, n_q=101)
    t = cost.truthful_offer(PG)
    assert np.max(np.abs(x - t)) <= 1.0 + 1e-9, np.max(np.abs(x - t))


def test_markup_and_withhold_arms():
    a, b, c = 200.0, 0.05, 80.0
    rd = linear_rd(a, b)
    cost = R.StepCost([1000.0, 1000.0], [c, c + 20])
    t = R.truthful(rd, cost)[0]
    best = max(R.offer_profit(rd, R.markup_offer(PG, cost, m), cost)[0] for m in np.linspace(0, 1, 101))
    assert best >= t
    w = max(R.offer_profit(rd, R.withhold_offer(PG, cost, q), cost)[0] for q in np.linspace(0, 2000, 201))
    assert w >= t


def test_energy_dp_storage():
    # two-price day, 100 MW / 200 MWh battery, eta 0.88: price-taker charges cheap hours, sells dear hours
    T = 24
    base = np.where((np.arange(T) >= 17) & (np.arange(T) <= 20), 180.0, 60.0)
    base[2:6] = 20.0
    rds_pt = [linear_rd(bp, 1e-6) for bp in base]  # flat (price-taker)
    u, e, obj = R.energy_dp(rds_pt, 0.0, 200.0, 100.0, 100.0, 0.88, 0.0, n_e=41)
    assert u[17:21].sum() > 190 and u[2:6].sum() < -200, (u.round(1))
    approx(obj, 200 * 180 - 200 / 0.88 * 20, 1.0)
    # with price impact (steep curves) the strategic schedule trades less and earns more than the price-taker
    # schedule evaluated on the same steep curves
    rds = [linear_rd(bp, 0.4) for bp in base]
    us, _, objs = R.energy_dp(rds, 0.0, 200.0, 100.0, 100.0, 0.88, 0.0, n_e=81)
    pt_on_steep = R.energy_value(rds, u)
    assert objs >= pt_on_steep - 1e-6 and abs(us).max() < abs(u).max(), (objs, pt_on_steep, us.round(1))  # spreads volume


def test_bootstrap():
    m, lo, hi = R.block_bootstrap_ci(np.arange(12.0))
    assert lo < m < hi


if __name__ == "__main__":
    for name, f in list(globals().items()):
        if name.startswith("test_"):
            f()
            print("ok", name)
