#!/usr/bin/env bash
# submit_webgifs.sh — render + submit a log-replay webgif eval for each (category,
# scene) in cat_assign.tsv. Skips scenes whose gif already exists or whose arrow
# isn't ready yet. Prints each kubectl result (util-policy denial visible) and stops
# on the first util-policy denial. Idempotent — re-run to continue. GPU jobs.
#   TARGET caps in-flight webgif jobs so Pending doesn't pile up. BATCH caps per pass.
cd "$(dirname "$0")"
NS=cogrob; L="app=webgif"; BATCH=${BATCH:-28}; TARGET=${TARGET:-20}
GIFDIR=/avl-west/navsafe-website-gifs
POD=horuan-nexussim   # mounts /avl-west, used only to read CephFS state

[ -f webgif_assign.tsv ] || { echo "!! webgif_assign.tsv (category<TAB>scene) missing"; exit 1; }
mkdir -p rendered/webgif

# CephFS state via the dev pod: which gifs exist, which arrows are ready
gifs_done=$(kubectl exec -n $NS $POD -- bash -c "ls $GIFDIR/*.gif 2>/dev/null | xargs -n1 basename 2>/dev/null" 2>/dev/null | sed 's/\.gif$//')
arrow_ready=$(kubectl exec -n $NS $POD -- bash -c 'for d in /avl-west/navhard421/*/arrow/logs/nuplan_test/*; do [ -d "$d" ] && basename "$d"; done' 2>/dev/null | sort -u)

run=$(kubectl get pods -n $NS -l "$L" -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -cE 'Running|Pending|ContainerCreating')
slots=$(( TARGET - run )); [ "$slots" -gt "$BATCH" ] && slots=$BATCH
echo "in-flight webgif jobs=$run  target=$TARGET  -> up to $slots this pass"

n=0
while IFS=$'\t' read -r CAT C; do
  [ -z "$C" ] && continue
  [ "$n" -ge "$slots" ] && { echo "--- submitted $n this pass (cap) ---"; break; }
  # skip: gif already made
  printf '%s\n' "$gifs_done" | grep -qxF "$CAT-$C" && continue
  # skip: this scene already has a webgif job in flight
  kubectl get job -n $NS "webgif-$C" >/dev/null 2>&1 && { st=$(kubectl get job -n $NS webgif-$C -o jsonpath='{.status.succeeded}/{.status.active}'); [ "${st%/*}" = "1" ] || [ "${st#*/}" = "1" ] && continue; }
  # require: arrow ready
  printf '%s\n' "$arrow_ready" | grep -qxF "$C" || { echo "waiting on arrow: $CAT ($C)"; continue; }
  sed -e "s|__CAT__|$CAT|g" -e "s|__SCENE__|$C|g" templates/webgif_eval.yaml > "rendered/webgif/$C.yaml"
  kubectl delete job -n $NS "webgif-$C" --ignore-not-found --wait=false >/dev/null 2>&1
  out=$(kubectl apply -f "rendered/webgif/$C.yaml" 2>&1)
  echo "[$CAT] $out"
  case "$out" in
    *created*) n=$((n+1));;
    *"utilization is too low"*) echo; echo "=== UTIL-POLICY DENIED after $n — stopping, re-run later ==="; exit 2;;
  esac
done < webgif_assign.tsv
echo "done: submitted $n this pass"
