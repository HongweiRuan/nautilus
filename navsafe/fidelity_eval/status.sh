#!/usr/bin/env bash
# status.sh — one screen of truth: jobs, pods, and what is actually on CephFS.
set -uo pipefail
cd "$(dirname "$0")"
NS="${NS:-cogrob}"; POD="${POD:-horuan-nexussim}"
echo "=== jobs ==="
kubectl get jobs -n "$NS" -l app=render_quality_eval \
  -o custom-columns=NAME:.metadata.name,STAGE:.metadata.labels.stage,OK:.status.succeeded,ACTIVE:.status.active,FAIL:.status.failed \
  2>/dev/null | head -60
echo
echo "=== pods by phase ==="
kubectl get pods -n "$NS" -l app=render_quality_eval --no-headers 2>/dev/null \
  | awk '{c[$3]++} END {for (p in c) printf "  %-16s %d\n", p, c[p]}'
echo
echo "=== progress against the pinned manifest ==="
kubectl exec -n "$NS" "$POD" -- bash -lc 'python3 -c "
import json, os
R=\"/avl-west/render_quality_eval\"
m=json.load(open(f\"{R}/manifest.json\"))[\"scenarios\"]
nf=sum(len(s[\"frames\"]) for s in m)
print(f\"  manifest        {len(m):>4} scenarios  {nf:>6} frames\")
for k,sub in ((\"nurec_native\",\"render_raw/nurec_native\"),(\"nurec_400\",\"render_raw/nurec_400\")):
    c=len([d for d in os.listdir(f\"{R}/{sub}\") if os.path.isdir(f\"{R}/{sub}/{d}\")]) if os.path.isdir(f\"{R}/{sub}\") else 0
    print(f\"  {k:<15} {c:>4}/1568 clips\")
d=f\"{R}/render_raw/drivearena\"
n=sum(os.path.exists(os.path.join(d,f[\"data_path\"])) for s in m for f in s[\"frames\"]) if os.path.isdir(d) else 0
print(f\"  drivearena      {n:>6}/{nf} frames\")
" 2>/dev/null' 2>/dev/null
