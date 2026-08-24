#!/usr/bin/env bash
# migrate_artifacts.sh — move already-built stage artifacts for the scenarios that the
# 500 selection KEEPS, from the old trees into /avl-west/navsafe_5s_500, so nothing is
# reconstructed twice.
#
#   old trees:  /avl-west/navsafe-5s-720   (441-scenario navtest selection: ncore + aux)
#               /avl-west/navsafe-testsplit (test-split mining; may not exist yet)
#   new tree:   /avl-west/navsafe_5s_500
#
# A carried-over scenario keeps its exact token and t0, so its four clip ids
# (<token>s1..s4) and every artifact path under them are unchanged — migration is a
# plain per-clip directory move.
#
# Runs INSIDE a pod that mounts /avl-west (it moves files on CephFS):
#     kubectl cp migrate_artifacts.sh cogrob/horuan-nexussim:/tmp/
#     kubectl cp scenes_500.tsv       cogrob/horuan-nexussim:/tmp/
#     kubectl exec cogrob/horuan-nexussim -- bash /tmp/migrate_artifacts.sh          # dry run
#     kubectl exec cogrob/horuan-nexussim -- bash /tmp/migrate_artifacts.sh --apply  # really move
#
# Default is a DRY RUN that only reports. Pass --apply to move.
# COPY=1 copies instead of moving (keeps the old trees intact; needs 2x space).
set -uo pipefail

TSV="${TSV:-/tmp/scenes_500.tsv}"
NEW="${NEW:-/avl-west/navsafe_5s_500}"
OLD_DIRS=("${OLD1:-/avl-west/navsafe-5s-720}" "${OLD2:-/avl-west/navsafe-testsplit}")
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1
MV="mv"; [ -n "${COPY:-}" ] && MV="cp -a"

[ -f "$TSV" ] || { echo "!! $TSV not found (copy scenes_500.tsv into the pod first)"; exit 1; }

echo "=== migrate to $NEW  (apply=$APPLY, op=$MV) ==="
mkdir -p "$NEW"

moved=0; already=0; absent=0; clips=0
while IFS=$'\t' read -r TOK LOG T0 T1 TYPES LEAVES SRC; do
  [ -z "${TOK:-}" ] && continue
  case "$TOK" in \#*) continue;; esac
  for k in 1 2 3 4; do
    C="${TOK}s${k}"; clips=$((clips+1))
    if [ -d "$NEW/$C" ]; then already=$((already+1)); continue; fi
    found=""
    for O in "${OLD_DIRS[@]}"; do
      [ -d "$O/$C" ] && { found="$O/$C"; break; }
    done
    if [ -z "$found" ]; then absent=$((absent+1)); continue; fi
    if [ "$APPLY" = "1" ]; then
      $MV "$found" "$NEW/$C" && moved=$((moved+1))
    else
      moved=$((moved+1))
    fi
  done
done < "$TSV"

echo "clips in selection : $clips"
echo "already in new tree: $already"
echo "migrated           : $moved $([ "$APPLY" = 1 ] || echo '(dry run — nothing moved)')"
echo "not built yet      : $absent   <- these are what submit_stage.sh will build"

if [ "$APPLY" = "1" ]; then
  echo ""
  echo "=== new tree stage counts ==="
  echo "  ncore : $(ls $NEW/*/clips/*/pai_*.json 2>/dev/null | wc -l)"
  echo "  aux   : $(ls -d $NEW/*/clips/*/*.aux.*.zarr.itar 2>/dev/null | sed -E 's#.*/clips/([^/]+)/.*#\1#' | sort -u | wc -l)"
  echo "  arrow : $(ls -d $NEW/*/arrow/logs/nuplan_test/* 2>/dev/null | wc -l)"
  echo "  train : $(ls $NEW/*/output_5cam/*/artifacts/last.usdz 2>/dev/null | wc -l)"
  echo ""
  echo "Leftovers in the old trees are scenarios the 500 selection dropped."
  for O in "${OLD_DIRS[@]}"; do
    [ -d "$O" ] && echo "  $O: $(ls -d $O/*/ 2>/dev/null | wc -l) clip dirs left"
  done
  echo "Review, then delete them by hand when you are happy with the new tree."
fi
