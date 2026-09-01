import pandas as pd, numpy as np, os
pd.set_option('display.width', 250); pd.set_option('display.max_rows', 300)
p = pd.read_parquet('/tmp/claude-1000/-home-pgeorgakopoulos-armada-energy-markets/f14d1211-694f-4ee9-8b0f-e5fdf0b9ea13/scratchpad/probe2y37_dataset.parquet')
print(p.columns.tolist(), len(p))
p['r']=p.sim37-p.settled
print("\n=== bias (model-settled) by MODEL MARGIN decile (supply/demand), pooled Core+SEE+Baltic, hours 16-19 UTC ===")
belt=['DE_LU','NL','BE','AT','CZ','SK','HU','SI','PL','RO','BG','GR','RS','EE','LV','LT','FR','CH','DK1','DK2']
x=p[p.zone.isin(belt)&(p.hour>=16)&(p.hour<=19)].copy(); x['md']=pd.qcut(x.margin.rank(method='first'),10,labels=False)
print(x.groupby('md').agg(margin=('margin','mean'),n=('r','size'),bias=('r','mean'),settled=('settled','mean'),sim=('sim37','mean'),spike_rate=('settled',lambda s:(s>=200).mean())).round(2).T.to_string())
print("\n=== same, per zone: bias in lowest vs highest margin decile (within zone, all hours) ===")
def f(g):
    g=g.copy(); g['md']=pd.qcut(g.margin.rank(method='first'),10,labels=False)
    b=g.groupby('md').r.mean(); m=g.groupby('md').margin.mean()
    return pd.Series({'margin_d0':m[0],'bias_d0':b[0],'bias_d5':b[5],'bias_d9':b[9],'margin_d9':m[9],'slope_bias_per_0.1margin':np.polyfit(g.margin,g.r,1)[0]*0.1})
print(p.groupby('zone').apply(f).round(2).sort_values('bias_d0').to_string())
# does settled respond to margin more steeply than model? regress price on margin within zone-hour
print("\n=== elasticity: OLS slope of settled and of model on margin (per 0.1 margin), evening 17-19, selected zones ===")
for z in ['DE_LU','NL','PL','HU','SK','GR','FR','IT-NORTH','ES']:
    g=p[(p.zone==z)&(p.hour>=17)&(p.hour<=19)]
    print(z, 'settled', round(np.polyfit(g.margin,g.settled,1)[0]*0.1,1), 'model', round(np.polyfit(g.margin,g.sim37,1)[0]*0.1,1), 'n',len(g), 'margin p10/p50/p90', g.margin.quantile([.1,.5,.9]).round(2).tolist())
