"""Hand-calculable checks; pytest needs no extract, network or model artifact."""
import importlib.util
import json
from pathlib import Path
import sys

import numpy as np
import pandas as pd
import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
spec = importlib.util.spec_from_file_location("benchmark431", HERE / "evaluate.py")
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)
from targets import helper


def history(start="2026-09-01", end="2026-10-05"):
    x = b.make_grid(["GR"], start, end, "Europe/Athens")
    x["actual"] = (x.market_date - pd.Timestamp(start)).dt.days * 10. + x.local_hour
    return x[["zone", "t", "actual"]]


def forecast(a, start="2026-09-15", end="2026-09-16", error=0., model="test", lead=1):
    x = b.calendar(a, "Europe/Athens")
    x = x[x.market_date.between(start, end)].copy()
    x["prediction"] = x.actual + error
    x["model"], x["lead"] = model, lead
    return x[["zone", "t", "prediction", "model", "lead"]]


def pooled(tables, **filters):
    m = tables["metrics"]
    keep = m.group.eq("all") & m.coverage.eq("all_paired_cells") & m.aggregation.eq("pooled_cell")
    for col, value in filters.items():
        keep &= m[col].eq(value)
    return m[keep].iloc[0]


@pytest.mark.parametrize("error,rmae", [(0., 0.), (20., 2.)])
def test_perfect_and_worse_forecast(error, rmae):
    a = history()
    out = b.evaluate(a, forecast(a, error=error), start="2026-09-15", end="2026-09-16")
    m = pooled(out, naive="d1", mask_family="pairwise")
    assert m.n == 48 and m.mae == error and m.bias == error
    assert m.naive_mae == 10 and m.rmae == rmae


def test_lags_use_dates_not_row_offsets_and_nan_common_mask():
    a = history()
    f = forecast(a, end="2026-09-15")
    local = b.calendar(a, "Europe/Athens")
    a = a[~(local.market_date.eq("2026-09-14") & local.local_hour.eq(2))].copy()
    f.loc[f.index[3], "prediction"] = np.nan
    a.loc[a.t.eq(f.t.iloc[4]), "actual"] = np.nan
    out = b.evaluate(a, f, start="2026-09-15", end="2026-09-15")
    m = pooled(out, naive="d1", mask_family="pairwise")
    assert m.n == 21 and m.naive_mae == 10
    masks = out["masks"].query("naive == 'd1'").iloc[0]
    assert masks.complete_day_n == 0 and masks.partial_day_n == 21


@pytest.mark.parametrize("lead", [1, 2, 7])
def test_lead_admissibility(lead):
    a = history()
    f = forecast(a, lead=lead)
    out = b.evaluate(a, f, start="2026-09-15", end="2026-09-16")
    assert pooled(out, naive="d7", mask_family="pairwise").n == 48
    for n in ["d1", "epf"]:
        if lead == 1:
            assert pooled(out, naive=n, mask_family="pairwise").n == 48
        else:
            assert out["metrics"].query("naive == @n").empty
            assert out["exclusions"].query("naive == @n and reason=='naive_unavailable_at_issue_for_lead'").n.sum() == 48


@pytest.mark.parametrize("day,lag", [("2026-09-14", 7), ("2026-09-15", 1),
                                      ("2026-09-18", 1), ("2026-09-19", 7), ("2026-09-20", 7)])
def test_weekday_rule(day, lag):
    a = history()
    target = forecast(a, start=day, end=day).assign(lead=1)
    x = b.naive_forecasts(a, target)
    assert np.allclose(target.prediction.to_numpy() - x.naive_epf, lag * 10)


def test_zero_naive_denominator_and_zero_mean_price():
    x = pd.DataFrame(dict(zone=["GR", "GR"], market_date=pd.to_datetime(["2026-09-15"] * 2),
                          actual=[-1., 1.], prediction=[0., 2.], naive=[-1., 1.]))
    m = b.summarize(x, "pooled_cell")
    assert m["mae"] == 1 and m["rmae"] is None and m["naive_mae"] == 0
    assert m["mae_over_mean_price"] is None and m["share_le_zero"] == .5


def test_site_daily_estimator_and_ratio_of_errors():
    x = pd.DataFrame(dict(zone=["GR"] * 25,
        market_date=pd.to_datetime(["2026-09-15"] * 24 + ["2026-09-16"]),
        actual=[1.] * 25, prediction=[1.] * 24 + [25.], naive=[3.] * 24 + [5.]))
    cell, daily = b.summarize(x, "pooled_cell"), b.summarize(x, "mean_daily")
    assert cell["mae"] == 24 / 25 and cell["rmae"] == pytest.approx(24 / 52)
    assert daily["mae"] == 12 and daily["rmae"] == 4  # not the mean daily ratio, 3


