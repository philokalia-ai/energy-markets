"""#392 supersede: a pinned physics base with no rows skips ONLY the hybrid line.

Runs without Postgres or data/: the emitter module is loaded with stubbed heavy
imports where missing, and `lines_for_day` is fed synthetic frames.
Standalone:  python3 test/test_emit_model_lines_pin.py
"""
import datetime as dt
import importlib.util
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path

import numpy as np
import pandas as pd

for mod in ("psycopg2", "joblib", "duckdb"):           # not needed by lines_for_day
    if importlib.util.find_spec(mod) is None:
        sys.modules[mod] = types.ModuleType(mod)
if importlib.util.find_spec("sklearn") is None:
    sk = types.ModuleType("sklearn"); ens = types.ModuleType("sklearn.ensemble")
    ens.HistGradientBoostingRegressor = object
    sys.modules["sklearn"] = sk; sys.modules["sklearn.ensemble"] = ens

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("emit_model_lines", ROOT / "bin" / "emit_model_lines.py")
eml = importlib.util.module_from_spec(spec)
spec.loader.exec_module(eml)


class Const:
    def __init__(self, v): self.v = v
    def predict(self, X): return np.full(len(X), self.v)


T = dt.date(2026, 11, 14)


def frames(base_versions):
    """feats for GR/BG on T; physics base rows at the given versions (freshest wins)."""
    ks = [f"{T}T{h:02d}" for h in range(24)]
    feats = pd.DataFrame([dict(zone=z, k=k, D=5000., res_sh=.3, imp_sh=.1, bst_sh=0., margin=1.4)
                          for z in ("GR", "BG") for k in ks])
    base = pd.DataFrame([dict(zone=z, t=pd.Timestamp(k + ":00", tz="UTC"), sim=100., base_cv=cv, k=k)
                         for cv in base_versions for z in ("GR", "BG") for k in ks],
                        columns=["zone", "t", "sim", "base_cv", "k"])
    t = pd.date_range(pd.Timestamp(T) - pd.Timedelta(days=10), pd.Timestamp(T), freq="h",
                      tz="UTC", inclusive="left")
    st = pd.concat([pd.DataFrame(dict(zone=z, t=t, p=90.)) for z in ("GR", "BG")], ignore_index=True)
    return feats, base, st


class PinTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        for f in ("probe_ttf.csv", "probe_eua.csv"):
            with open(os.path.join(self.tmp.name, f), "w") as fh:
                fh.write("2026-11-01 00:00:00,30.0\n")
        self._train = eml.TRAIN; eml.TRAIN = self.tmp.name
        self.models = {"hybrid": {"GR": Const(5.), "BG": Const(5.)},
                       "stats": {"GR": Const(77.), "BG": Const(77.)}}

    def tearDown(self):
        eml.TRAIN = self._train; self.tmp.cleanup()

    def run_day(self, base_h, base_any, st, feats, last_settled=T):
        return eml.lines_for_day(T, feats, base_h, base_any, st, last_settled, self.models)

    def test_pinned_base_empty_keeps_stats(self):
        # production today: only cv43 forecasts, artifact pinned to cv37
        feats, base_any, st = frames([43])
        base_h = base_any[base_any.base_cv == 37]
        rows, hyb, sta = self.run_day(base_h, base_any, st, feats)
        self.assertTrue(hyb.startswith("SKIPPED"))
        self.assertEqual(sta, "emitted")
        self.assertEqual({r[2] for r in rows}, {"stats_gbm"})
        self.assertEqual(len(rows), 48)
        self.assertTrue(all(r[5] is None for r in rows))       # stats has no base
        self.assertTrue(all(r[3] == 77. for r in rows))

    def test_pinned_base_present_emits_both(self):
        feats, base_any, st = frames([37])
        rows, hyb, sta = self.run_day(base_any, base_any, st, feats)
        self.assertEqual((hyb, sta), ("emitted", "emitted"))
        h = [r for r in rows if r[2] == "hybrid_gbm"]
        self.assertEqual(len(h), 48)
        self.assertTrue(all(r[3] == 105. and r[5] == 37 for r in h))

    def test_no_forecast_at_all_emits_nothing(self):
        feats, base_any, st = frames([])
        rows, hyb, sta = self.run_day(base_any, base_any, st, feats)
        self.assertEqual(rows, [])
        self.assertTrue(hyb.startswith("SKIPPED"))
        self.assertTrue(sta.startswith("skipped"))

    def test_stats_not_due_beyond_lag24(self):
        feats, base_any, st = frames([43])
        rows, hyb, sta = self.run_day(base_any[base_any.base_cv == 37], base_any, st, feats,
                                      last_settled=T - dt.timedelta(days=3))
        self.assertEqual(rows, [])
        self.assertTrue(sta.startswith("not due"))

    def test_main_does_not_systemexit_on_empty_pin(self):
        src = (ROOT / "bin" / "emit_model_lines.py").read_text()
        body = src[src.index("def main():"):]
        self.assertNotIn("SystemExit", body)



