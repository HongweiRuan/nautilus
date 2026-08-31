#!/usr/bin/env bash
# submit_parity.sh — render a handful of clips BOTH ways (offline vs gRPC with
# the harmonizer off) so the two paths can be compared pixel-wise.
#
# This is the gate on the whole ablation: +Harmonizer is only reachable from
# serve-grpc, so if the two paths do not agree, Base has to be re-rendered
# through gRPC too or the row difference is not the harmonizer.
#
#   ./submit_parity.sh              # default 6 clips, 1 job
#   CLIPS="a b c" ./submit_parity.sh
set -o pipefail
cd "$(dirname "$0")"
NS="${NS:-cogrob}"; POD="${POD:-horuan-nexussim}"

# Six clips from six DIFFERENT scenarios, so a path difference that only shows
# up on some reconstructions is not missed by sampling one scene four times.
CLIPS="${CLIPS:-00185dab0ba153b9s1 0057ce5b81c35a81s1 02b68b9cc51f506as1 054e4984e1b55ec9s1 20cc0fdb7e2d5c3fs1 2575048779565f0bs1}"
RUNID="${RUNID:-$(date +%m%d%H%M%S)}"
OUT="rendered/parity"; mkdir -p "$OUT"

MAN=""
for c in $CLIPS; do MAN="${MAN}${c}\n"; done
SHARD="sh-$RUNID"
Y="$OUT/$SHARD.yaml"
python3 - "$SHARD" "$Y" <<PY
import sys
shard, out = sys.argv[1], sys.argv[2]
tpl = open("templates/parity.yaml").read()
man = "\n".join("              " + c for c in """$CLIPS""".split())
open(out, "w").write(tpl.replace("__SHARD__", shard).replace("              __MANIFEST__", man))
PY

if kubectl apply -f "$Y" >/dev/null 2>&1; then
  echo "[parity] submitted $SHARD ($(echo $CLIPS | wc -w) clips)"
else
  echo "[parity] APPLY FAILED:"; kubectl apply -f "$Y" 2>&1 | tail -2; exit 1
fi
