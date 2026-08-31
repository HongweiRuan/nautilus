#!/usr/bin/env bash
# submit_posesrc.sh — one job per clip: render it under all four offline pose
# sources plus gRPC (rolling shutter on/off), so the cross-comparison can say
# WHICH pose source the gRPC path behaves like.
set -o pipefail
cd "$(dirname "$0")"
CLIPS="${CLIPS:-00185dab0ba153b9s1 2575048779565f0bs1}"
RUNID="${RUNID:-$(date +%m%d%H%M%S)}"
OUT="rendered/posesrc"; mkdir -p "$OUT"
n=0
for C in $CLIPS; do
  # Full clip id, lowercased: the first 8 chars are the SCENARIO token and are
  # identical across that scenario's s1..s4, so a truncated slug made two jobs
  # collide on one name and the second died on "field is immutable".
  SHARD="$(echo "$C" | tr "[:upper:]" "[:lower:]")-$RUNID"; Y="$OUT/$SHARD.yaml"
  sed -e "s/__SHARD__/$SHARD/g" -e "s/__CLIP__/$C/g" templates/posesrc.yaml > "$Y"
  if kubectl apply -f "$Y" >/dev/null 2>&1; then n=$((n+1)); echo "  submitted $SHARD ($C)"
  else echo "  APPLY FAILED $C:"; kubectl apply -f "$Y" 2>&1|tail -2; fi
done
echo "[posesrc] $n job(s)"
