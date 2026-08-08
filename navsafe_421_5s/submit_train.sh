#!/usr/bin/env bash
# submit_train.sh — ONE foreground pass. Submits the navhard train scenes that still
# need it (no last.usdz / not Succeeded / not Running), printing each kubectl result
# so you SEE the util-policy denial directly. Stops on the first util-policy denial.
# Idempotent — re-run to submit more. TARGET caps in-flight so Pending doesn't pile
# up (which is what trips the util-policy). Override: TARGET=60 ./submit_train.sh
cd "$(dirname "$0")"
NS=cogrob; L="app=navhard421-5s,stage=train"; BATCH=${BATCH:-100}   # submit up to this many per pass

# done = last.usdz on CephFS (queried via a running train pod) OR a Succeeded job
pod=$(kubectl get pods -n $NS -l "$L" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
done_l=$([ -n "$pod" ] && kubectl exec -n $NS "$pod" -- bash -c \
  'for f in /avl-west/navhard421-website-5s/*/output_5cam/*/artifacts/last.usdz; do [ -f "$f" ] && echo "$f"; done' 2>/dev/null \
  | sed -E 's#.*/navhard421/([^/]+)/output_5cam.*#\1#')
succ_l=$(kubectl get jobs -n $NS -l "$L" -o jsonpath='{range .items[?(@.status.succeeded==1)]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sed 's/nav5s-train-//')
# in-flight = scenes with a Running OR Pending (OR ContainerCreating) pod — skip so a
# re-run never re-submits/churns a job that's already going
inflight_l=$(kubectl get pods -n $NS -l "$L" -o jsonpath='{range .items[*]}{.status.phase}{"|"}{.metadata.labels.job-name}{"\n"}{end}' 2>/dev/null \
  | awk -F'|' '$1=="Running"||$1=="Pending"||$1=="ContainerCreating"{print $2}' | sed 's/nav5s-train-//')
comm -23 <(sort -u train_list.txt) <(printf '%s\n%s\n%s\n' "$done_l" "$succ_l" "$inflight_l" | sort -u) | grep . > remaining_train.txt
rc=$(grep -c . remaining_train.txt)

run=$(kubectl get pods -n $NS -l "$L" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
pend=$(kubectl get pods -n $NS -l "$L" --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')
slots=$BATCH; [ "$rc" -lt "$slots" ] && slots=$rc
echo "remaining=$rc  running=$run  pending=$pend  -> submitting up to $slots this pass (BATCH=$BATCH)"
[ "$slots" -le 0 ] && { echo "nothing remaining to submit"; exit 0; }

n=0
while IFS= read -r C; do
  [ "$n" -ge "$slots" ] && { echo "--- submitted $n this pass (BATCH cap) ---"; break; }
  kubectl delete job -n $NS "nav5s-train-$C" --ignore-not-found --wait=false >/dev/null 2>&1
  out=$(kubectl apply -f "rendered/train/$C.yaml" 2>&1)
  echo "$out"
  case "$out" in
    *created*) n=$((n+1));;
    *"utilization is too low"*) echo; echo "=== UTIL-POLICY DENIED after $n submitted — stopping. Re-run later. ==="; exit 2;;
  esac
done < remaining_train.txt
echo "done: submitted $n this pass; $((rc-n)) still need a job"
