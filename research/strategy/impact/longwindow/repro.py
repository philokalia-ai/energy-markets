"""Reproduction check: long-window overlays 2026-09-01..11-14 vs the first combined check's overlays (same days).
usage: venv-tsfm/bin/python -I repro.py > repro.md"""
import os, glob, pandas as pd
EM = os.path.expanduser('~/armada/em-team'); L = f'{EM}/strategy/runs/st-impact/r2/long'
old = {'base': f'{EM}/cv46-physics/runs/cp-runs/combined-pr-74d9fc3/tsfm-PR/postsim',
       'cand': f'{EM}/strategy/runs/st-impact/r2/comb/tsfm-SHAPE/postsim'}
cols = ['zone', 't_utc', 'tsfm_median', 'tsfm_q10', 'tsfm_q90']
print('# Reproduction: 2026-09-01..11-14 overlays, long-window run vs first combined check\n')
for a in ('base', 'cand'):
    fs = sorted(os.path.basename(f) for f in glob.glob(f'{old[a]}/2026-*.csv'))
    x = pd.concat([pd.read_csv(f'{old[a]}/{f}', usecols=cols) for f in fs])
    y = pd.concat([pd.read_csv(f'{L}/tsfm-{a}/postsim/{f}', usecols=cols) for f in fs if os.path.exists(f'{L}/tsfm-{a}/postsim/{f}')])
    m = x.merge(y, on=['zone', 't_utc'], how='outer', suffixes=('_old', '_new'), indicator=True)
    both = m[m._merge == 'both']; d = (both.tsfm_median_old - both.tsfm_median_new).abs()
    dq = max((both.tsfm_q10_old - both.tsfm_q10_new).abs().max(), (both.tsfm_q90_old - both.tsfm_q90_new).abs().max())
    print(f'- {a}: {len(fs)} days, {len(both):,} common cells (only old {int((m._merge=="left_only").sum())}, only new '
          f'{int((m._merge=="right_only").sum())}); median forecast max |diff| {d.max():.3g} €/MWh, mean |diff| {d.mean():.3g}, '
          f'cells differing {int((d > 0).sum()):,}; q10/q90 max |diff| {dq:.3g}')
