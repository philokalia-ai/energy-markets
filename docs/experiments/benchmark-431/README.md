# Offline forecast benchmark contract (#431)

This pack compares saved predictions with available naive baselines on explicit
common cells. It changes no scorer, exporter, model, workflow, database, public
number or default. It does not fit models. Clearing remains cv44. Lower forecast
error is evidence about these saved cohorts, not a verdict about market conduct.

The [results](outputs/RESULTS.md) distinguish newly computed benchmarks from
historical summaries whose raw forecasts are unavailable. All numerical tables
are scoped by target, lead, mask, aggregation and publication class. A sparse
model never changes an existing model-versus-naive comparison.

## Contract and inputs

[manifest-example.json](manifest-example.json) fixes the source hashes, target
policy/helper hash, hourly resolution, market-day timezone, model/artifact/base
cv, fit end, information/publication class, window, missingness, aggregation and
mask hashes. Unknown artifact hashes or fit ends are **null with a reason**;
these are missing provenance, not independently validated forecast vintages.
Prepared manifests and output hashes are committed under `outputs/`.

The pure evaluator accepts CSV or parquet:

- Actual history: `zone,t,actual`, one row per zone and UTC hour. Include at
  least seven prior market days. Optional `available_utc` means authenticated
  source availability; if provided, unknown/late stamps fail closed against
  each forecast's `issue_utc`. An ETL revision stamp is not that evidence.
- Saved forecasts: `zone,t,model,lead,prediction`. Optional `eligible` is an
  explicit cohort mask; optional `issue_utc` supports authenticated input
  availability. Missing values stay missing. Duplicate keys and native-quarter
  input fail rather than being silently pooled with hourly data.
- Dates are the site's **Europe/Athens market days**; UTC keys remain unique
  through DST. This is not necessarily an exchange's auction-day convention.

Source files are opened read-only and never modified. SHA256 checks reject
changed prepared inputs. Each comparison's `mask_sha256` hashes sorted
`zone\tUTC-hour-ISO\tlead\n` keys, with a separate complete-day hash. The root
manifest pins the mask-index CSV; output hashes also pin metrics, exclusions and
DM. `--save-masks` optionally writes the exact keys to a separate directory.
Exclusion counts by zone/reason can overlap; `excluded_union=expected-n` is the
non-overlapping total. Expected cells include missing forecast rows. Optional all-model masks intersect
final admissible pairwise masks per lead and naive, including model-specific
issue-time availability; all participating models then share identical keys.

## Two targets; no silent retarget

`targets.py` imports the canonical `bin/da_target.py` API merged in #440
(`e758b93`); there is no docs-local fallback. The manifest pins that helper's
path and hash. The former API port (b70636b) was checked against all prepared
actuals: 840,153 highest-sequence and840,129 SDAC hours, with identical keys and
zero price differences ([parity audit](outputs/target-helper-parity.csv)).
Regeneration with the merged helper preserves all targets and scores.

- **highest_seq** reproduces the current legacy target: highest numeric auction
  sequence per interval, latest revision tie-break, then hourly mean. This
  selects EXAA sequence2 for AT/DE_LU, and DK copies where present.
- **sdac** explicitly selects AT/DE_LU sequence1 and DK1/DK2's blank sequence;
  other single-auction zones retain their series. Unknown multi-auction zones
  fail closed and are listed. Revisions are deduplicated within the chosen
  auction/resolution; each hour uses one fully covering resolution and a
  duration-weighted mean. Missing SDAC never falls back to EXAA.

Hourly targets round to eight decimals before the `<=0` share, avoiding numeric
zero sign artifacts. Prices are EUR/MWh throughout. Both naive history and the
scoring actual follow the selected target. Retargeting the evaluation does
**not** retrain a saved model or change its original context/lag policy.

## Naives and aggregation

Lags join **market date plus local hour**, never row offsets. Repeated source
local hours are averaged; both repeated target hours get the same source value.
A nonexistent spring source hour remains missing. The weekday rule is purely
calendar-weekday based, not a holiday calendar:

