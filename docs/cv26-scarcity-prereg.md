# cv26 — evening scarcity form, pre-registration

**Status: DRAFT, awaiting the owner's ratification. No scored arm runs until
this is merged.** Windows, gates, tie-break, envelope and the Set-A/Set-B
discipline are inherited unchanged from the ratified `docs/cv25-phase2-prereg.md`
(Set A calibrates, Set B is scored once for the accept decision). The claim
served is #227: parameters are nameable market characteristics on ex-ante data,
validated out-of-sample.

## The measured problem this targets

Two independent measurements point at the same missing form:

1. **GR Set-B evening diagnosis (2026-07-30, from the Phase-4 cells):** on
   non-cap days the model's evening bias is **−35 to −48 €/MWh at 17:00–18:00
   UTC** while the settled evening price has stdev **128–143 €/MWh** (vs ~30
   daytime) — the book's compressed near-peak ladder cannot produce the fat
   evening tail the real market prices. The Phase-4 T1 backstop, correct for
   killing winter phantom-scarcity caps, adds elastic supply at 1.8×SRMC and
   *shaves this genuine ramp further* (GR B corr 0.739→0.691, the measured
   owner's-call flag in `docs/experiments/cv25-phase4-recal.md`).
2. **The footprint evening residual** (`docs/experiments/zone-diagnoses-2026-07.md`):
   roughly half of each SEE zone's evening error is imported through the
   coupling — the cv18 lesson says this cannot be fixed one zone at a time and
   re-points at the peak-scarcity **form**, validated on the coupled footprint.

## T1 — hyperbolic scarcity tail (form change, footprint-wide)

- **Current form** (`book_build.jl`): multiplicative markup on the upper supply
  tranches, `scarcity = 1 + κ_s·max(0, θ − margin)² + κ_p·norm_demand^p`. The
  quadratic term is bounded and gentle until margin is deep below θ; the real
  evening tail is convex far earlier.
- **Lever:** replace the quadratic scarcity term with a hyperbolic one,
  `κ_s·max(0, θ − margin)² → κ_h·(θ − margin)/(margin − m₀)` for
  `m₀ < margin < θ` (capped at the existing price ceiling; the peak term and
  every credit — import ATC, backstop — enter `margin` exactly as today). ONE
  new profile parameter (`m₀`, the asymptote margin); `κ_h` is set by
  continuity with the current form at a fixed reference margin, NOT fitted per
  zone. Form applies footprint-wide; zones keep their existing `θ`/κ profile
  values.
- **Market characteristic:** the observed **convexity of near-peak pricing** —
  bidders price their last tranches against effective residual capacity with a
  hyperbolic, not quadratic, tail (the standard peak-load-pricing/LOLP-adjacent
  shape). It is a property of how scarcity is priced, not of any one zone.
- **Expected direction:** GR/SEE evening bias at 16:00–21:00 UTC shrinks
  toward 0 without new cap hours; the Phase-4 flags (GR B corr −0.048, RO
  neighbour corr −0.026) reverse sign; daytime hours (untouched margins) move
  ≤ noise.
- **Falsifiers:** any new cap hour (≥ €2,999) in any zone vs the cv25 baseline;
  any zone breaching the inherited envelope (neighbour MAE +1.0 / corr −0.02,
  any zone +3.0 / −0.05); GR evening (16–21 UTC) MAE not improving on Set A;
  the Set-A verdict not surviving Set B. Per the cv18 rule, the arms run on the
  **full coupled 39-zone footprint** — no 2-zone pilots; a coupled regression
  anywhere is a finding, not noise.

## Deliberately out of scope

- The midday negative-price gap (NL/IT-NORTH/PL solar troughs) — a separate
  book-form capability (deep-surplus pricing), its own future prereg.
- Conduct residuals (PL import premium, IT-NORTH GME cap tail) — measured, not
  reproduced (`zone-diagnoses-2026-07.md`).
- Any per-zone retuning of `θ`, κ's, anchors or backstops in the same arms —
  the form change must stand alone (delete-before-adding discipline).

## Protocol

1. Implement behind `EUPHEMIA_DISABLE_CV26` (house isempty style); all-off must
   be bit-identical to main (guard: GR single-zone + 39-zone EU day).
2. Arms on the ratified Set-A windows, full footprint: `cv25` (baseline),
   `hyper` (the form). Leave-one-out is trivial here (one treatment); the two
   arms ARE the ablation.
3. Score per the inherited gates (scored-cell counts beside every figure,
   evening-window sub-scores 16–21 UTC reported per zone); Set B once, only if
   Set A passes.
4. Report both; the ship/backfill decision is the owner's. cv bumps to 26 on
   the activating branch only.

**Ratification: merging this file. Amendments before the run, in the open.**
