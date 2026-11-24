#!/bin/bash
# st-impact long-window warm record runner (adapted copy of cv46-physics cp-runs/harness/warmarm.sh, 2026-11-24).
# lw-addlane.sh QUEUE_FILE CORES — one extra lane on a running lw.sh queue (same chunk code). Original header:
# lw.sh DAYS_FILE — builds BOTH arms (base = c490255 detached, cand = 63d0d11 local default-flip) for every day of
# DAYS_FILE, from ONE shared queue of "ATTEMPT ARM DAYS_CSV" chunks; lanes = LANESETS (space-separated core ranges).
# Per chunk: one scope MemoryMax=LANE_MEM, OOM watchdog, timeout 300 s x days + 900 s; results split per day into
# $RUNS/<arm>/db/<day>.duckdb (warmsplit.py), done flags $RUNS/<arm>/done/<day>; undone days re-queued once.
{
set -u
Q=$(readlink -f $1); ADDCORES=$2
EM=$HOME/armada/em-team; HS=$EM/strategy/st-impact/harness; RUNS=$EM/strategy/runs/st-impact/r2/long
PY=$EM/venv-ops431/bin/python; LANE_MEM=${LANE_MEM:-7}; CHUNK=${CHUNK:-30}; JT=${JT:-2}
MEMSPEC=$(awk -v g=$LANE_MEM 'BEGIN{printf "%dM", g*1024}')
declare -A WT=([base]=$EM/worktrees/st-impact-lw-base [cand]=$EM/worktrees/st-impact-lw-cand)
declare -A SHA=([base]=c490255 [cand]=63d0d11)
for a in base cand; do
  [ "$(git -C ${WT[$a]} rev-parse --short=7 HEAD)" = "${SHA[$a]}" ] || { echo "${WT[$a]} not at ${SHA[$a]}"; exit 2; }
  git -C ${WT[$a]} diff --quiet && git -C ${WT[$a]} diff --cached --quiet || { echo "${WT[$a]} dirty"; exit 2; }
  mkdir -p $RUNS/$a/done $RUNS/$a/db $RUNS/$a/logs
  echo "ADDLANE ARM=$a SHA=${SHA[$a]} QUEUE=$Q CORES=$ADDCORES LANE_MEM=${LANE_MEM}G JT=$JT start=$(date -u +%FT%TZ)" >> $RUNS/$a/RUN.txt
done
ST=$RUNS/staging; [ -e $Q ] && [ -e $Q.active ] || { echo "no queue $Q"; exit 2; }
pop() { ( flock 9; l=$(head -1 $Q); if [ -n "$l" ]; then sed -i 1d $Q; echo $(( $(cat $Q.active) + 1 )) > $Q.active; fi; echo "$l" ) 9>$Q.lock; }
release() { ( flock 9; echo $(( $(cat $Q.active) - 1 )) > $Q.active ) 9>$Q.lock; }
active() { ( flock 9; cat $Q.active ) 9>$Q.lock; }
push() { ( flock 9; echo "$1" >> $Q ) 9>$Q.lock; }

run_chunk() {   # run_chunk ATTEMPT ARM DAYS_CSV LANE_CORES
  local att=$1 arm=$2 days=$3 cs=$4; local first=${days%%,*} last=${days##*,}; local nd=$(echo ${days//,/ } | wc -w)
  local RD=$RUNS/$arm SD=$ST/$arm-$first-$last-a$att; mkdir -p $SD/tmp; local DB=$SD/chunk.duckdb LOG=$SD/chunk.log
  rm -f $DB $DB.wal $LOG; local TO=$(( 300 * nd + 900 )) U=st-impact-lw-$arm-$first-a$att-$$
  local START=$(date -u +%FT%TZ) T0=$(date +%s)
  systemctl --user reset-failed $U.scope 2>/dev/null
  systemd-run --user --scope -q --unit=$U -p MemoryMax=$MEMSPEC -p MemorySwapMax=0 -p OOMPolicy=continue -p CPUWeight=20 \
    taskset -c $cs bash -c '
      CG=/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup); SD=$1; TO=$2; shift 2
      ( while sleep 15; do o=$(awk "\$1==\"oom_kill\"{print \$2}" $CG/memory.events 2>/dev/null)
          if [ "${o:-0}" -gt 0 ]; then echo "WARM OOM-KILL oom_kill=$o peak=$(cat $CG/memory.peak)" >> $SD/events
            for p in $(cat $CG/cgroup.procs); do [ $p != $$ ] && [ $p != $BASHPID ] && kill -9 $p 2>/dev/null; done; break; fi; done ) &
      WD=$!; timeout -k 60 $TO "$@"; rc=$?; kill $WD 2>/dev/null
      echo "rc=$rc peak=$(cat $CG/memory.peak 2>/dev/null)" > $SD/scope.txt; exit $rc' _ $SD $TO \
    env -C ${WT[$arm]} -i HOME=$HOME PATH=/usr/local/bin:/usr/bin:/bin USER=$USER LANG=C.UTF-8 TMPDIR=$SD/tmp \
      JULIA_DEPOT_PATH=$EM/depot-strategy:$EM/depot-cv46p:$EM/depot-lead:$EM/depot-ops JULIA_MAX_NUM_PRECOMPILE_FILES=40 \
      JULIA_NUM_THREADS=$JT OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 \
      EUPHEMIA_DATA_STORE=duckdb EUPHEMIA_DUCKDB_READONLY=true EUPHEMIA_FLOW_ASOF_MODE=v2 \
      EUPHEMIA_DUCKDB_PATH=$HOME/armada/em-data/euphemia-live-20261115.duckdb \
      EUPHEMIA_DUCKDB_TEMP=$SD/tmp EUPHEMIA_DUCKDB_THREADS=2 EUPHEMIA_DUCKDB_MEMORY=1GB \
      EUPHEMIA_RESULTS_DB=$DB DAYS=$days SOLVERS=1 BOOKS=1 IN_FLIGHT=2 \
      $EM/runtimes/ops/julia-1.13.4/bin/julia --startup-file=no --heap-size-hint=3G --project=. $HS/record_day.jl > $LOG 2>&1
  local RC=$? WALL=$(( $(date +%s) - T0 )); local PEAK=$(sed -n 's/.*peak=\([0-9]*\).*/\1/p' $SD/scope.txt 2>/dev/null)
  local ok=() miss=() d
  for d in ${days//,/ }; do grep -q "^DAY $d DONE" $LOG && ok+=($d) || miss+=($d); done
  if [ ${#ok[@]} -gt 0 ] && [ -s $DB ]; then
    if $PY -I $HS/warmsplit.py $DB $RD/db "${ok[@]}" > $SD/split.txt 2>&1; then
      for d in "${ok[@]}"; do
        local tot=$(grep -m1 "^DAY $d DONE" $LOG | sed -n 's/.*total=\([0-9.]*\)s.*/\1/p')
        { flock 8; [ -s $RD/metrics.tsv ] || printf 'day\trc\twall_s\trss_peak_bytes\tunit\tstart_utc\n' > $RD/metrics.tsv
          printf '%s\t%s\t%s\t%s\t%s\t%s\n' $d $RC ${tot:-NA} ${PEAK:-NA} $U $START >> $RD/metrics.tsv; } 8>$RD/.metrics.lock
        touch $RD/done/$d
      done
      rm -f $DB $DB.wal
    else miss+=("${ok[@]}"); echo "$(date -u +%FT%TZ) split FAILED for $arm $first..$last (see $SD/split.txt)" >> $RUNS/lanes.log; fi
  fi
  gzip -c $LOG > $RD/logs/warm-$first-$last-a$att.log.gz; rm -rf $SD/tmp
  echo "$(date -u +%H:%M:%SZ) $arm $first..$last a$att cores=$cs rc=$RC wall=${WALL}s peak=$PEAK done=${#ok[@]}/$nd $( [ -s $SD/events ] && cat $SD/events )" >> $RUNS/lanes.log
  if [ ${#miss[@]} -gt 0 ]; then
    if [ $att -lt 2 ]; then push "$((att + 1)) $arm $(IFS=,; echo "${miss[*]}")"
    else echo "$(date -u +%H:%M:%SZ) NOT-done after 2 warm attempts: $arm ${miss[*]}" >> $RUNS/lanes.log; fi
  fi
}
lane() {
  local cs=$1 item
  while :; do
    item=$(pop)
    if [ -z "$item" ]; then [ "$(active)" -le 0 ] && break; sleep 20; continue; fi
    set -- $item; run_chunk $1 $2 $3 $cs
    release
  done
}
lane $ADDCORES
echo "$(date -u +%H:%M:%SZ) addlane $ADDCORES exits" >> $RUNS/lanes.log
exit 0
}