| Lead | D−1 | D−7 | Weekday (epf) |
|---|---|---|---|
| 1 | same hour previous local date | same hour seven dates earlier | D−1 Tue–Fri, D−7 Sat/Sun/Mon |
| 2–7 | unavailable; not emitted | same hour seven dates earlier | unavailable; not emitted |

Day-ahead prices for delivery D−1 are normally auctioned on D−2, hence known at
D−1 morning; this is a calendar availability rule. The extract retains latest
revisions, not an issue-time price archive. These retrospective naive inputs
therefore carry a reconstruction caveat. Leads2–7 cannot borrow target D−1
prices retrospectively.

Each model/naive/lead has its own finite common mask. `pairwise` is primary;
optional `all_models` is a separate cohort, demonstrated on Timestral. Adding a
sparse model cannot shrink prior pairwise masks. Model/naive MAE, bias, n, mean
price, nonpositive share and MAE/mean-price use those same cells. `rmae` is the
ratio of matched aggregate model and naive absolute errors. A zero naive error
makes rMAE undefined; a zero mean price makes MAE/mean-price undefined.

Both estimators are emitted:

1. **pooled_cell:** every retained hourly cell has equal weight.
2. **mean_daily:** first average each zone/local-day's retained cells, then
   average those zone-days equally, matching the site's daily-score style.
   Both errors use the same mask and rMAE is a ratio of these aggregate errors,
   not a mean of daily ratios. It is recalculated on the paired mask, so it need
   not equal an already stored scoreboard with different coverage.

`complete_zone_days` is the primary coverage: all23/24/25 local hours must be
paired. `all_paired_cells` is the secondary partial-coverage diagnostic. For the
historical record only, `historical-reconciliation.csv` replays its original
**energy-weighted mean of zone metrics**, including its weighted mean of zone
rMAEs. That is a third, separately labelled estimator, not a pooled-error ratio.
New live/Timestral results are not energy weighted.

## Significance

The independently implemented multivariate DM convention uses one daily L1
loss from each complete **24-hour vector**, not 24 independent hourly tests.
For footprints, absolute errors are taken before averaging zones; every declared
zone must cover all24 hours on a retained day. Spring/fall DST days and incomplete
days are excluded from DM only, retained in point scores. At least30 balanced
daily vectors are required; otherwise the result is `insufficient data`.

With `d=mean_hour(|naive-actual|-|model-actual|)`, positive DM favors the model.
Its standard error uses a Bartlett/Newey–West long-run variance with fixed
calendar bandwidth `max(7,lead-1)`. Missing dates remain gaps in the HAC products.
Zero loss-differential variance is explicitly undefined (identical daily losses
return p=1). Reported p-values are one-sided, asymptotic, exploratory and
unadjusted across comparisons. Mixed versions/regimes can violate a stable-loss
difference assumption, further limiting inference. A small p-value on reconstructed forecasts does
not authenticate first publication, uncontaminated pretraining or conduct.