class AsOfTest(PinTest):
    def setUp(self):
        super().setUp()
        self.issue = eml.utc_issue('2026-11-13T10:40:00Z')

    def test_last_settled_is_per_zone_and_early_exaa_cannot_advance_it(self):
        st = pd.DataFrame({'zone': ['GR', 'AT'],
                           't': pd.to_datetime(['2026-11-11T23:00Z', '2026-11-14T23:00Z']),
                           'p': [90., 120.]})
        self.assertEqual(eml.zone_last_settled(st, self.issue),
                         {'GR': dt.date(2026, 11, 12), 'AT': dt.date(2026, 11, 13)})

    def test_one_zones_settlement_does_not_authorize_another(self):
        feats, base, st = frames([37])
        rows, _, _ = self.run_day(base, base, st, feats,
                                  {'GR': T - dt.timedelta(days=1), 'BG': T - dt.timedelta(days=3)})
        self.assertEqual({r[0] for r in rows if r[2] == 'stats_gbm'}, {'GR'})

    def test_early_exaa_has_one_auction_and_no_d2_stats(self):
        from unittest.mock import patch
        raw = pd.DataFrame([dict(z='AT', seq=seq, res='PT60M', t=t, p=p,
                                 u='2026-11-13T09:00:00Z')
                            for t in pd.date_range('2026-11-03', '2026-11-15', freq='h', inclusive='left')
                            for seq, p in [('1', 100.), ('2', 120.)]])
        with patch.object(eml, 'target_helper', return_value=None), patch.dict(os.environ, {'EUPHEMIA_DA_TARGET':'highest_seq'}):
            st = eml.canonical_settled(raw)
        self.assertEqual(set(st.p), {120.})
        feats, base, _ = frames([37])
        feats['zone'] = 'AT'; feats = feats.drop_duplicates(['zone','k'])
        base['zone'] = 'AT'; base = base.drop_duplicates(['zone','k'])
        models = {'hybrid':{}, 'stats':{'AT':Const(1.)}}
        d2_issue = eml.utc_issue('2026-11-12T10:40:00Z')
        rows, _, sta = eml.lines_for_day(T, feats, base, base, st,
                                         eml.zone_last_settled(st, d2_issue), models, d2_issue)
        self.assertEqual(rows, [])
        self.assertTrue(sta.startswith('not due'))

    def test_athens_cell_cap_across_winter_and_summer_midnight(self):
        # The previous UTC-date cap leaked two winter / three summer D+2 cells.
        for issue_text, boundary_hour in [('2026-11-13T10:40Z',22),
                                          ('2026-07-13T10:40Z',21),
                                          ('2026-11-13T22:30Z',22),
                                          ('2026-07-13T21:30Z',21)]:
            with self.subTest(issue=issue_text):
                issue=eml.utc_issue(issue_text)
                day=eml.market_date(issue)+dt.timedelta(days=1)
                hours=pd.date_range(str(day),periods=24,freq='h',tz='UTC')
                base=pd.DataFrame({'zone':'AT','t':hours,'k':hours.strftime('%Y-%m-%dT%H'),
                                   'base_cv':44,'sim':100.,'prediction_made_utc':issue})
                feats=base[['zone','k']].assign(D=5000.,res_sh=.3,imp_sh=.1,bst_sh=0.,margin=1.4)
                # Includes the early EXAA market day, so every elapsed-hour lag exists.
                history=pd.date_range(pd.Timestamp(day,tz='UTC')-pd.Timedelta(days=12),
                                      pd.Timestamp(day,tz='UTC'),freq='h',inclusive='left')
                st=pd.DataFrame({'zone':'AT','t':history,'p':120.})
                rows,_,_=eml.lines_for_day(day,feats,base.iloc[:0],base,st,
                    eml.zone_last_settled(st,issue),{'hybrid':{},'stats':{'AT':Const(120.)}},issue)
                self.assertEqual(len(rows),boundary_hour)
                self.assertEqual([pd.Timestamp(r[1]).hour for r in rows],list(range(boundary_hour)))
                self.assertTrue(all(eml.market_date(r[1])==day for r in rows))
                self.assertTrue(all(eml.market_date(r[1])<=eml.market_date(issue)+dt.timedelta(days=1)
                                    for r in rows))

    def test_strict_gate_uses_each_cells_athens_delivery_day(self):
        for text, boundary_hour in [('2026-11-13T10:40Z',22),('2026-07-13T09:40Z',21)]:
            with self.subTest(issue=text):
                issue=eml.utc_issue(text)
                day=issue.date()
                hours=pd.date_range(str(day),periods=24,freq='h',tz='UTC')
                base=pd.DataFrame({'zone':'AT','t':hours,'k':hours.strftime('%Y-%m-%dT%H'),
                                   'base_cv':44,'sim':100.,'prediction_made_utc':issue})
                feats=base[['zone','k']].assign(D=5000.,res_sh=.3,imp_sh=.1,bst_sh=0.,margin=1.4)
                history=pd.date_range(pd.Timestamp(day,tz='UTC')-pd.Timedelta(days=12),
                                      pd.Timestamp(day,tz='UTC'),freq='h',inclusive='left')
                st=pd.DataFrame({'zone':'AT','t':history,'p':120.})
                models={'hybrid':{},'stats':{'AT':Const(120.)}}
                rows,_,_=eml.lines_for_day(day,feats,base.iloc[:0],base,st,
                    eml.zone_last_settled(st,issue),models,issue,True)
                self.assertEqual([pd.Timestamp(r[1]).hour for r in rows],list(range(boundary_hour,24)))
                self.assertTrue(all(eml.market_date(r[1])==eml.market_date(issue)+dt.timedelta(days=1)
                                    for r in rows))
                closed=eml.gate_utc(eml.market_date(issue)+dt.timedelta(days=1))
                rows,_,_=eml.lines_for_day(day,feats,base.iloc[:0],base,st,
                    eml.zone_last_settled(st,closed),models,closed,True)
                self.assertEqual(rows,[])

    def test_revision_filter_precedes_canonical_selection(self):
        from unittest.mock import patch
        raw = pd.DataFrame([dict(z='GR', seq='1', res='PT60M', t='2026-11-12T00:00Z',
                                 p=p, u=u) for p,u in [(80.,'2026-11-12T09:00Z'),
                                                       (999.,'2026-11-14T09:00Z')]])
        with patch.object(eml,'target_helper',return_value=None), patch.dict(os.environ,{'EUPHEMIA_DA_TARGET':'highest_seq'}):
            self.assertEqual(eml.canonical_settled(raw).p.tolist(), [999.])
            self.assertEqual(eml.canonical_settled(raw,self.issue).p.tolist(), [80.])
            raw['u'] = None
            self.assertTrue(eml.canonical_settled(raw,self.issue).empty)
            # A partially unverifiable zone must not be passed as authenticated.
            raw.loc[0,'u'] = '2026-11-12T09:00Z'
            self.assertTrue(eml.canonical_settled(raw,self.issue).empty)

    def test_missing_helper_fails_on_sdac_and_unknown_policy(self):
        from unittest.mock import patch
        with patch.object(eml,'target_helper',return_value=None):
            for value in ('sdac','wrong'):
                with patch.dict(os.environ,{'EUPHEMIA_DA_TARGET':value}), self.assertRaises(ValueError):
                    eml.target_policy()

    def test_helper_api_is_used(self):
        from unittest.mock import patch, Mock
        act = pd.DataFrame({'z':['GR'],'t':[pd.Timestamp('2026-11-12')],'act':[42.]})
        helper = Mock(); helper.policy.return_value = 'sdac'
        helper.sdac_hourly.return_value = (act,pd.DataFrame(),pd.DataFrame())
        raw = pd.DataFrame(columns=['z','seq','res','t','p','u'])
        with patch.object(eml,'target_helper',return_value=helper):
            self.assertEqual(eml.canonical_settled(raw).p.tolist(),[42.])
        helper.sdac_hourly.assert_called_once()
        helper.highest_seq_hourly.assert_not_called()

    def test_future_physics_is_excluded_and_stats_stays_independent(self):
        feats, base, st = frames([37])
        base['prediction_made_utc'] = pd.Timestamp('2026-11-13T11:00Z')
        rows, _, _ = eml.lines_for_day(T,feats,base,base,st,eml.zone_last_settled(st,self.issue),
                                       self.models,self.issue,True)
        self.assertEqual(rows,[])  # both domains require an available forecast
        missing=base.drop(columns='prediction_made_utc')
        rows,_,_=eml.lines_for_day(T,feats,missing,missing,st,eml.zone_last_settled(st,self.issue),
                                   self.models,self.issue,True)
        self.assertEqual(rows,[])
        base['prediction_made_utc'] = self.issue
        rows, _, _ = eml.lines_for_day(T,feats,base,base,st,eml.zone_last_settled(st,self.issue),
                                       self.models,self.issue,True)
        self.assertEqual(len(rows),92)  # last two UTC hours in each zone are Athens D+2
        rows2, _, _ = eml.lines_for_day(T,feats,base.iloc[:0],base,st,
                                        eml.zone_last_settled(st,self.issue),self.models,self.issue,True)
        self.assertEqual({r[2] for r in rows2},{'stats_gbm'})

    def test_gate_dst_midnight_and_backfill_override(self):
        self.assertEqual(eml.gate_utc(dt.date(2026,3,30)),pd.Timestamp('2026-03-29T10:00Z'))
        self.assertEqual(eml.gate_utc(dt.date(2026,10,26)),pd.Timestamp('2026-10-25T11:00Z'))
        self.assertFalse(eml.may_emit(T,'2026-11-13T11:00Z',True))
        self.assertTrue(eml.may_emit(T,'2026-11-13T10:59:59Z',True))
        self.assertTrue(eml.may_emit(T,'2026-11-14T00:00Z',True,True))
        self.assertFalse(eml.may_emit(T,'2026-11-14T00:00Z',True))
        self.assertEqual(eml.utc_issue('2026-11-14T01:00+02:00').date(),dt.date(2026,11,13))
        with self.assertRaises(ValueError): eml.utc_issue('2026-11-14T00:00')

    def test_strict_does_not_emit_past_day(self):
        feats,base,st=frames([37])
        rows,_,_=eml.lines_for_day(T,feats,base,base,st,{},self.models,
                                   eml.utc_issue('2026-11-14T10:40Z'),True)
        self.assertEqual(rows,[])

    def test_metadata_is_exact_and_replay_is_idempotent(self):
        feats,base,st=frames([37]);base['prediction_made_utc']=self.issue
        rows,_,_=self.run_day(base,base,st,feats)
        a=eml.provenance_rows(rows,base,self.issue,7,False)
        b=eml.provenance_rows(rows,base,self.issue,7,False)
        self.assertEqual(a,b)
        import json
        for r in a:
            self.assertEqual(r[6],self.issue.to_pydatetime())
            m=json.loads(r[7])
            self.assertEqual(m['base_code_version'],r[5])
            self.assertEqual(m['physics_prediction_made_utc'],self.issue.isoformat() if r[2]=='hybrid_gbm' else None)


    def test_strict_is_default_and_only_zero_disables_it(self):
        self.assertTrue(eml.strict_asof({}))
        self.assertTrue(eml.strict_asof({'MODEL_LINES_STRICT_ASOF':'1'}))
        self.assertTrue(eml.strict_asof({'MODEL_LINES_STRICT_ASOF':''}))
        self.assertFalse(eml.strict_asof({'MODEL_LINES_STRICT_ASOF':'0'}))

    def test_main_default_and_zero_kill_switch_wiring(self):
        from unittest.mock import patch, Mock
        import io
        from contextlib import redirect_stdout
        feats,base,st=frames([37]);base['prediction_made_utc']=self.issue
        expected,_,_=eml.lines_for_day(T,feats,base,base,st,
            eml.zone_last_settled(st,self.issue),self.models,self.issue,False)
        expected=eml.provenance_rows(expected,base,self.issue,7,False)
        original_issue=eml.utc_issue
        for flag,strict in [(None,True),('0',False)]:
            with self.subTest(flag=flag):
                cx=Mock();log=io.StringIO()
                env={} if flag is None else {'MODEL_LINES_STRICT_ASOF':flag}
                with patch.dict(os.environ,env,clear=True), \
                     patch.object(sys,'argv',['emit_model_lines.py',str(T),str(T)]), \
                     patch.object(eml,'utc_issue',side_effect=lambda v=None:self.issue if v is None else original_issue(v)), \
                     patch.object(eml,'load_models',return_value=self.models), \
                     patch.object(eml,'conn',return_value=cx), \
                     patch.object(eml,'refresh_fuel_csvs'), \
                     patch.object(eml,'physics_base',return_value=base) as physics, \
                     patch.object(eml,'settled_history',return_value=st) as settled, \
                     patch.object(eml,'features_for',return_value=(feats,7)), \
                     patch.object(eml,'ensure_metadata_columns',return_value=True), \
                     redirect_stdout(log):
                    eml.main()
                self.assertTrue(all(c.args[-1]==(self.issue if strict else None)
                                    for c in physics.call_args_list))
                self.assertEqual(settled.call_args.args[-1],self.issue if strict else None)
                sql,rows=cx.cursor.return_value.executemany.call_args.args
                self.assertEqual(sql,eml.UPSERT_STRICT_SQL if strict else eml.UPSERT_SQL)
                if not strict:
                    self.assertEqual(rows,expected)  # exact #439 False-path rows + metadata
                self.assertEqual(log.getvalue().count('model lines gate:'),1)
                self.assertIn(f'strict_asof={strict}',log.getvalue())

    def test_gate_log_counts_next_day_weather_domain(self):
        for issue,ts,kept,dropped in [
            ('2026-11-13T10:40Z',['2026-11-13T22:00Z','2026-11-14T00:00Z','2026-11-14T22:00Z'],2,0),
            ('2026-07-13T10:40Z',['2026-07-13T21:00Z','2026-07-14T00:00Z','2026-07-14T21:00Z'],0,2)]:
            base=pd.DataFrame({'t':pd.to_datetime(ts)})
            text=eml.gate_run_summary(base,eml.utc_issue(issue),True)
            self.assertIn(f'cells_kept={kept} cells_dropped={dropped}',text)
            self.assertIn('scope=next_day_weather_cells',text)
            self.assertIn('gate_utc=',text);self.assertIn('issue_utc=',text)
            self.assertIn('cells_kept=2 cells_dropped=0',eml.gate_run_summary(base,eml.utc_issue(issue),False))
            self.assertIn('cells_kept=2 cells_dropped=0',eml.gate_run_summary(base,eml.utc_issue(issue),True,True))


