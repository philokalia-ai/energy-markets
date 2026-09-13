"""Edge cases the 2026-09-13 review reproduced against the first draft."""
import numpy as np, pandas as pd, settlement_view as sv


class FakeCx:
    def __init__(self, df): self.df = df


def _patch(df):
    sv._raw = lambda cx, w0, w1: df.copy()


def mk(rows):
    d = pd.DataFrame(rows, columns=["z", "seq", "res", "t", "p", "u"])
    d["t"] = pd.to_datetime(d.t); d["u"] = pd.to_datetime(d.u)
    return d


def test_latest_revision_wins():
    _patch(mk([("X", "", "PT60M", "2026-01-01 00:00", 100.0, "2026-01-01 10:00"),
               ("X", "", "PT60M", "2026-01-01 00:00", 200.0, "2026-01-01 14:00")]))
    out = sv.canonical_settlement(FakeCx(None), "2026-01-01", "2026-01-02")
    assert out.a.iloc[0] == 200.0, out          # was 100 (earliest kept)


def test_hour_uses_one_resolution():
    # hourly 100 at 00:00 + quarter zeros at :15/:30/:45 -> the quarter series
    # does not cover the hour (45 of 60 min), so the hourly row wins: 100, not 25
    _patch(mk([("X", "", "PT60M", "2026-01-01 00:00", 100.0, "2026-01-01"),
               ("X", "", "PT15M", "2026-01-01 00:15", 0.0, "2026-01-01"),
               ("X", "", "PT15M", "2026-01-01 00:30", 0.0, "2026-01-01"),
               ("X", "", "PT15M", "2026-01-01 00:45", 0.0, "2026-01-01")]))
    out = sv.canonical_settlement(FakeCx(None), "2026-01-01", "2026-01-02")
    assert out.a.iloc[0] == 100.0, out          # was 25.0 (mixed resolutions)


def test_complete_quarter_hour_is_duration_weighted():
    _patch(mk([("X", "", "PT15M", f"2026-01-01 00:{m:02d}", v, "2026-01-01")
               for m, v in ((0, 100.0), (15, 200.0), (30, 300.0), (45, 400.0))]))
    out = sv.canonical_settlement(FakeCx(None), "2026-01-01", "2026-01-02")
    assert out.a.iloc[0] == 250.0, out


def test_exaa_sequence_dropped_and_ledgered():
    _patch(mk([("DE_LU", "1", "PT60M", "2026-01-01 00:00", 100.0, "2026-01-01 14:15"),
               ("DE_LU", "2", "PT60M", "2026-01-01 00:00", 80.0, "2026-01-01 11:10")]))
    out, smap, exc = sv.canonical_settlement(FakeCx(None), "2026-01-01", "2026-01-02",
                                             return_map=True, return_excluded=True)
    assert out.a.iloc[0] == 100.0 and smap.loc["DE_LU", "seq"] == "1"
    assert (exc.reason == "other auction").sum() == 1


def test_unknown_multi_auction_zone_fails_closed():
    _patch(mk([("ZZ", "1", "PT60M", "2026-01-01 00:00", 10.0, "2026-01-01"),
               ("ZZ", "2", "PT60M", "2026-01-01 00:00", 20.0, "2026-01-01")]))
    try:
        sv.canonical_settlement(FakeCx(None), "2026-01-01", "2026-01-02")
    except ValueError as e:
        assert "ZZ" in str(e); return
    raise AssertionError("expected a fail-closed error for an unmapped multi-auction zone")


def test_incomplete_hour_excluded():
    _patch(mk([("X", "", "PT15M", "2026-01-01 00:00", 100.0, "2026-01-01"),
               ("X", "", "PT15M", "2026-01-01 00:15", 100.0, "2026-01-01")]))
    out, exc = sv.canonical_settlement(FakeCx(None), "2026-01-01", "2026-01-02", return_excluded=True)
    assert len(out) == 0 and (exc.reason == "resolution not chosen for the hour").sum() == 2


if __name__ == "__main__":
    import sys
    fs = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for f in fs:
        f(); print("ok", f.__name__)
    print(f"{len(fs)} settlement-view cases pass")
