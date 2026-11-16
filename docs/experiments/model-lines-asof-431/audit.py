#!/usr/bin/env python3
"""Offline source-coverage/lag audit; probe outputs are NOT frozen GBM forecasts."""
import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import sys
import tempfile
from pathlib import Path

import duckdb
import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'bin'))
import emit_model_lines as eml


class Cursor:
    """Translate emitter's parameter placeholders for a private in-memory DB."""
    def __init__(self, con): self.con = con
    def execute(self, sql, args=()):
        self.con.execute(sql.replace('%s', '?').replace('%%', '%').replace('::jsonb', '::JSON'), args)
    def fetchall(self): return self.con.fetchall()


class Probe:
    def __init__(self, lag=False): self.lag = lag
    def predict(self, x): return x.lag24.to_numpy() if self.lag else np.zeros(len(x))


def live_forecasts(directory, start, end):
    rows = []
    hashes = {}
    for path in sorted(Path(directory).glob('*.json')):
        hashes[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
        obj = json.loads(path.read_text())
        for day in obj['days']:
            if not day['input_mode'].startswith('weather'): continue
            for t, price in zip(day['hours'], day['sim']):
                stamp = pd.Timestamp(t)
                if start <= stamp.date() <= end and price is not None:
                    rows.append((obj['zone'], stamp, float(price), int(day['code_version']),
                                 pd.Timestamp(day.get('prediction_made_utc')),
                                 int(day['lead_days']), day['input_mode']))
    return pd.DataFrame(rows, columns=['bidding_zone', 'date_time_utc', 'price_eur_mwh',
                        'code_version', 'prediction_made_utc', 'lead_days', 'input_mode']), hashes


def keys(rows): return {(r[0],r[1],r[2],r[4]) for r in rows}


def coverage(rows, issue):
    counts = {}
    for r in rows:
        key = f'{r[0]}/{r[2]}/lead{(eml.market_date(r[1])-eml.market_date(issue)).days}'
        counts[key] = counts.get(key,0)+1
    return dict(sorted(counts.items()))


def run_days(issue, base_h, base_any, st, strict, zones, legacy=False):
    out = []
    models = {'hybrid':{z:Probe() for z in zones}, 'stats':{z:Probe(True) for z in zones}}
    last = st.t.max().date() if legacy else eml.zone_last_settled(st,issue)
    for lead in range(-2,8):
        day = issue.date()+dt.timedelta(days=lead)
        feats = base_any[base_any.k.str[:10] == day.isoformat()][['zone','k']].copy()
        for col,val in [('D',5000.),('res_sh',.3),('imp_sh',.1),('bst_sh',0.),('margin',1.4)]:
            feats[col]=val
        rows,_,_=eml.lines_for_day(day,feats,base_h,base_any,st,last,models,
                                   issue=None if legacy else issue,strict=strict)
        out.extend(eml.provenance_rows(rows,base_h,issue,7,strict))
    return out


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--extract',required=True)
    ap.add_argument('--live',required=True)
    ap.add_argument('--output',required=True)
    ap.add_argument('--target-helper',help='Optional unmerged PR C bin/da_target.py, loaded without copying')
    ap.add_argument('--issues',nargs='+',default=['2026-09-19T10:40Z','2026-10-24T10:40Z','2026-11-13T10:40Z'])
    ap.add_argument('--base-cv',type=int,default=eml.BASE_CV)
    args=ap.parse_args()
    if args.target_helper:
        spec=importlib.util.spec_from_file_location('da_target',args.target_helper)
        helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper)
        sys.modules['da_target']=helper
    issues=[eml.utc_issue(v) for v in args.issues]
    live,hashes=live_forecasts(args.live,min(i.date() for i in issues)-dt.timedelta(days=2),
                              max(i.date() for i in issues)+dt.timedelta(days=7))
    con=duckdb.connect(':memory:',config={'threads':4})
    con.register('live_frame',live)
    con.execute('CREATE SCHEMA simulations')
    con.execute('CREATE TABLE simulations.forecast_prices AS SELECT * FROM live_frame')
    con.execute('''CREATE TABLE simulations.model_lines (
        bidding_zone VARCHAR,date_time_utc TIMESTAMPTZ,model VARCHAR,price_eur_mwh DOUBLE,
        code_version INTEGER,base_code_version INTEGER,issue_utc TIMESTAMPTZ,source_manifest JSON,
        generated_at TIMESTAMPTZ DEFAULT now(),
        UNIQUE(bidding_zone,date_time_utc,model,code_version))''')
    cur=Cursor(con)
    extract=duckdb.connect(args.extract,read_only=True,config={'threads':4})
    report={'kind':'source-coverage and lag24 probe, NOT trained-GBM price validation',
            'extract':str(Path(args.extract).resolve()),'live_sha256':hashes,
            'base_cv':args.base_cv,'target_policy':eml.target_policy(),
            'delivery_day_timezone':'Europe/Athens','configured_strict_asof':eml.strict_asof(),
            'target_helper_sha256':hashlib.sha256(Path(args.target_helper).read_bytes()).hexdigest() if args.target_helper else None,
            'book_and_model_coverage_assumption':'all available forecast cells have book features and a model; synthetic fundamentals',
            'versions':{'duckdb':duckdb.__version__,'pandas':pd.__version__},'issues':[]}
    with tempfile.TemporaryDirectory() as td:
        eml.TRAIN=td
        for filename in ('probe_ttf.csv','probe_eua.csv'):
            Path(td,filename).write_text('2026-01-01 00:00:00,30.0\n')
        for issue in issues:
            d0=issue.date()-dt.timedelta(days=2);d1=issue.date()+dt.timedelta(days=7)
            raw=extract.execute('''SELECT map_code z,sequence seq,resolution_code res,
                date_time_utc t,price_currency_mwh p,update_time_utc u
                FROM entsoe.energy_prices
                WHERE contract_type='Day-ahead' AND currency='EUR' AND area_type_code LIKE 'BZN%'
                  AND price_currency_mwh IS NOT NULL AND date_time_utc>=? AND date_time_utc<?''',
                [d0-dt.timedelta(days=10),d1+dt.timedelta(days=1)]).df()
            settled=eml.canonical_settled(raw)
            strict_settled=eml.canonical_settled(raw,issue)
            old_st=extract.execute('''SELECT map_code zone,date_time_utc t,AVG(price_currency_mwh) p
                FROM entsoe.energy_prices WHERE contract_type='Day-ahead' AND currency='EUR'
                AND date_time_utc>=? AND date_time_utc<? GROUP BY 1,2''',
                [d0-dt.timedelta(days=10),d1+dt.timedelta(days=1)]).df()
            old_st['t']=pd.to_datetime(old_st.t,utc=True)
            old_st=old_st.sort_values(['zone','t']).reset_index(drop=True)
            print(f'{issue.isoformat()}: settled {len(raw)} rows loaded', flush=True)
            bases=[eml.physics_base(cur,d0,d1,pin,cut) for cut in (None,issue) for pin in (None,args.base_cv)]
            any_base,pinned,strict_any,strict_pinned=bases
            zones=sorted(any_base.zone.unique())
            old=run_days(issue,pinned,any_base,old_st,False,zones,True)
            default=run_days(issue,pinned,any_base,settled,False,zones)
            strict=run_days(issue,strict_pinned,strict_any,strict_settled,True,zones)
            mode=eml.strict_asof()
            configured=run_days(issue,strict_pinned if mode else pinned,
                                strict_any if mode else any_base,
                                strict_settled if mode else settled,mode,zones)
            assert configured == (strict if mode else default)
            # SQL row order is unspecified; hash complete cells in primary-key order.
            digest=lambda rows:hashlib.sha256(json.dumps(sorted(rows,key=lambda r:(r[0],r[1],r[2],r[4])),
                                                        default=str,separators=(',',':')).encode()).hexdigest()
            assert all(eml.market_date(r[1])>eml.market_date(issue) for r in strict)
            for rows in (default,strict):
                assert not any(r[2]=='stats_gbm'
                               and eml.market_date(r[1])>=eml.market_date(issue)+dt.timedelta(days=2) for r in rows)
                assert all(r[6]==issue.to_pydatetime() for r in rows)
                con.execute('DELETE FROM simulations.model_lines')
                columns=['bidding_zone','date_time_utc','model','price_eur_mwh','code_version',
                         'base_code_version','issue_utc','source_manifest']
                batch=pd.DataFrame(rows,columns=columns)
                con.register('audit_rows',batch)
                sql=eml.UPSERT_SQL.replace('VALUES (%s, %s, %s, %s, %s, %s, %s, %s::jsonb)',
                    'SELECT bidding_zone, date_time_utc::TIMESTAMPTZ, model, price_eur_mwh, '
                    'code_version, base_code_version, issue_utc::TIMESTAMPTZ, source_manifest::JSON '
                    'FROM audit_rows WHERE TRUE')
                if rows: con.execute(sql)
                first=con.execute('SELECT * FROM simulations.model_lines ORDER BY ALL').fetchall()
                if rows: con.execute(sql)
                assert first==con.execute('SELECT * FROM simulations.model_lines ORDER BY ALL').fetchall()
            assert default==run_days(issue,pinned,any_base,settled,False,zones)
            assert strict==run_days(issue,strict_pinned,strict_any,strict_settled,True,zones)
            joined=old_st.merge(settled,on=['zone','t'],suffixes=('_old','_new'))
            lag_delta={}
            for z in zones:
                delivery_day=(joined.t+pd.Timedelta(hours=24)).dt.tz_convert('Europe/Athens').dt.date
                g=joined[(joined.zone==z)&(delivery_day==eml.market_date(issue)+dt.timedelta(days=1))]
                delta=g.p_new-g.p_old
                lag_delta[z]={'lag24_cells':len(g),'changed':int((delta.abs()>1e-8).sum()),
                              'mean_delta':float(delta.mean()),'mean_abs_delta':float(delta.abs().mean()),
                              'max_abs_delta':float(delta.abs().max())}
            old_map={(r[0],r[1],r[2],r[4]):r[3] for r in old}
            impact={}
            for z in ('AT','DE_LU'):
                delta=[r[3]-old_map[(r[0],r[1],r[2],r[4])] for r in default
                       if r[0]==z and r[2]=='stats_gbm' and (r[0],r[1],r[2],r[4]) in old_map]
                impact[z]={'probe_common_cells':len(delta),'mean_abs_lag24_delta':float(np.abs(delta).mean()) if delta else None}
            lost=keys(default)-keys(strict)
            print(f'{issue.isoformat()}: default={len(default)} strict={len(strict)}; checks pass', flush=True)
            report['issues'].append({'issue_utc':issue.isoformat(),'default_rows':len(default),'strict_rows':len(strict),
                'configured_rows':len(configured),'configured_output_sha256':digest(configured),
                'kill_switch_output_sha256':digest(default),'strict_output_sha256':digest(strict),
                'legacy_probe_rows':len(old),'default_by_zone_model_lead':coverage(default,issue),
                'strict_by_zone_model_lead':coverage(strict,issue),
                'strict_lost_by_zone_model_lead':coverage([r for r in default if (r[0],r[1],r[2],r[4]) in lost],issue),
                'settled_raw_rows':len(raw),'settled_hours':len(settled),'settled_hours_at_issue':len(strict_settled),
                'lag24_delta_for_next_day':lag_delta,'stats_probe_input_impact':impact,
                'checks':{'no_strict_past':True,'no_at_de_d2':True,'no_market_d2_stats':True,'issue_set':True,'idempotent':True}})
    Path(args.output).write_text(json.dumps(report,indent=2,sort_keys=True)+'\n')
    for row in report['issues']:
        print(row['issue_utc'],row['default_rows'],row['strict_rows'], {z:row['lag24_delta_for_next_day'][z] for z in ('AT','DE_LU')})


if __name__=='__main__':main()
