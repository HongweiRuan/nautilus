#!/usr/bin/env bash
# submit_rigeval.sh — closed-loop eval of one scenario under a chosen camera
# rig / harmonizer combination, everything else identical to the NavSafe eval.
#
#   ./submit_rigeval.sh 05d0a1a763fc5334 recon off
#   ./submit_rigeval.sh 05d0a1a763fc5334 navsim on     # what NavSafe runs today
set -o pipefail
cd "$(dirname "$0")"
T="${1:?token}"; RIG="${2:-recon}"; HARM="${3:-off}"
case "$RIG" in recon|navsim) ;; *) echo "rig must be recon|navsim"; exit 1;; esac
case "$HARM" in on|off) ;; *) echo "harmonizer must be on|off"; exit 1;; esac
RUNID="${RUNID:-$(date +%m%d%H%M%S)}"
SLUG="${T:0:8}-${RIG}-h${HARM}"
OUT="rendered/rigeval"; mkdir -p "$OUT"
Y="$OUT/$SLUG-$RUNID.yaml"
sed -e "s/__TOKEN__/$T/g" -e "s/__SLUG__/$SLUG/g" -e "s/__RIG__/$RIG/g" \
    -e "s/__HARM__/$HARM/g" -e "s/__RUNID__/$RUNID/g" templates/rigeval.yaml > "$Y"
if kubectl apply -f "$Y" >/dev/null 2>&1; then
  echo "[rigeval] submitted $SLUG  (rig=$RIG harmonizer=$HARM)"
  echo "          out: /avl-west/fidelity_eval/rigeval/$SLUG"
else
  echo "[rigeval] APPLY FAILED:"; kubectl apply -f "$Y" 2>&1 | tail -2; exit 1
fi