class MetadataDDLTest(unittest.TestCase):
    def test_catalog_first_and_bounded_transaction(self):
        from unittest.mock import Mock
        cx=Mock();cur=cx.cursor.return_value
        cur.fetchall.return_value=[(c,) for c in eml.MODEL_LINE_COLUMNS]
        self.assertTrue(eml.ensure_metadata_columns(cx))
        self.assertEqual(cur.execute.call_count,1)
        cx.commit.assert_not_called()
        cur.reset_mock();cur.fetchall.return_value=[('base_code_version',)]
        self.assertTrue(eml.ensure_metadata_columns(cx))
        sql=[call.args[0] for call in cur.execute.call_args_list]
        self.assertIn("SET LOCAL lock_timeout = '5s'",sql)
        ddl=next(s for s in sql if s.startswith('ALTER'))
        self.assertIn('issue_utc timestamptz',ddl)
        self.assertIn('source_manifest jsonb',ddl)
        self.assertNotIn('base_code_version integer',ddl)

    def test_migration_failure_rolls_back(self):
        from unittest.mock import Mock
        cx=Mock();cur=cx.cursor.return_value;cur.fetchall.return_value=[]
        def execute(sql):
            if sql.startswith('ALTER'): raise RuntimeError('lock timeout')
        cur.execute.side_effect=execute
        self.assertFalse(eml.ensure_metadata_columns(cx))
        cx.rollback.assert_called_once()