Method references: [daily-vector DM convention](https://epftoolbox.readthedocs.io/en/latest/modules/statest/dm.html),
[Newey–West covariance method](https://www.nber.org/papers/t0055).
The formulas are implemented locally; epftoolbox is not imported or vendored.

## Source windows and limitations

- **Record:** July2024–June2026. Replaying rounded committed zone summaries with
  their original energy weights reproduces23.082 /0.814. Probe/OOS parquet files
  are absent locally (confirmed by leader), so new highest-sequence/SDAC cell
  scores, keyed naive scores, masks and DM are unavailable. GroupKFold ML rows
  are nonchronological, not prospective out-of-sample forecasts.
- **Rolling cv39:** July2025–June2026, four chronological folds. The committed
  summary reports physics23.30, stats21.05, n341,256, canonical SDAC, unweighted
  pooled cells. Saved per-cell predictions are absent, so there is no new
  retarget, naive denominator, mask or DM. These remain reported summaries.
- **Saved live:** September14–November13, 2026, `em-team/live/`, weather rows,
  all saved leads, mixed cv39/40/42. GBM/stats are explicitly named overlays: their
  independent issuance/artifact fit stamps are absent and they may have been
  rewritten. Multi-lead overlay scores are descriptive, not authenticated
  multi-day forecasts. Physics `prediction_made_utc` is creation-time evidence,
  not first-publication proof. No operational 06:30 availability is inferred.
- **Since cv43:** new immutable directory `em-team/live-20261116/`, fetched via
  the public no-auth API on November16 (exact per-file times/hashes in each
  manifest). Only cv>=43 weather rows. Includes tomorrow's delivery date when
  its DA auction already settled by fetch, capped at fetch-local-date+1.
  There are two complete lead1 highest-sequence dates (November16/17), mixed
  cv43/44. The raw extract ends earlier: SDAC has39 partial cells and **zero
  complete new zone-days**. Partial scores are separate, never a two-day SDAC
  performance claim. Both DM results are insufficient data.
- **Timestral:** saved209M forecasts, original frozen on-time physics cohort,
  exactly47,679 cells:936 cv39,36,447 cv40 and10,296 cv42. Physics code versions
  are carried from the saved rows; physics model and post-sim base version
  lists/counts derive from this eligible original cohort. Prices-only models
  have no physics base. These provenance counts precede target-policy and
  complete-zone-day restrictions, whose masks/counts are reported separately.
  The original cohort required D−1/D−2/D−7 price coverage;
  D−2 is preserved only as a cohort condition, not evaluated as a benchmark.
  Original highest-sequence MAE25.2647 vs same-context prices-only28.8191 is
  reproduced. New SDAC/complete-day estimators differ as expected. “On-time”
  bounds the physics input cutoff at10:00; it does not prove the offline
  reconstruction was publicly issued then. Contexts remain those saved; their
  initial auction revisions/pretraining separation are not authenticated.

`target-exclusions.csv` lists auction/revision/resolution exclusions.
`public-highest-seq-overlap.csv` records changes between the newer public target
snapshot and the older extract; post-cv43 and older cohorts are never silently
pooled. No missing historical raw forecast or current SDAC target is invented.

## Reproduce

Use a private environment with `requirements.txt`. No Julia or production
credentials are required. The supplied example's zero hashes are placeholders;
replace them with your actual file hashes and provenance before use.

```bash
python -m pytest docs/experiments/benchmark-431/test_benchmark.py -q
python docs/experiments/benchmark-431/evaluate.py \
  --actuals /saved/actuals.csv --forecasts /saved/forecasts.csv \
  --manifest /saved/manifest.json --output /saved/benchmark-output
```

To recreate this saved-data pack (pin heavy work to your assigned cores):

```bash
python docs/experiments/benchmark-431/prepare.py \
  --extract /path/to/euphemia-live-20261115.duckdb \
  --live /path/to/em-team/live --fresh-live /path/to/em-team/live-20261116 \
  --tsfm /path/to/em-team/results/tsfm --cache /private/benchmark-inputs \
  --outputs docs/experiments/benchmark-431/outputs
OPENBLAS_NUM_THREADS=1 python docs/experiments/benchmark-431/run_pack.py \
  --pack /private/benchmark-inputs/pack.json \
  --output docs/experiments/benchmark-431/outputs --workers 3
```

The extract is opened with `read_only=True` and hashed without copying it.
Raw prepared panels stay in the private cache. `fetch_live.py --output NEW_DIR`
creates a new public snapshot with a generic User-Agent and a0.5-second pause;
it refuses to overwrite a directory. There is no dispatch or production write.

## External protocol references and licence (not a ranking)

[Lago et al.'s benchmark](https://arxiv.org/abs/2008.08004) describes other
markets, test years, recalibration and benchmark conventions. Those protocols
are references, not converted rMAE numbers or a claim of LEAR-class performance.
No literature score is placed beside this pack's results.

The upstream epftoolbox [LICENSE at commit47d6e06](https://github.com/jeslago/epftoolbox/blob/47d6e0629f65ebd19d3c12cb5689dbad0c2ea078/LICENSE)
is **Apache-2.0**, checked2026-11-16, correcting the task's tentative AGPL belief.
This pack still does not import epftoolbox or its training stack.
