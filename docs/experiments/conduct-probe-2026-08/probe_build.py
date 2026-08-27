"""Conduct-probe dataset: per zone-hour over the book-covered Wednesdays.
Physics features + inversion at actual net position + conduct features."""
import sys, os, glob, datetime as dt
import duckdb, numpy as np, pandas as pd
S = sys.argv[1]
BOOKS = sys.argv[2] if len(sys.argv) > 2 else 'data/web/v1/books'
TAG = sys.argv[3] if len(sys.argv) > 3 else ''      # '' -> probe_*.csv inputs; '2y' -> probe2y_*.csv
D0, D1 = dt.date(2024,7,1), dt.date(2026,6,30)
if TAG:
    days = sorted(dt.date.fromisoformat(f[:10]) for f in os.listdir(BOOKS)
                  if f.endswith('.parquet') and not f.startswith('.') and D0 <= dt.date.fromisoformat(f[:10]) <= D1)
else:
    wed = [dt.date(2025,7,2)+dt.timedelta(days=7*i) for i in range(52)]
    days = [d for d in wed if os.path.exists(f'{BOOKS}/{d}.parquet')]
print(f"days with books: {len(days)} ({days[0]}..{days[-1]})", flush=True)
con = duckdb.connect()
# --- flows -> actual net export per zone-hour (UTC hour key)
fl = con.sql(f"""select ts, o, i, mw from read_csv('{S}/probe{TAG}_flows.csv', header=false,
              names=['ts','o','i','mw'], types={{'ts':'timestamptz'}})""").df()
fl['k'] = pd.to_datetime(fl.ts, utc=True).dt.strftime('%Y-%m-%dT%H')
# sub-hourly (PT15M) flow rows must be AVERAGED into the hour before summing
# across borders — summing them counted 15-min borders 4x (found 2026-08-27).
fl = fl.groupby(['o','i','k'], as_index=False).mw.mean()
out = fl.groupby(['o','k']).mw.sum().rename('out_mw'); inn = fl.groupby(['i','k']).mw.sum().rename('in_mw')
nx = pd.concat([out, inn], axis=1).fillna(0.0); nx['nx'] = nx.out_mw - nx.in_mw
nx = nx.reset_index().rename(columns={'level_0':'zone','o':'zone','index':'zk'})
nx = nx.rename(columns={nx.columns[0]:'zone', nx.columns[1]:'k'})[['zone','k','nx']]
nxmap = {(r.zone, r.k): r.nx for r in nx.itertuples()}
# --- firm map
fm = pd.read_csv(f'{S}/probe_firms.psv', sep='|', header=None, names=['fz','unit_code','firm'])
firm_of = dict(zip(fm.unit_code, fm.firm))
TIER1 = {'GR','HU','BG','RS','FR','RO'}
# --- fuels (D-2 close convention: last close strictly before day-1)
ttf = pd.read_csv(f'{S}/probe_ttf.csv', header=None, names=['date','close'], parse_dates=['date'])
eua = pd.read_csv(f'{S}/probe_eua.csv', header=None, names=['date','close'], parse_dates=['date'])
def lastclose(df, day):
    s = df[df.date < pd.Timestamp(day) - pd.Timedelta(days=1)]
    return float(s.close.iloc[-1]) if len(s) else np.nan
