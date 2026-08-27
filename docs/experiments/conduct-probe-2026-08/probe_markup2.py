"""Implied-markup temporal structure, 2y."""
import sys, numpy as np, pandas as pd
S=sys.argv[1]; TAG=sys.argv[2] if len(sys.argv)>2 else ''
df = pd.read_parquet(f'{S}/probe{TAG}_dataset.parquet').dropna(subset=['markup'])
df['pk'] = df.hour.between(16,19)
df['season'] = np.where(df.month.isin([12,1,2]), 'win', np.where(df.month.isin([6,7,8]), 'sum', 'shoulder'))
g = df.groupby('zone')
base = g.apply(lambda d: d[~d.pk].markup.mean())
t = pd.DataFrame({
  'mk_pk_prem': g.apply(lambda d: d[d.pk].markup.mean()) - base,
  'mk_win_prem': g.apply(lambda d: d[d.season=='win'].markup.mean() - d[d.season=='sum'].markup.mean()),
  'piv_share': g.piv.mean(), 'tier1': g.tier1.first(),
}).round(1).sort_values('mk_pk_prem', ascending=False)
print(t.to_string()); t.to_csv(f'{S}/probe{TAG}_markup_structure.csv')
