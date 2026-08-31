#!/usr/bin/env bash
# submit_grpcrender.sh — render every manifest clip through the eval's own gRPC
# path, twice (harmonizer off / on), sharded over the GPU pool.
#
#   ./submit_grpcrender.sh            # 20 shards over all clips still missing
#   JOBS=8 ./submit_grpcrender.sh
set -o pipefail
cd "$(dirname "$0")"
NS="${NS:-cogrob}"; POD="${POD:-horuan-nexussim}"
JOBS="${JOBS:-20}"
RUNID="${RUNID:-$(date +%m%d%H%M%S)}"
OUT="rendered/grpcrender"; mkdir -p "$OUT"

# Clip list from the pinned manifest, not from a directory listing: the frame
# set the scorer uses is the manifest's, and a clip outside it would be
# rendered for nothing. The helper is copied up and run as a FILE -- inlining
# it through `bash -lc` mangled the json escaping and returned an empty list.
kubectl cp list_clips.py "$NS/$POD:/tmp/list_clips.py" >/dev/null 2>&1 \
  || { echo "could not copy list_clips.py to the pod"; exit 1; }
kubectl exec -n "$NS" "$POD" -- python3 /tmp/list_clips.py 2>/dev/null \
  | tr -d '\r' | grep -E '^[0-9a-f]{16}s[1-4]$' | sort -u > /tmp/fid_clips.txt
TOTAL=$(wc -l < /tmp/fid_clips.txt)
[ "$TOTAL" -gt 0 ] || { echo "could not read the manifest clip list"; exit 1; }

kubectl exec -n "$NS" "$POD" -- python3 /tmp/list_clips.py --todo 2>/dev/null \
  | tr -d '\r' | grep -E '^[0-9a-f]{16}s[1-4]$' | sort -u > /tmp/fid_todo.txt
TODO=$(wc -l < /tmp/fid_todo.txt)
echo "[grpcrender] $TOTAL clip(s) in manifest, $TODO still to render"
[ "$TODO" -gt 0 ] || { echo "[grpcrender] nothing to do."; exit 0; }

PER=$(( (TODO + JOBS - 1) / JOBS ))
n=0; ok=0
split -l "$PER" -d -a 2 /tmp/fid_todo.txt /tmp/fid_shard_
for f in /tmp/fid_shard_*; do
  SHARD="sh$(printf '%02d' $n)-$RUNID"; Y="$OUT/$SHARD.yaml"
  python3 - "$SHARD" "$f" "$Y" <<'PY'
import sys
shard, clips, out = sys.argv[1], sys.argv[2], sys.argv[3]
man = "\n".join("              " + c.strip() for c in open(clips) if c.strip())
tpl = open("templates/grpcrender.yaml").read()
open(out, "w").write(tpl.replace("__SHARD__", shard).replace("              __MANIFEST__", man))
PY
  if kubectl apply -f "$Y" >/dev/null 2>&1; then ok=$((ok+1))
  else echo "  APPLY FAILED $SHARD:"; kubectl apply -f "$Y" 2>&1|tail -1; fi
  n=$((n+1))
done
rm -f /tmp/fid_shard_*
echo "[grpcrender] submitted $ok of $n shard(s), ~$PER clip(s) each"
