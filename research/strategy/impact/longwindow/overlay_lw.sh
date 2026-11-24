#!/bin/bash
# Long-window Timestral post-sim overlay, both arms, ONE scope (36G, cores 40-79), em-tsfm 14370a8, as cv46 combined.sh
# step 5 / comb/overlay.sh. Window 2025-10-01..END (END = 2026-08-31 when the arm's 07-02..11-14 export equals the
# existing one, whose 09-01..11-14 overlay is then copied in; else 2026-11-14). Physics from 2025-08-02.
EM=$HOME/armada/em-team; L=$EM/strategy/runs/st-impact/r2/long; TS=$HOME/armada/em-tsfm; TSD=docs/experiments/tsfm-2y-backtest
[ "$(git -C $TS rev-parse --short HEAD)" = 14370a8 ] || { echo "em-tsfm HEAD is not 14370a8"; exit 2; }
grep -q POST-RECORDS-END $L/post_records.md || { echo "post_records not done"; exit 2; }
declare -A SRC=([base]=$EM/cv46-physics/runs/cp-runs/combined-pr-74d9fc3/tsfm-PR/postsim [cand]=$EM/strategy/runs/st-impact/r2/comb/tsfm-SHAPE/postsim)
for a in base cand; do echo "ALLDONE" > $L/phys-$a.done; done
sleep 150   # run_tsfm.physics_files() skips files modified < 120 s ago
cd $TS && HF_HUB_OFFLINE=1 systemd-run --user --scope -q --unit=st-impact-tsfm-lw-$$ -p MemoryMax=36G -p MemorySwapMax=0 \
  -p OOMPolicy=continue -p CPUWeight=20 taskset -c 40-79 bash -c '
  L=$1; TSD=$2; EM=$3
  for a in base cand; do
    if grep -q "REUSE_${a^^}=yes" $L/post_records.md; then END=2026-08-31; else END=2026-11-14; fi
    echo "$(date -u +%FT%TZ) overlay $a 2025-10-01..$END"
    $EM/venv-tsfm/bin/python $TSD/run_tsfm.py --mode postsim --start 2025-10-01 --end $END --phys-dir $L/phys-$a \
      --phys-start 2025-08-02 --phys-done $L/phys-$a.done --out $L/tsfm-$a --workers 10 --threads 4 \
      --extract $HOME/armada/em-data/euphemia-live-20261115.duckdb
    echo "$(date -u +%FT%TZ) overlay $a rc=$? days=$(ls $L/tsfm-$a/postsim 2>/dev/null | wc -l)"
  done' _ $L $TSD $EM
for a in base cand; do
  if grep -q "REUSE_${a^^}=yes" $L/post_records.md; then
    for f in ${SRC[$a]}/2026-09-*.csv ${SRC[$a]}/2026-1[01]-*.csv; do cp -n $f $L/tsfm-$a/postsim/; done
    echo "copied reused 09-01..11-14 overlay for $a from ${SRC[$a]}"
  fi
  echo "tsfm-$a: $(ls $L/tsfm-$a/postsim | wc -l) days $(ls $L/tsfm-$a/postsim | sed -n '1p;$p' | tr '\n' ' ')"
done
echo "OVERLAY-LW-END $(date -u +%FT%TZ)"