def test_sparse_candidate_does_not_change_existing_pair_mask():
    a = history()
    f = forecast(a, end="2026-09-15")
    first = b.evaluate(a, f, start="2026-09-15", end="2026-09-15")
    sparse = f.iloc[:2].assign(model="sparse")
    second = b.evaluate(a, pd.concat([f, sparse]), start="2026-09-15", end="2026-09-15", intersection=True)
    x = first["masks"].query("model=='test' and naive=='d1'").iloc[0]
    y = second["masks"].query("model=='test' and naive=='d1' and mask_family=='pairwise'").iloc[0]
    assert x.n == y.n == 24 and x.mask_sha256 == y.mask_sha256
    assert second["masks"].query("model=='test' and naive=='d1' and mask_family=='all_models'").n.iloc[0] == 2


def test_duplicate_keys_and_subhourly_rows_rejected():
    a = history()
    f = forecast(a)
    with pytest.raises(ValueError, match="Duplicate"):
        b.evaluate(a, pd.concat([f, f.iloc[:1]]), start="2026-09-15", end="2026-09-16")
    f.loc[f.index[0], "t"] += pd.Timedelta(minutes=15)
    with pytest.raises(ValueError, match="subhourly"):
        b.evaluate(a, f, start="2026-09-15", end="2026-09-16")


def test_authenticated_availability_is_not_inferred_from_a_late_stamp():
    a = history()
    a["available_utc"] = pd.Timestamp("2026-09-14 12:00Z")
    f = forecast(a, end="2026-09-15").assign(issue_utc=pd.Timestamp("2026-09-14 06:30Z"))
    out = b.evaluate(a, f, start="2026-09-15", end="2026-09-15")
    assert pooled(out, naive="d1", mask_family="pairwise").n == 0
    a["available_utc"] = pd.Timestamp("2026-09-13 12:00Z")
    out = b.evaluate(a, f, start="2026-09-15", end="2026-09-15")
    assert pooled(out, naive="d1", mask_family="pairwise").n == 24


def test_dst_25_hour_repeat_mean_and_23_hour_missing_source():
    a = history("2026-10-15", "2026-10-27")
    local = b.calendar(a, "Europe/Athens")
    repeated = local.market_date.eq("2026-10-25") & local.local_hour.eq(3)
    assert repeated.sum() == 2
    a.loc[repeated, "actual"] = [10., 30.]
    f = forecast(a, start="2026-10-26", end="2026-10-26")
    n = b.naive_forecasts(a, f)
    assert n.loc[n.local_hour.eq(3), "naive_d1"].iloc[0] == 20
    a = history("2026-03-15", "2026-03-31")
    f = forecast(a, start="2026-03-30", end="2026-03-30")
    n = b.naive_forecasts(a, f)
    assert n.loc[n.local_hour.eq(3), "naive_d1"].isna().all()


@pytest.mark.parametrize("day,n", [("2026-03-29", 23), ("2026-10-25", 25)])
def test_dst_hours_scored_but_excluded_from_daily_vector_dm(day, n):
    start = str((pd.Timestamp(day) - pd.Timedelta(days=10)).date())
    a = history(start, day)
    f = forecast(a, start=day, end=day)
    out = b.evaluate(a, f, start=day, end=day)
    assert pooled(out, naive="d7", mask_family="pairwise").n == n
    dm = out["dm"].query("group=='all' and naive=='d7'").iloc[0]
    assert dm.n_days == 0 and dm.status == "insufficient data"


def test_multivariate_dm_direction_short_window_and_zero_variance():
    model = np.zeros((40, 24))
    naive = np.tile(np.arange(1, 41)[:, None], (1, 24))
    better = b.dm_daily_vectors(model, naive)
    worse = b.dm_daily_vectors(naive, model)
    assert better["statistic"] > 0 and better["p_model_better"] < .05
    assert worse["p_model_better"] > .95
    assert b.dm_daily_vectors(model[:29], naive[:29])["status"] == "insufficient data"
    assert b.dm_daily_vectors(model, model)["p_model_better"] == 1.
    assert b.dm_daily_vectors(model, np.ones((40, 24)))["statistic"] is None
    with pytest.raises(ValueError):
        b.dm_daily_vectors(np.ones((40, 23)), np.ones((40, 23)))


