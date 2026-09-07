#!/bin/bash
# Bring up the three fleets, probing until every job is in.
#
#   plain  x8   1 GPU  46 scenarios that insert nothing   --cache-size 2 is safe
#   edit   x8   2 GPU   8 scenarios whose recipe inserts  --cache-size 4 required
#   simwam x12  2 GPU  all 54, SimWAM needs 12.6 GiB of its own
#   = 48 GPUs
#
# The split exists because --cache-size 2 evicts one of a scenario's four
# reconstructions during the insert pass and the eviction takes the injected
# asset with it, so rendering frame 0 (which needs the FIRST segment, the first
# one evicted) dies with "'navsafe_animal#ph0' is not in list". Only the eight
# scenarios that actually insert need the bigger cache, so only they pay for a
# second card.
#
# Interleaved so no fleet waits for another to finish starting, and each batch
# probes admission first: nothing is deleted here, so a refusal costs only time.
set -uo pipefail
SP="$(cd "$(dirname "$0")" && pwd)"
ORDER=""; p=0; e=0; s=0
while [ $p -lt 8 ] || [ $e -lt 8 ] || [ $s -lt 12 ]; do
  [ $p -lt 8 ]  && { ORDER="$ORDER plain-w$(printf %02d $p)";  p=$((p+1)); }
  [ $e -lt 8 ]  && { ORDER="$ORDER edit-w$(printf %02d $e)";   e=$((e+1)); }
  for k in 1 2; do [ $s -lt 12 ] && { ORDER="$ORDER simwam-w$(printf %02d $s)"; s=$((s+1)); }; done
done
TOTAL=$(echo $ORDER | wc -w | tr -d ' ')
ok=0
set -- $ORDER
while [ $# -gt 0 ]; do
  grp=""
  for k in 1 2 3 4; do [ $# -gt 0 ] && { grp="$grp $1"; shift; }; done
  first=$(echo $grp | awk '{print $1}')
  if ! kubectl apply --dry-run=server -f "$SP/jobs/$first.yaml" >/dev/null 2>&1; then
    echo "refused ($ok/$TOTAL in) — probe again in 5 min ($(date -u +%H:%MZ))"
    set -- $grp "$@"; sleep 300; continue
  fi
  for j in $grp; do kubectl apply -f "$SP/jobs/$j.yaml" >/dev/null 2>&1 && ok=$((ok+1)); done
  echo "submitted$grp  ($ok/$TOTAL)"
  sleep 45
done
echo "ALL $TOTAL SUBMITTED"
kubectl get pods -n cogrob --no-headers 2>/dev/null | grep -E '^navsafe-(perturb|edit|simwam)-w' | awk '{print $3}' | sort | uniq -c
