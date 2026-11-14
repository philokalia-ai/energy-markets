# Independent RES-only measurement: blocks

Source: `em-team/reports/blocks.md`, 20:55 UTC report entry, read on
2026-11-14 at approximately 21:51 UTC. Source report SHA256 at capture:
`6927ea12f192efd9a9497dd1f653239cfa02912b59d006c4a0ece2ee666a89c8`. The complete source is a running team report; this excerpt freezes the measurement cited here.

The RES-only row is a second measurement on September 27 and November 2.
Its base includes both the Italy fleet correction and the in-merit correction.
Its input path is the legacy record path without the 10:00 context used by
collapse's eight-day matrix. Compare the RES arm with its own base; do not
pool absolute levels across the two workstreams. The reported delta is
−0.01 €/MWh (the displayed endpoints are rounded independently). Hits change
1→10 and false alarms 1→13. This does not establish a decisive level gain.

## Earlier two-day source row

From the 20:55 UTC report entry (partial matrix, Italy + in-merit base):

| Arm | Days | Reported MAE | Hits | False alarms |
|---|---|---|---|---|
| RES ladder only vs own base | 09-27, 11-02 | 52.01→51.99, reported Δ−0.01 | 1→10 | 1→13 |

## Later seven-day relay

Leader relayed blocks' additional measurement on 2026-11-14: in the September20
RES pass2, two of24 periods reached time_limit, and the12:00UTC incumbent
put all39 zones at the3000€/MWh cap (base10.17€/MWh). After excluding
cap/floor cells, its seven-day comparison contains6,523 cells, MAE delta
+0.30€/MWh, hits1→27 and false alarms1→16. This later filtered slice is
reported by blocks, not independently re-scored by collapse. It is distinct
from the earlier two-day row and from collapse's context-bound eight-day
matrix. The suggested zero-offer degeneracy mechanism remains a hypothesis.
