# Strategic layer roadmap — firm strategies for all of Europe

**Goal.** Extend the GR strategic-bidding finding into a European **strategic
counterfactual**: per zone and firm, a calibrated, regime-gated bidding
strategy layered on the competitive model — with (a) an improved fit across
Europe, (b) an explicit, per-zone *exercised-markup wedge* between the
competitive and strategic counterfactuals, and (c) a public per-timeslot view
of the computed bid ladders with market-state and per-firm strategy commentary.

The product framing matters: we do NOT fold strategy into the competitive
model. The competitive counterfactual stays untouched (it is the measuring
stick); the strategic layer is a second, separately-labeled reconstruction.
**The wedge between the two is the market-power estimate** — the deliverable,
not a nuisance.

## Phases and gates

### Phase 0 — Unit-level dispatch evidence (GR) ✅ *(this PR)*

Fit-equivalence showed the settled prices support ~one portfolio of markup but
cannot identify the firm. The discriminating evidence is **dispatch**: capacity
that was in the money at the settled price but did not produce. Per thermal
unit: `shortfall(h) = max(0, p95₃₀d − output(h))` in hours with
`settled > 1.15 × SRMC(fuel, day)`; aggregate per firm; compare the 60
medium-fit days against a good-fit control set; correlate with the daily
residual. Gate: a firm-differential shortfall pattern on residual days = named
attribution; no differential = the markup stays unattributed ("the market's
flexible margin").

### Phase A — Firm maps beyond SEE (the data prerequisite)

`simulations.unit_firms` covers 5 SEE zones (480 rows). Wave 1 adds the big
price-setting fleets by capacity-ranked name rules (the BG "name-rule v1"
precedent, `source` tag preserved, verify-before-publication):

- **DE_LU** (RWE, LEAG, EnBW, Uniper, Vattenfall, Iqony/STEAG, municipal),
  **FR** (EDF ≈ all nuclear + most hydro; Engie, TotalEnergies CCGT),
  **ES** (Endesa, Iberdrola, Naturgy, EDP), **IT zones** (Enel, Edison, A2A,
  EPH, Eni, Tirreno Power, Sorgenia).
- Gate per zone: ≥70 % of *thermal + hydro* registry MW mapped before the zone
  enters Phase B. Coverage report committed alongside the rules.
- Wave 2 (as needed): NL/BE/AT/CZ/PL/PT + Nordics (statkraft/vattenfall/fortum).

### Phase B — Per-zone strategy calibration (the GR protocol, industrialized)

For each zone with a usable firm map, rerun the exact GR discipline — no
shortcuts, every step is a gate:

1. **Day selection** from the cv17 coupled baseline (`eu17_base` labels):
   medium-corr band per zone, split into a 60-day calibration set and a
   held-out remainder.
2. **Residual-sign gate**: only positive-residual regimes are eligible for a
   markup layer (negative-residual zones are model problems, not strategy
   targets — BG/RO/RS today).
3. **Strategy fit**: the winning GR mechanism (near-uniform markup on committed
   units' dispatchable range, per-firm rates via `strat_tiered_markup.jl`)
   plus the zone's own regime gate (ex-ante tightness signal — scarcity
   margin / net-load percentile — NOT realized fit).
4. **Acceptance gates** (all three, or the zone ships without a strategic
   layer): beats the post-hoc additive level-shift null **on the held-out
   set**; raises held-out daily-corr; consistent on >60 % of held-out days.
5. Output: a data record `strategy_calibrations` (zone, firm set, rate,
   regime gate, gates passed, day sets) — code-free, auditable.

### Phase C — The EU strategic counterfactual

Coupled 39-zone run with every calibrated zone's strategic layer active
(ZoneScenario strategist per zone), labeled e.g. `eu_strategic_v1` next to the
competitive `eu17_base`. Deliverables: per-zone MAE/corr/bias both ways, the
**wedge time series** (strategic − competitive per zone-hour = exercised-markup
estimate), and the honesty rule: zones that failed Phase B gates run
competitive-only. If this ever writes product tables it is a model change →
**cv18+** with the full backfill discipline; until then, offline labels only.

### Phase D — Per-timeslot bids view with commentary

The public artifact. For zone × day × timeslot:

- **Data contract** (parquet via the existing R2 export): the tagged order
  ladder aggregated to (firm, price-band, MW) steps — competitive and
  strategic variants — plus clearing price, marginal tranche owner, scarcity
  factor, net-import level, RES share.
- **UI**: firm-colored supply-curve view with the demand line and both
  clearing points; slider over the 24/96 slots; the wedge highlighted.
- **Commentary**: rule-based text from the book metrics, two sentences per
  slot: *market state* ("tight evening ramp, imports at ATC limit, RES 12 %")
  and *per-firm strategy* ("PPC running units bid ≈ +25 % over cost — regime
  gate active; fringe at cost"). Grounded in computed fields only — no
  free-form generation, every phrase traceable to a number.
- Publication honesty: computed bids are model reconstructions, labeled as
  such; real bids are confidential and never claimed.

## Sequencing

Phase 0 and A are independent and run now. B needs A per zone; C needs ≥3-4
calibrated zones to be interesting; D needs C's labels plus an export/UI
iteration. Realistic cadence: 0+A(wave 1) in this PR; B pilots next; C+D as
their own PRs with their own review gates (this experiment's review→correction
cycle is the template).
