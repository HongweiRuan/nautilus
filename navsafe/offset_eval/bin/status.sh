#!/bin/bash
# Where the sweep is: jobs, pods, and scored cells per model.
#
# The cell counts come from a find inside a worker pod, because the run dir is
# on CephFS and only the cluster can walk it at any speed.
set -uo pipefail
echo "=== jobs ==="
kubectl get jobs -n cogrob --no-headers 2>/dev/null \
  | grep -E '^navsafe-(perturb|edit|simwam)-w' | awk '{print $2}' | sort | uniq -c
echo "=== pods ==="
kubectl get pods -n cogrob --no-headers 2>/dev/null \
  | grep -E '^navsafe-(perturb|edit|simwam)-w' \
  | awk '{split($1,a,"-"); print a[2], $3}' | sort | uniq -c
echo "=== GPUs held ==="
kubectl get pods -n cogrob -o json 2>/dev/null | python3 -c "
import json,sys
t=sum(sum(int(c.get('resources',{}).get('requests',{}).get('nvidia.com/gpu',0) or 0)
          for c in p['spec']['containers'])
      for p in json.load(sys.stdin)['items']
      if p['metadata']['name'].startswith(('navsafe-perturb-w','navsafe-edit-w','navsafe-simwam-w'))
      and p['status'].get('phase')=='Running')
print(f'  {t}')"
P=$(kubectl get pods -n cogrob --no-headers 2>/dev/null \
    | grep -m1 -E '^navsafe-(perturb|edit|simwam)-w.*Running' | awk '{print $1}')
[ -z "$P" ] && { echo "no running worker to count cells through"; exit 0; }
echo "=== scored cells ==="
kubectl exec -n cogrob "$P" -- bash -c '
R=/avl-west/runs/20260905-handoff-perturb-demo/eval/seed0
for m in pdm_closed diffusiondrive recogdrive_rl diffusiondrive_beyonddrive simwam; do
  printf "  %-28s %4s / 1021\n" "$m" \
    "$(find $R -mindepth 4 -maxdepth 4 -type d -name $m -exec test -f {}/navsafe_metrics.json \; -print 2>/dev/null | wc -l)"
done' 2>/dev/null