class PhysicsSQLTest(unittest.TestCase):
    @unittest.skipUnless(hasattr(sys.modules.get('duckdb'),'connect'), 'DuckDB optional for SQL fixture')
    def test_cutoff_precedes_winning_vintage_selection(self):
        import duckdb
        cx=duckdb.connect(':memory:')
        cx.execute('CREATE SCHEMA simulations')
        cx.execute('''CREATE TABLE simulations.forecast_prices (
            bidding_zone VARCHAR,date_time_utc TIMESTAMPTZ,price_eur_mwh DOUBLE,
            code_version INTEGER,prediction_made_utc TIMESTAMPTZ,lead_days INTEGER,input_mode VARCHAR,
            is_retro BOOLEAN)''')
        cx.execute("""INSERT INTO simulations.forecast_prices VALUES
            ('GR','2026-11-14T00:00Z',80,37,'2026-11-12T06:30Z',2,'weather',FALSE),
            ('GR','2026-11-14T00:00Z',999,37,'2026-11-13T18:00Z',1,'weather',FALSE)""")
        class Cursor:
            def execute(self,sql,args):cx.execute(sql.replace('%s','?').replace('%%','%'),args)
            def fetchall(self):return cx.fetchall()
        cur=Cursor()
        self.assertEqual(eml.physics_base(cur,T,T,37).sim.tolist(),[999.])
        self.assertEqual(eml.physics_base(cur,T,T,37,eml.utc_issue('2026-11-13T10:40Z')).sim.tolist(),[80.])
        cx.close()

    @unittest.skipUnless(hasattr(sys.modules.get('duckdb'),'connect'), 'DuckDB optional for SQL fixture')
    def test_reconstructed_rows_never_supply_physics_or_stats_domain(self):
        import duckdb
        cx=duckdb.connect(':memory:')
        cx.execute('CREATE SCHEMA simulations')
        cx.execute('''CREATE TABLE simulations.forecast_prices (
            bidding_zone VARCHAR,date_time_utc TIMESTAMPTZ,price_eur_mwh DOUBLE,
            code_version INTEGER,prediction_made_utc TIMESTAMPTZ,lead_days INTEGER,
            input_mode VARCHAR,is_retro BOOLEAN)''')
        cx.execute("""INSERT INTO simulations.forecast_prices VALUES
            ('GR','2026-11-14T00:00Z',80,37,'2026-11-12T06:30Z',2,'weather',FALSE),
            ('GR','2026-11-14T01:00Z',70,37,'2026-11-12T06:30Z',2,'weather',NULL),
            ('GR','2026-11-14T00:00Z',999,37,'2026-11-13T09:00Z',1,'weather',TRUE),
            ('GR','2026-11-14T01:00Z',999,37,'2026-11-13T09:00Z',1,'weather',TRUE),
            ('BG','2026-11-14T00:00Z',555,37,'2026-11-13T09:00Z',1,'weather',TRUE)""")
        class Cursor:
            def execute(self,sql,args):cx.execute(sql.replace('%s','?').replace('%%','%'),args)
            def fetchall(self):return cx.fetchall()
        for pin in (None,37):
            for issue in (None,eml.utc_issue('2026-11-13T10:40Z')):
                with self.subTest(pin=pin,issue=issue):
                    base=eml.physics_base(Cursor(),T,T,pin,issue).sort_values('k')
                    self.assertEqual(base.zone.tolist(),['GR','GR'])
                    self.assertEqual(base.sim.tolist(),[80.,70.])
        cx.close()

    def test_atomic_write_guard_is_only_on_strict_path(self):
        self.assertNotIn('clock_timestamp',eml.UPSERT_SQL)
        self.assertIn('WHERE clock_timestamp() < %s',eml.UPSERT_STRICT_SQL)
        self.assertNotIn('VALUES (',eml.UPSERT_STRICT_SQL)
        self.assertEqual(eml.UPSERT_STRICT_SQL.count('%s'),10)
        self.assertIn('AND clock_timestamp() < %s',eml.UPSERT_STRICT_SQL)


    @unittest.skipUnless(hasattr(sys.modules.get('duckdb'),'connect'), 'DuckDB optional for SQL fixture')
    def test_atomic_guard_blocks_both_insert_and_overwrite_after_gate(self):
        import duckdb
        cx=duckdb.connect(':memory:')
        now=eml.utc_issue('2026-11-13T11:00Z').to_pydatetime()
        cx.create_function('clock_timestamp',lambda:now,return_type='TIMESTAMPTZ',side_effects=True)
        cx.execute('CREATE SCHEMA simulations')
        cx.execute('''CREATE TABLE simulations.model_lines (
            bidding_zone VARCHAR,date_time_utc TIMESTAMPTZ,model VARCHAR,price_eur_mwh DOUBLE,
            code_version INTEGER,base_code_version INTEGER,issue_utc TIMESTAMPTZ,source_manifest JSON,
            generated_at TIMESTAMPTZ DEFAULT now(),
            UNIQUE(bidding_zone,date_time_utc,model,code_version))''')
        row=('GR','2026-11-14T00:00:00Z','hybrid_gbm',80.,37,37,now,'{}')
        sql=eml.UPSERT_STRICT_SQL.replace('%s','?').replace('::jsonb','::JSON')
        cx.execute(sql,(*row,*([eml.utc_issue('2026-11-13T10:00Z').to_pydatetime()]*2)))
        self.assertEqual(cx.execute('SELECT count(*) FROM simulations.model_lines').fetchone()[0],0)
        cx.execute(sql,(*row,*([eml.utc_issue('2026-11-13T12:00Z').to_pydatetime()]*2)))
        cx.execute(sql,(*row[:3],999.,*row[4:],*([eml.utc_issue('2026-11-13T10:00Z').to_pydatetime()]*2)))
        self.assertEqual(cx.execute('SELECT price_eur_mwh FROM simulations.model_lines').fetchone()[0],80.)
        cx.close()


if __name__ == "__main__":
    unittest.main()
