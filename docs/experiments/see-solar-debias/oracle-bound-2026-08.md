# Solar-input oracle bound — cartography charter (declared 2026-08-08, before the run)

**Purpose.** The debias family concluded that discriminating false from true
collapse needs a weather-conditioned solar input (the ML models) on the
record path — an owner-level track decision. This run measures what that
decision is worth: the **upper bound** of record-path improvement from a
perfect solar input.

**NOT ex-ante, by construction.** The treatment replaces each zone-hour's
D-1 solar forecast with the REALIZED solar (`aggregated_generation_per_type`
actuals) via the first-class `renewable_modifier` hook, footprint-wide.
This is an oracle: it can never ship, never enters any record or track, and
its label (`solar_oracle_fy`) is excluded from every product query. Its only
output is the attribution table.

**Arms.** Baseline = `trmk_base_fy` (cv31, 2025-08-01..2026-07-31, the
epias-patched extract). Treatment = same everything + oracle solar deltas
(mw → max(mw − (fc_solar − act_solar), 0) per zone-hour, all 39 zones).

**Readout (no gates — cartography):** per-zone year ΔMAE/Δcorr = the solar
share of each zone's error; false-collapse counts GR/BG/RO; collapse hit /
false-alarm at the ≤€5 threshold (the first-class question under a perfect
input); the degenerate-flip interpretation guard applies to single-month
outliers. The follow-on question — how much of this bound the ML solar
captures — is measurable on the windows where weather-track vintages exist.
