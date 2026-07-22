# Analogue flows — temperature-aware ex-ante flow rule (via load similarity)

## Problem

The D-1 price forecast systematically overshot GR/BG/RO/RS evenings in July
2026: +58 to +103 €/MWh at 20:00–23:00 local, on 90–100% of 16 realized days.
Diagnosis (2026-07-22, this session):

- Load and RES inputs were near-perfect (evening load fcst 7679 vs actual
  7563 MW; RES 744 vs 743 MW). **Not a load problem at D-1.**
- The `:v2` flow climatology (median of same-weekday D-7..D-56) assumed GR
  **exports** 430–990 MW in the evening — because May–June it did. From early
  July the SEE region flipped (heatwave): BG −261→+374, MK −310→+227,
  TR −98→+127 MW average evening flow. Realized GR evenings: +500…+1500 MW
  **imports**. The 8-week median needs ≥5/8 weeks in the new regime to flip —
  it lags every seasonal turn by ~a month.
- The missing 1–2 GW of evening supply (on a 7.6 GW load) fires the scarcity/
  peak markup: sim ≈ 2.4× gas SRMC (241 €/MWh) vs actual ≈ 1.4× (133–146).

The physical driver is the tropical-night AC response (measured on GR: night
load slope 195 MW/°C below 25 °C, 354 MW/°C above; ~2.5 GW range) — but the
TSO's D-1 load forecast already carries it (forecast error flat in
temperature, corr 0.04). It reaches our model through the **neighbors'
balances**, i.e. the flow assumption.

## Idea

Replace the calendar analogue ("same weekday, last 8 weeks") with a
**thermal-regime analogue**: pick the historical days whose realized 24 h load
vector is closest to the delivery day's published D-1 load forecast vector,
and take the per-(border, hour) median of *those* days' flows. Load is the
ex-ante thermometer — it is a monotone function of temperature, embeds
weekday/holiday/tourism structure, is published before the auction, and
exists for all 39 zones (the weather DB covers GR cities only). A heatwave
week then finds last summer's analogue days instead of dragging this spring's
calendar median.

## Stage 1 — flow-rule benchmark (`eval_flow_rules.py`)

The rule's proximate target is observable (realized flows), so rules are
compared on flow MAE directly, before any market-model run. All rules are
strictly ex-ante (candidates ≤ D-2). Evaluated 2024-07..2026-07 across the
39-zone footprint, overall / evenings / July-2026 (the SEE flip window).

Rules: `v2` (shipped), `rec3` (median D-7/14/21), `ana8`/`ana16` (load
analogues), `ana8b`/`ana16b` (50/50 blend with v2).

Results: `results_flow_rules.tsv` (net-import MAE per zone × rule × period),
`results_flow_rules_borders.tsv` (per-border MAE).

**Stage-1 verdict (measured, footprint-mean hourly net-import MAE in MW):**

| period | v2 (shipped) | rec3 | ana16 (pure) | **ana16b (blend)** |
|---|---|---|---|---|
| all (2024-07..2026-07) | 458.7 | 458.5 | 438.5 | **413.1** |
| evenings (17–20 UTC) | 444.6 | 440.3 | 422.6 | **401.0** |
| July-2026 flip evenings | 494.4 | 468.2 | 456.2 | **451.8** |

The 50/50 blend of analogue(K=16) with the :v2 value wins every composite,
including the Nordic zones (DK1 jul26-evening 1065→804, SE2 484→381) — so no
class scoping is needed; the earlier apparent Nordic analogue blow-up was an
artifact of sub-hour aggregation in the first evaluator run (fixed to
MW-level hourly means). GR jul26 evenings: 589→494 (pure analogue 416).

Smoke test of the shipped `:v3` (GR 2026-07-21): the analogue selector picked
10/16 days from late July 2025 — last summer's heatwave found automatically —
and moved the assumed evening balance from −366..−1096 (v2) to −189..−473,
about halfway to the realized +928..+1240. The blend halves the regime error
by construction; the price A/B decides whether that is enough.

## Stage 2 — coupled price A/B (planned gates)

Per the cv18 methodological rule, the mechanism is validated on the **full
coupled 39-zone footprint from day one** — no isolated-zone pilots:

1. Implement the winning rule as `FLOW_ASOF_MODE = :v3` (env
   `EUPHEMIA_FLOW_ASOF_MODE=v3`), default untouched — `:v2` paths byte-identical.
2. A/B on coupled clears: July 2026 (in-sample for the diagnosis), plus
   held-out windows (June 2026, summer 2025 transition, one winter month).
3. Gates: (a) GR/SEE evening bias collapses materially; (b) no zone's
   corr/MAE degrades beyond noise on the held-out windows; (c) the SEE
   byte-identity suite for non-EU paths stays green.
4. Ship: flip the daily-forecast default to `:v3`, cv bump (next free version
   — 18 is RESERVED for the shape levers per the ledger), backfill, Metabase.

## Related / follow-ups

- The tropical-night kink (25 °C threshold, 354 MW/°C) belongs in the D-n
  load model for leads 2–7 (weather track), where we forecast load ourselves.
- The cv17 `import_backstop` remains the complementary mechanism for
  quantity-limited import starvation; this experiment fixes the *directional*
  assumption feeding both the injections and the backstop headroom.
