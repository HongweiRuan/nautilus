#!/usr/bin/env bash
# run_all.sh — drive the 5s pipeline ncore -> aux -> train to completion.
# Per stage: render the 112 job yamls, then throttled-submit (respecting the
# Nautilus util-policy) + auto-resubmit failures until every clip has a Succeeded
# job, then advance to the next stage. A clip that fails MAXTRY times is "given up"
# (reported, not blocking). Emits per-stage progress + ALL_TRAIN_DONE at the end.
# Idempotent: re-run any time; finished clips are skipped. kubectl-only (no CephFS).
set -uo pipefail
cd "$(dirname "$0")"
NS=cogrob
LIST=train_list.txt
N=$(grep -c . "$LIST")
TARGET_CPU=${TARGET_CPU:-112}     # ncore (CPU): fire all
TARGET_GPU=${TARGET_GPU:-80}      # aux/train (GPU): keep ~80 in flight (util-policy)
MAXTRY=${MAXTRY:-3}               # give up on a clip after this many submits
POLL=${POLL:-120}

render()  { DRYRUN=1 ./run_stage.sh "$1" >/dev/null 2>&1; }
scenes_succ() { kubectl get jobs -n $NS -l "app=navhard421-5s,stage=$1" \
  -o jsonpath='{range .items[?(@.status.succeeded==1)]}{.metadata.labels.scene}{"\n"}{end}' 2>/dev/null | sort -u | grep . || true; }
scenes_inflight() { kubectl get pods -n $NS -l "app=navhard421-5s,stage=$1" \
  -o jsonpath='{range .items[*]}{.status.phase}{"|"}{.metadata.labels.scene}{"\n"}{end}' 2>/dev/null \
  | awk -F'|' '$1=="Running"||$1=="Pending"||$1=="ContainerCreating"{print $2}' | sort -u | grep . || true; }
count_phase() { kubectl get pods -n $NS -l "app=navhard421-5s,stage=$1" --field-selector=status.phase=$2 --no-headers 2>/dev/null | wc -l | tr -d ' '; }

drive() {  # <stage> <target_inflight>
  local st=$1 target=$2 dn rem run pend slots C out n gave
  local SUB=/tmp/nav5s_submits_$st.log; : > "$SUB"
  render "$st"
  echo "$(date -u +%H:%M) [$st] rendered $(ls rendered/$st/*.yaml 2>/dev/null | wc -l | tr -d ' ') yamls; driving to $N"
  while :; do
    scenes_succ "$st" | sort -u > /tmp/nav5s_done_$st.txt
    dn=$(grep -c . /tmp/nav5s_done_$st.txt)
    # gave-up = submitted >= MAXTRY and still not succeeded
    : > /tmp/nav5s_gave_$st.txt
    [ -s "$SUB" ] && sort "$SUB" | uniq -c | awk -v m=$MAXTRY '$1>=m{print $2}' \
      | sort -u | comm -23 - /tmp/nav5s_done_$st.txt > /tmp/nav5s_gave_$st.txt
    gave=$(grep -c . /tmp/nav5s_gave_$st.txt)
    if [ $(( dn + gave )) -ge "$N" ]; then
      echo "$(date -u +%H:%M) [$st] STAGE_COMPLETE  ok=$dn  gave_up=$gave/$N"
      [ "$gave" -gt 0 ] && echo "[$st] gave-up clips: $(tr '\n' ' ' < /tmp/nav5s_gave_$st.txt)"
      return 0
    fi
    scenes_inflight "$st" | sort -u > /tmp/nav5s_infl_$st.txt
    # remaining = list - done - inflight - gaveup
    comm -23 <(sort -u "$LIST") <(cat /tmp/nav5s_done_$st.txt /tmp/nav5s_infl_$st.txt /tmp/nav5s_gave_$st.txt | sort -u) \
      | grep . > /tmp/nav5s_rem_$st.txt || true
    rem=$(grep -c . /tmp/nav5s_rem_$st.txt)
    run=$(count_phase "$st" Running); pend=$(count_phase "$st" Pending)
    slots=$(( target - run - pend )); [ "$slots" -lt 0 ] && slots=0
    n=0
    if [ "$rem" -gt 0 ] && [ "$slots" -gt 0 ]; then
      C=$(head -1 /tmp/nav5s_rem_$st.txt)
      # cooling ONLY on an explicit util-policy denial; an "immutable"/other error
      # from the probe (a stale failed job of the same name) is NOT cooling — the
      # submit loop deletes-then-applies, so proceed.
      if kubectl apply --dry-run=server -f "rendered/$st/$C.yaml" 2>&1 | grep -qi 'utilization is too low'; then
        echo "$(date -u +%H:%M) [$st] util-policy cooling"
      else
        while IFS= read -r C; do
          [ "$n" -ge "$slots" ] && break
          kubectl delete job -n $NS "nav5s-$st-$C" --ignore-not-found --wait=false >/dev/null 2>&1
          out=$(kubectl apply -f "rendered/$st/$C.yaml" 2>&1)
          case "$out" in
            *created*|*configured*) n=$((n+1)); echo "$C" >> "$SUB";;
            *"utilization is too low"*) echo "$(date -u +%H:%M) [$st] util-policy denied after +$n; backing off"; break;;
          esac
        done < /tmp/nav5s_rem_$st.txt
      fi
    fi
    echo "$(date -u +%H:%M) [$st] ok=$dn/$N rem=$rem run=$run pend=$pend +$n gave=$gave"
    sleep "$POLL"
  done
}

echo "=== $(date -u +%H:%M) 5s pipeline START: $N clips (ncore -> aux -> train) ==="
drive ncore "$TARGET_CPU"
drive aux    "$TARGET_GPU"
drive train  "$TARGET_GPU"
echo "=== $(date -u +%H:%M) ALL_TRAIN_DONE ok=$(scenes_succ train | wc -l | tr -d ' ')/$N ==="
