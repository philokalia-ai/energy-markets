# DK1 & SE3 — hour-of-day residual characterization (loop, July 2026)

Full-record hour-of-day residual profiles (actual − sim, cv17 `eu17_base`):

## DK1 — an AMPLITUDE problem (the Italy family, half-strength)

Actual swings 46→117 €/MWh across the day (Δ71); the sim swings 65→94 (Δ29).
Residual profile: **−19 at the solar valley (h12), +23 at the evening peak
(h17)** — the sim neither dips enough in RES-surplus hours (DK1 is wind-heavy;
net load goes deeply negative) nor rises enough at the peak. Same mechanism
family as the IT flat line (uniform-SRMC thermal steps + climatology-flat
imports), at ~50 % strength. Candidates: per-unit efficiency spread (now
validated on IT-CSOUTH: corr 0.31→0.68) + RES-surplus pricing below the gas
band. DK1 shape ratio 0.64 → expect meaningful gains from the same cv18 pair.

## SE3 — a LEVEL problem (night-heavy water-value overpricing)

The sim tracks the shape (ratio 0.99) but sits ~24–41 € ABOVE settled around
the clock, with the gap **largest at night (−39…−41) and smallest at the peak
(−21)**: the Swedish hydro water value is priced too high, most of all in
off-peak hours (act 24–27 at night vs sim 62–66). This is the known Nordic
water-value open problem, now characterized precisely: it is not shape, not
imports — it is the **night-time hydro offer floor**. A `water_value_base` /
off-peak-discount recalibration for SE3 (reservoir-opportunity model) is the
right cv18 lever; the strategic layer is explicitly NOT implicated.
