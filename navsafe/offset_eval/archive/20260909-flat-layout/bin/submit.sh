#!/bin/bash
# Bring fleets up, probing the utilisation webhook until every job is in.
#
#   bin/submit.sh                     all four fleets
#   bin/submit.sh heavy               just one
#   bin/submit.sh plain edit          just those two
#
#   plain  x8   1 GPU  46 scenarios that insert nothing   models.tsv
#   edit   x8   2 GPU   8 scenarios whose recipe inserts  models.tsv
#   simwam x12  2 GPU  all 54                             models_simwam.tsv
#   heavy  x12  2 GPU  all 54                             models_heavy.tsv
#
# The plain/edit split exists because --cache-size 2 evicts one of a scenario's
# four reconstructions during the insert pass and the eviction takes the injected
# asset with it, so rendering frame 0 -- which needs the FIRST segment, the first
# one evicted -- dies with "'navsafe_animal#ph0' is not in list". Only the eight
# inserting scenarios pay for a second card. simwam and heavy are on two cards
# whatever the scenario, because their models need a card to themselves.
#
# A job that already exists is SKIPPED, not replaced: a Job spec is immutable.
# Delete it first if you mean to change it. Nothing is deleted here, so a
# refusal costs only time -- the batch goes back to the head of the queue.
set -uo pipefail
SP="$(cd "$(dirname "$0")/.." && pwd)"

fleet_size() {
  case "$1" in
    plain|edit)   echo 8  ;;
    simwam|heavy) echo 12 ;;
    *) echo "unknown fleet: $1" >&2; exit 2 ;;
  esac
}
# The plain fleet's jobs are named navsafe-perturb-* for historical reasons;
# every other fleet's name matches its manifest prefix.
job_name() {
  case "$1" in
    plain-*)  echo "navsafe-perturb-${1##*-}" ;;
    *)        echo "navsafe-${1%-w*}-${1##*-}" ;;
  esac
}

FLEETS=${*:-plain edit simwam heavy}
for f in $FLEETS; do fleet_size "$f" >/dev/null; done

# Interleave the fleets so none waits for another to finish starting.
ORDER=""; i=0; more=1
while [ "$more" = 1 ]; do
  more=0
  for f in $FLEETS; do
    if [ "$i" -lt "$(fleet_size "$f")" ]; then
      ORDER="$ORDER $f-w$(printf %02d $i)"; more=1
    fi
  done
  i=$((i + 1))
done

TOTAL=$(echo $ORDER | wc -w | tr -d ' ')
echo "submitting up to $TOTAL jobs:$(for f in $FLEETS; do printf ' %s(%s)' "$f" "$(fleet_size $f)"; done)"

ok=0; skipped=0
set -- $ORDER
while [ $# -gt 0 ]; do
  grp=""
  for k in 1 2 3 4; do [ $# -gt 0 ] && { grp="$grp $1"; shift; }; done
  first=$(echo $grp | awk '{print $1}')
  # Probe under a name that does not exist: a dry run against an EXISTING Job is
  # a patch, and a Job spec is immutable, so it fails on `field is immutable`
  # whatever the webhook thinks -- and a script reading that as "refused" waits
  # forever.
  if ! python3 "$SP/bin/admitprobe.py" "$SP/jobs/$first.yaml" /tmp/admitprobe-$$.yaml 2>/dev/null \
     || ! kubectl apply --dry-run=server -f /tmp/admitprobe-$$.yaml >/dev/null 2>&1; then
    echo "refused ($ok in, $skipped existed) — probe again in 5 min ($(date -u +%H:%MZ))"
    set -- $grp "$@"; sleep 300; continue
  fi
  for j in $grp; do
    name=$(job_name "$j")
    if kubectl get job -n cogrob "$name" >/dev/null 2>&1; then
      skipped=$((skipped + 1)); continue
    fi
    kubectl apply -f "$SP/jobs/$j.yaml" >/dev/null 2>&1 && ok=$((ok + 1)) || echo "FAILED $name"
  done
  echo "submitted$grp  ($ok in, $skipped existed)"
  sleep 45
done
rm -f /tmp/admitprobe-$$.yaml
echo "DONE: $ok created, $skipped already existed"
kubectl get pods -n cogrob --no-headers 2>/dev/null \
  | grep -E '^navsafe-(perturb|edit|simwam|heavy)-w' | awk '{print $3}' | sort | uniq -c
