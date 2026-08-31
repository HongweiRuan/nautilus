#!/usr/bin/env bash
# clean.sh [stage] — delete COMPLETED jobs so they stop holding namespace quota.
# Never touches active ones.
set -uo pipefail
NS="${NS:-cogrob}"
SEL="app=render_quality_eval"; [ -n "${1:-}" ] && SEL="$SEL,stage=$1"
kubectl get jobs -n "$NS" -l "$SEL" -o json 2>/dev/null | python3 -c '
import sys, json, subprocess
d = json.load(sys.stdin)
gone = 0
for j in d.get("items", []):
    st = j.get("status", {})
    if st.get("active"): continue
    if not (st.get("succeeded") or st.get("failed")): continue
    n = j["metadata"]["name"]
    subprocess.run(["kubectl","delete","job","-n","'"$NS"'",n,"--wait=false"],
                   stdout=subprocess.DEVNULL)
    gone += 1
print(f"deleted {gone} finished job(s)")
'
