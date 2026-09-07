#!/bin/bash
# Recreate the two-card fleets without ry-gpu-08.
#
# Its device plugin fails GetPreferredAllocation for a MULTI-GPU request: it
# queries the NVLink state between the two devices it would hand out and one is
# gone (the node advertises 7 now, not 8). The node stays Ready, so the
# scheduler keeps placing two-card pods there and the kubelet keeps rejecting
# them at admission -- 38 rejections in 20 minutes, each burning one of the
# Job's 20 retries. Same failure as 2026-09-05. A one-card request never takes
# that path, so the plain fleet keeps the node and is left alone here.
#
# Node affinity lives in the Job's pod template, which is immutable, so this
# deletes and recreates, one at a time, and only after admitprobe.py says the
# webhook will take it.
set -uo pipefail
SP="$(cd "$(dirname "$0")" && pwd)"
LIST=""
for i in $(seq 0 7);  do LIST="$LIST edit-w$(printf %02d $i)";   done
for i in $(seq 0 11); do LIST="$LIST simwam-w$(printf %02d $i)"; done
ok=0
for j in $LIST; do
  f="$SP/jobs/$j.yaml"
  [ -f "$f" ] || { echo "MISSING $f"; continue; }
  name="navsafe-${j%-w*}-${j##*-}"
  until python3 "$SP/admitprobe.py" "$f" /tmp/ap-$$.yaml 2>/dev/null \
        && kubectl apply --dry-run=server -f /tmp/ap-$$.yaml >/dev/null 2>&1; do
    echo "webhook refusing before $j ($ok done) — retry in 5 min ($(date -u +%H:%MZ))"
    sleep 300
  done
  kubectl delete job -n cogrob "$name" --wait=true >/dev/null 2>&1
  kubectl apply -f "$f" >/dev/null 2>&1 && ok=$((ok+1)) || echo "LOST $name"
  sleep 20
done
rm -f /tmp/ap-$$.yaml
echo "recreated $ok/20 two-card jobs without ry-gpu-08 ($(date -u +%H:%MZ))"
kubectl get pods -n cogrob --no-headers 2>/dev/null | grep -E '^navsafe-(perturb|edit|simwam)-w' | awk '{print $3}' | sort | uniq -c
