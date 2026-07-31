# cv30 — export capability, surplus floor, and the decision trace: pre-registration

**Gates frozen by this merge.** Inherited windows/gates from the cv27-borders
program (its screening protocol IS the template); baseline = cv27 main.
Headline validation target (owner, 2026-07-31): **GR summer-2026 midday hours
must clear ≤ €5** (measured episode: settled 0.0 for 6-7 h/day, 30-31/07 +
01/08, while the model held 96-133 by staying coupled to BG over a 1,000 MW
offered ATC whose real DA exchange saturated at ~245 MW).

## T1 — demonstrated EXPORT capability (per-border program, cv27 recipe reversed)

- **Selection rule (price-based, frozen):** candidate directed borders A>B
  where, on trailing-year hours, settled prices DECOUPLED (|P_A − P_B| > €5)
  while observed flow < 50% of offered DA ATC — the signature of nominal ATC
  overstating the DA-allocatable capacity — ranked by episode count. The
  static midday survey (2026-07-31) flags IT-CSOUTH>IT-SOUTH (3.9×), BG>GR
  (2.4×), RO>BG (2.2×), IT-SOUTH>IT-Calabria (2.0×); GR>BG enters via the
  conditional rule.
- **Lever:** cap the border's model capacity at the demonstrated p95-block
  exchange (the `_fbmc_capability` machinery, applied as a CEILING on borders
  WITH Day-ahead rows — the mirror of cv27, which fills borders WITHOUT them).
- **Protocol:** per-border screening with both directions tied, endpoint +
  neighbour + aggregate gates exactly as cv27-borders; accepted set →
  combination Set A → Set B once.

## T2 — surplus price-taker floor (third redesign, both measured defects fixed)

- **Signal (import/export-aware):** hour is in surplus when
  `price_taker_mw ≥ load + demonstrated_export_capability` (the T1 quantity —
  a zone is only truly long when it cannot export the excess). Fires the
  price-taker block (RES, RoR, deep must-run) at the declared −20 floor.
  Falsifiers: phantom rate ≤2% (cv28: 18%, cv29: 16.4% — both from
  export-blind signals), SE1/SE2 untouched, hit-rate reported.
- **T3 — self-scheduling reallocation:** the cv29-T3 haircut shares
  (Sardinia 0.5, IT-CSOUTH 0.62, IT-CNORTH/Sicily 0.7) MOVE that share of
  unit offers INTO the price-taker block instead of deleting it (cv29 measured
  deletion = phantom scarcity, +7.45 MAE).

## T4 — cloud-cover feature for weather-RES (input side, separate validation)

`cloud_cover` (already in the ETL since infra#9) enters the solar feature
vector; validated on the forecast track (weather-track GR/ES solar MAE), not
the record gates. The 2026-07-30/31 episode: ENTSO-E fc 139% cover vs actual
112% — clear-sky level bias is real but was NOT the decisive error.

## The decision trace (engineering deliverable, price-inert)

Every book order gains a STRATEGY tag at capture: which pricing branch
produced it (srmc_tranche_k / water_value(model, dryness, norm_demand) /
must_run_deep / res_price_taker / import_injection / backstop / boundary_book
/ export_capability_ceiling) plus the branch's key inputs. Per (zone, hour)
the capture also records: clearing price, the MARGINAL order's tag, each
border's flow vs its limit (binding or not), and the boundary-book
assumptions in effect (TR/UK/UA books). Deliverable: the per-day book parquet
gains `strategy` and `inputs` columns + a per-zone-hour `trace` JSON — the
"plant X offers Y at P with strategy S because C" and "country reaches level
L, cables bind at Z, TR/UA assumed W" narratives the owner specified, feeding
the site's book visualization. GUARD: capture-side only — prices bit-identical
with tracing on/off.

**Protocol:** switches `EUPHEMIA_DISABLE_CV30` + `_T1.._T4`; all-off guard
bit-identical to cv27 main; per-cell harness; screening → combination → Set B;
non-draft PR with results; owner decides. cv→30 on the activating branch only
(29/28 stay reserved for their measured no-ships).