def test_sdac_target_auction_and_missing_hour_fail_closed():
    raw = pd.DataFrame(dict(z=["AT"] * 5 + ["UNKNOWN"] * 2,
        seq=["1"] * 4 + ["2", "1", "2"], res=["PT15M"] * 4 + ["PT60M"] * 3,
        t=pd.to_datetime(["2026-09-15 00:00", "2026-09-15 00:15", "2026-09-15 00:30", "2026-09-15 00:45"] + ["2026-09-15 00:00"] * 3),
        p=[1., 2., 3., 4., 100., 5., 6.], u=pd.Timestamp("2026-09-14")))
    actual, exclusions, _ = helper.sdac_hourly(raw)
    assert actual.z.tolist() == ["AT"] and actual.act.iloc[0] == 2.5
    assert "ambiguous auction" in set(exclusions.reason)
    assert helper.highest_seq_hourly(raw).query("z=='AT'").act.iloc[0] > 2.5
    short = raw.drop(index=3)
    assert helper.sdac_hourly(short)[0].query("z=='AT'").empty


def test_mask_hash_is_order_independent():
    x = forecast(history())
    assert b.mask_hash(x, 1) == b.mask_hash(x.iloc[::-1], 1)


def test_dm_hac_uses_calendar_lags_across_gaps():
    zeros = np.zeros((3, 24))
    naive = np.tile(np.array([1., 2., 4.])[:, None], (1, 24))
    result = b.dm_daily_vectors(zeros, naive, pd.to_datetime(["2026-01-01", "2026-01-02", "2026-01-04"]),
                                min_days=3, hac_lag=1)
    assert result["statistic"] == pytest.approx(21 / np.sqrt(46))


def test_footprint_dm_takes_absolute_errors_before_averaging_zones():
    x = b.make_grid(["AT", "GR"], "2026-01-01", "2026-02-09", "Europe/Athens")
    day = (x.market_date - pd.Timestamp("2026-01-01")).dt.days + 1
    x["actual"] = 0.
    x["prediction"] = np.where(x.zone == "AT", day, -day)
    x["naive"] = 1.
    result = b.dm_for_group(x, ["AT", "GR"], "Europe/Athens", 1, 30)
    assert result["statistic"] < 0 and result["p_model_better"] > .95


def test_cli_contract_hashes_and_output_manifest(tmp_path, monkeypatch):
    a = history()
    f = forecast(a)
    actual_path, forecast_path = tmp_path / "actuals.csv", tmp_path / "forecasts.csv"
    a.to_csv(actual_path, index=False)
    f.to_csv(forecast_path, index=False)
    manifest = dict(source={"actuals": {"sha256": b.sha256_file(actual_path)},
                            "forecasts": {"sha256": b.sha256_file(forecast_path)}},
                    target_policy="sdac", resolution="PT60M", market_day_timezone="Europe/Athens",
                    models=[{"id": "test", "artifact_cv": None, "base_cv": 44}], fit_end=None,
                    cutoff_publication_class="synthetic", window={"start": "2026-09-15", "end": "2026-09-16"},
                    missingness="finite paired cells", aggregation=["pooled_cell", "mean_daily"], mask_sha256=None)
    path = tmp_path / "manifest.json"
    path.write_text(json.dumps(manifest))
    monkeypatch.setattr(sys, "argv", ["evaluate.py", "--actuals", str(actual_path), "--forecasts", str(forecast_path),
                                     "--manifest", str(path), "--output", str(tmp_path / "out")])
    b.main()
    written = json.loads((tmp_path / "out/manifest.json").read_text())
    assert written["mask_sha256"] == b.sha256_file(tmp_path / "out/masks.csv")
    assert written["output_sha256"]["metrics"] == b.sha256_file(tmp_path / "out/metrics.csv")
    forecast_path.write_text(forecast_path.read_text() + "\n")
    with pytest.raises(ValueError, match="hash mismatch"):
        b.main()


def test_nullable_missing_actual_is_excluded_from_both_errors():
    a = history()
    f = forecast(a, end="2026-09-15")
    a["actual"] = a.actual.astype("Float64")
    a.loc[a.t.eq(f.t.iloc[0]), "actual"] = pd.NA
    out = b.evaluate(a, f, start="2026-09-15", end="2026-09-15")
    assert pooled(out, naive="d1", mask_family="pairwise").n == 23


def test_numeric_zero_target_is_normalized_before_nonpositive_share():
    a = history()
    a["actual"] = 1e-18
    f = forecast(a).assign(prediction=0.)
    result = b.evaluate(a, f, start="2026-09-15", end="2026-09-16")
    metric = pooled(result, naive="d1", mask_family="pairwise")
    assert metric.mae == 0 and metric.share_le_zero == 1 and pd.isna(metric.rmae)


def test_misaligned_intervals_do_not_fake_a_complete_sdac_hour():
    raw = pd.DataFrame(dict(z=["AT", "AT"], seq=["1", "1"], res=["PT30M", "PT30M"],
                           t=pd.to_datetime(["2026-09-15 00:15", "2026-09-15 00:45"]),
                           p=[1., 2.], u=pd.Timestamp("2026-09-14")))
    act, exclusions, _ = helper.sdac_hourly(raw)
    assert act.empty and set(exclusions.reason) == {"misaligned interval"}
