# "Bring your own power" by technology (cv44, Nov 2026, stride-16 sample)

Question (owner): would a different technology neutralise the GR data center
(+574 MW flat) at a different share than the merchant CCGT's s\* ≈ 193 %?

**Setup.**
- cv44 (PS energy-limited complex orders on), extract 2026-11-14 read-only, HiGHS.
- Driver `eu44_tech.jl`, ledger `scn_tech.py`, profiles `build_tech_profiles.py`, flex hours `build_flex_hours.py`.
- Each arm = DC + a GR plant sized by annual energy e relative to the DC's 5.03 TWh/yr.
- Paired with the cv44 `eu44_base` / `eu44_dc574` / `eu44_byop_s*` arms of `eu44_scenarios.jl` (same code and extract ⇒ deterministic; a one-day re-clear matches, max |Δp| = 0).
- **Coverage:** 44 complete common days (every 16th day of 2024-07-01..2026-06-30, minus two 38-zone days), 1,056 GR hours per arm, 39 zones.
- € = sample sums; ×16 gives the window.

**Arms**
- **PV / wind:** GR actual CF profile (actual / trailing-365-day max), offered at −0.01 €/MWh.
- **Firm:** 574 MW at 10 €/MWh every hour.
- **Battery:** 574 MW / 2,296 MWh.
  - Discharge = a `LinkedHourlyOrder` family allocated by the complex-order master. `extra_orders` may now return such members; they skip the merge.
  - Charging = 2,296/0.88 MWh of fixed load in the top-PV hours.
- **Reservoir:** 574 MW family, daily budget at 30 % CF.
- **dc_flex10:** DC off in the 9.7 % of hours above a trailing 90th-percentile price threshold of the DC arm.

| arm | nameplate MW | GR LW Δ | EU LW Δ | others' cost €m (sample) | capture €/MWh | GR Δ 17-21 local | GR Δ 11-15 local |
|---|---|---|---|---|---|---|---|
| DC only | — | +6.35 | +0.282 | +90.6 | — | +8.68 | +5.57 |
| firm e100 | 638 | −0.04 | +0.006 | +1.8 | 101 | −0.03 | +0.06 |
| PV e100 / e200 | 2,766 / 5,533 | −1.57 / −9.60 | +0.033 / −0.163 | +10.7 / −52.3 | 40 / 23 | +6.59 / +3.00 | −14.1 / −32.2 |
| wind e100 / e200 | 1,591 / 3,183 | −1.39 / −10.40 | −0.007 / −0.292 | −2.4 / −93.9 | 83 / 69 | +0.16 / −11.64 | −2.5 / −9.4 |
| PV e100 + wind e100 | 4,358 | −9.73 | −0.250 | −80.5 | 55 | −3.09 | −21.8 |
| PV e100 + 4 h battery | 2,766 + 574 MW / 2,296 MWh | −2.21 | −0.042 | −13.7 | 60 | −1.07 | −7.2 |
| reservoir e30 | 574 | +3.36 | +0.137 | +44.0 | 133 | +0.55 | +5.55 |
| DC flex (top 10 % h) | — | +4.95 | +0.214 | +68.8 | — | +3.17 | +5.58 |
| CCGT s100 / s150 / s200 | 638 / 957 / 1,276 | +2.75 / +1.19 / −0.41 | +0.101 / +0.029 / −0.037 | +32.4 / +9.4 / −11.9 | 112 / 110 / 109 | +0.28 / −3.29 / −7.37 | +5.3 / +5.2 / +5.1 |

**Crossing points (GR LW Δ = 0, linear):**
- PV e\* ≈ 80 %, wind e\* ≈ 82 % of the DC's energy.
- CCGT s\* ≈ 187 % on these days, i.e. ≈ 115 % of the DC's energy actually generated.
- The EU-wide cost crosses later for PV (≈ e117 %): PV leaves the evening peak and the RO/RS spill in place. A 4-hour battery removes them.

**Mechanism:**
- PV cannibalises midday (r = −0.58 with the DC-arm price; capture 40 → 23 €/MWh).
- Wind is uncorrelated with price (r = −0.04).
- Energy-limited resources placed in the top hours (battery, reservoir, DC flex) act most per MWh.

**Caveats:**
- Battery and reservoir are approximations: no SoC coupling, fixed charging, no inter-day carry-over. The model has no pumping demand.
- No new network.
- New RES bids below the fleet RES (1 €/MWh) and is never curtailed, because GR never clears below 1 €/MWh. It displaces existing RES in 118 (PV e100) to 191 (PV e200) floor hours, against 43 with the DC alone.
- Nameplates use a proxy CF.

Full write-up: em-team `reports/tsfm-p3-techmix.md`.