# --- JAO net-position headroom
jn = pd.read_csv(f'{S}/probe{TAG}_jaonp.csv', header=None, names=['hub','ts','mn','mx'])
jn['k'] = pd.to_datetime(jn.ts, utc=True, format='mixed').dt.strftime('%Y-%m-%dT%H')
jn['zone'] = jn.hub.replace({'DE':'DE_LU'})
jn = jn.groupby(['zone','k'])[['mn','mx']].mean().reset_index()
jaomap = {(r.zone, r.k): (r.mn, r.mx) for r in jn.itertuples()}
rows = []
for day in days:
    b = con.sql(f"""select zone, ts, side, price, mw, owner from '{BOOKS}/{day}.parquet'""").df()
    b['k'] = pd.to_datetime(b.ts, utc=True).dt.strftime('%Y-%m-%dT%H')
    gas, co2 = lastclose(ttf, day), lastclose(eua, day)
    for (z, k), g in b.groupby(['zone','k']):
        sup = g[g.side=='supply']; dem = g[g.side=='demand']
        D = dem.mw.sum()
        if D <= 0 or len(sup)==0: continue
        nxv = float(nxmap.get((z, k), np.nan))
        res = sup[sup.owner=='RES'].mw.sum(); imp = sup[sup.owner=='IMPORT'].mw.sum()
        bst = sup[sup.owner=='BACKSTOP'].mw.sum()
        named = sup[~sup.owner.isin(['RES','IMPORT','BACKSTOP'])]
        # supply curve (all offers incl RES/IMPORT/BACKSTOP), demand curve
        sc = sup.sort_values('price'); cs = sc.mw.cumsum().values; ps = sc.price.values
        dc = dem.sort_values('price', ascending=False); cd = dc.mw.cumsum().values; pd_ = dc.price.values
        # inversion at actual NX: find min p with S(p) >= D(p) + nx
        p_comp = np.nan
        if not np.isnan(nxv):
            # walk supply steps; demand served at price p:
            def dem_at(p): return cd[pd_ >= p][-1] if (pd_ >= p).any() else 0.0
            tgt_idx = np.searchsorted(cs - np.array([dem_at(p) for p in ps]) - nxv, 0.0)
            p_comp = ps[min(tgt_idx, len(ps)-1)]
        # conduct: firm aggregation (tier1 real firms, else owner-level)
        named2 = named.assign(f=[firm_of.get(o, o) for o in named.owner])
        fs = named2.groupby('f').mw.sum().sort_values(ascending=False)
        tot_named = fs.sum()
        top1 = float(fs.iloc[0]) if len(fs) else 0.0
        hhi = float(((fs/tot_named)**2).sum()) if tot_named>0 else np.nan
        # RSI: (total supply - top1) / (D + max(nx,0))
        stot = sup.mw.sum()
        need = D + max(nxv, 0.0) if not np.isnan(nxv) else D
        rsi = (stot - top1)/need if need>0 else np.nan
        mn, mx = jaomap.get((z, k), (np.nan, np.nan))
        rows.append(dict(zone=z, k=k, day=str(day), hour=int(k[11:13]), month=int(k[5:7]),
            D=D, nx=nxv, p_comp=p_comp, stot=stot, res_sh=res/D, imp_sh=imp/D, bst_sh=bst/D,
            margin=stot/D, top1_sh=top1/tot_named if tot_named>0 else np.nan, hhi=hhi, rsi=rsi,
            piv=1.0 if (not np.isnan(rsi) and rsi<1.0) else 0.0, tier1=float(z in TIER1),
            np_head_exp=(mx-nxv) if not np.isnan(mx) and not np.isnan(nxv) else np.nan,
            gas=gas, co2=co2))
    print(day, len(rows), flush=True)
df = pd.DataFrame(rows)
# join settled + cv35 sim
def loadcsv(f):
    d = pd.read_csv(f, header=None, names=['zone','ts','p'])
    d['k'] = pd.to_datetime(d.ts, utc=True, format='mixed').dt.strftime('%Y-%m-%dT%H')
    return d.groupby(['zone','k']).p.mean().rename('p').reset_index()
st_ = loadcsv((f'{S}/probe2y_settled.csv' if TAG else f'{S}/eval_settled.csv')).rename(columns={'p':'settled'})
sim = loadcsv(f'{S}/probe2y_sim.csv' if TAG else f'{S}/arm_ab_jao_np.csv').rename(columns={'p':'sim35'})
df = df.merge(st_, on=['zone','k'], how='left').merge(sim, on=['zone','k'], how='left')
df['resid'] = df.settled - df.sim35          # conduct object: settled minus counterfactual
df['markup'] = df.settled - df.p_comp        # implied markup from book inversion
df.to_parquet(f'{S}/probe{TAG}_dataset.parquet')
print("rows", len(df), "with settled", df.settled.notna().sum(), "with nx", df.nx.notna().sum())
print(df.groupby('zone')[['resid','markup']].mean().round(1).T.to_string())
