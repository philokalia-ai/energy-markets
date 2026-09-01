import pandas as pd, numpy as np, os
pd.set_option('display.width', 250); pd.set_option('display.max_rows', 300)
S=os.environ['S']; B='/home/pgeorgakopoulos/armada/energy-markets/data/backfill_books_cv37/'
df = pd.read_parquet(S+'/cv37_joined.parquet')
def book_view(day, zone, hour):
    b = pd.read_parquet(B+day+'.parquet'); b=b[(b.zone==zone)&(b.ts==pd.Timestamp(f"{day} {hour:02d}:00:00"))]
    sup=b[b.side=='supply'].copy(); dem=b[b.side=='demand'].copy()
    sup['strat']=sup.strategy.str.replace(r'_t\d+$','',regex=True)
    print(f"\n--- {zone} {day} {hour:02d}:00 UTC | demand MW {dem.mw.sum():.0f} | settled {df[(df.z==zone)&(df.h==pd.Timestamp(f'{day} {hour:02d}:00:00'))].act.values} model {df[(df.z==zone)&(df.h==pd.Timestamp(f'{day} {hour:02d}:00:00'))].sim.values}")
    g=sup.groupby('strategy').agg(mw=('mw','sum'),pmin=('price','min'),pmed=('price','median'),pmax=('price','max')).sort_values('pmed')
    g['cum_mw']=g.mw.cumsum(); print(g.round(1).to_string())
    # marginal strategy at demand
    sup=sup.sort_values('price'); sup['cum']=sup.mw.cumsum(); D=dem[dem.price>=3000].mw.sum()
    m=sup[sup.cum>=D].head(1); print("marginal order at firm demand:", m[['price','mw','owner','strategy']].to_string(index=False))
for day in ['2026-08-18','2025-08-19']:
    for z in ['DE_LU','PL']:
        book_view(day,z,18)
# fuel mix of supply strategies: which owners are coal vs gas? peek owner names by strategy
b = pd.read_parquet(B+'2026-08-18.parquet'); b=b[(b.zone=='DE_LU')&(b.side=='supply')]
print("\nstrategies:", sorted(b.strategy.unique())[:60])
print("owners sample:", b.owner.unique()[:40])
