#!/bin/bash
# FDpi^k for a NavSafe VLA / world-model row, one side per job.
#
# Three stages, and only the middle one needs the model:
#   A  token table  — what each anchor needs besides its picture (ego status,
#      and the earlier frames the model conditions on). Cached once on the PVC.
#   B  feature dump — the model's own scene representation per anchor, hooked
#      in ITS venv because that is the only process the model exists in.
#   C  compute_fd   — the evaluator's own script, unchanged: stage B writes the
#      npz contract it already reads.
#
# `set -uo pipefail`, never -e: under -e any unguarded failure kills the shell
# with no message, which is how three separate silent deaths were chased through
# the sibling render worker.
set -uo pipefail
set -E
say() { echo "[vlafd $(date +%H:%M:%S)] $*"; }
trap 'rc=$?; say "FAILED rc=$rc at line $LINENO: $BASH_COMMAND"' ERR

MODEL=${MODEL:?set MODEL, e.g. simwam}
SIDE=${SIDE:?set SIDE: original | <variation>}
LIMIT=${LIMIT:-0}                      # >0 = probe mode, first N anchors only
OUT=${OUT:-/avl-west/fidelity_eval/fdpik_vla}
SRC=${SRC:-/hugsim-storage/NexusSim}
NEXUSSIM_SHA=${NEXUSSIM_SHA:-}
UE=/avl-west/drivearena_bench/unified_evaluator
UEPY=$UE/../envs/ue/bin/python          # the evaluator's interpreter, on the PVC
SDIR=$(cd "$(dirname "$0")" && pwd)     # /cfg, resolved once
mkdir -p "$OUT"

# STAGE A FIRST, before apt/uv/clone. It needs nothing but the evaluator's
# interpreter, which is already on the PVC, so running it here turns a bad
# argument or a missing path into a failure in under a minute. Ordered after
# the environment build it cost eleven minutes of container setup to discover
# that SceneLoader takes `sensor_blobs_path`, not `original_sensor_path`.
# ---- stage A: the token table, once for every model and every side ----------
TABLE=$OUT/token_table.json
if [ ! -s "$TABLE" ]; then
  say "stage A: building the token table with the evaluator's interpreter"
  # No `conda activate`. The env lives on the PVC, so its interpreter is
  # enough with env.sh's exports set by hand -- and that keeps stage A working
  # whichever base image the job runs on, which the nre-ga round proved is not
  # a given: that image has no conda at all and the activate line killed it.
  ( cd "$UE" && unset PYTHONPATH && set -a && . ./env.sh && set +a
    "$UEPY" "$SDIR/token_table.py" --out "$TABLE" ) \
    || { say "stage A FAILED"; exit 1; }
fi
# $UEPY, not python3: this runs before apt, so the base image's own
# interpreter is not something to count on.
say "token table: $("$UEPY" -c "import json;print(len(json.load(open('$TABLE'))))" 2>/dev/null) anchors"


export DEBIAN_FRONTEND=noninteractive
# The GL/X libs are not decoration: opencv and parts of the SimWAM stack link
# them, and the base image no longer carries what nre-ga did. `|| true` on the
# libs alone -- a missing optional lib should not stop the run before it has
# had a chance to say what it actually needs.
apt-get update -qq && apt-get install -y -qq git curl python3-venv \
  || { say "apt FAILED"; exit 1; }
apt-get install -y -qq libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 >/dev/null || true
export PATH=$HOME/.local/bin:$HOME/.cargo/bin:$PATH
export UV_CACHE_DIR=/root/.cache/uv
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh
hash -r
command -v uv >/dev/null || { say "uv unavailable"; exit 1; }

# The adapters import their model through NexusSim's own vla_server modules, so
# the tree has to be here. A clone, not a copy: only tracked files, and the
# run can name the commit its features came from.
REPO=/root/ns
[ -d "$REPO/.git" ] || {
  git clone --quiet --no-hardlinks "$SRC" "$REPO" || { say "clone FAILED"; exit 1; }
  [ -n "$NEXUSSIM_SHA" ] && { git -C "$REPO" checkout --quiet "$NEXUSSIM_SHA" \
    || { say "checkout $NEXUSSIM_SHA FAILED"; exit 1; }; }
}
say "code at $(git -C "$REPO" log --oneline -1)"
export NAVSAFE_VLA_SERVER_DIR="$REPO/nexussim/modelzoo/navsim/vla_server"

# ---- the VLA venv, identical recipe to navsafe-rerun-cfg/run_worker.sh ------
LOCK=/avl-west/navsafe_eval/env_kit/vla_requirements.lock.txt
if [ ! -x /root/vla-venv/bin/python ]; then
  say "building vla-venv (~5 min)"
  uv venv --python 3.12 /root/vla-venv || { say "venv FAILED"; exit 1; }
  # hydra-core 1.3.2 declares omegaconf<2.4 and uv's resolver refuses the
  # 2.4.0.dev14 these configs were proven against; install it after, unpinned.
  grep -v '^omegaconf==' "$LOCK" > /tmp/r.txt
  uv pip install --python /root/vla-venv/bin/python \
    --extra-index-url https://download.pytorch.org/whl/cu128 \
    --index-strategy unsafe-best-match -r /tmp/r.txt \
    || { say "vla-venv install FAILED"; exit 1; }
  uv pip install --python /root/vla-venv/bin/python --no-deps omegaconf==2.4.0.dev14 \
    || { say "omegaconf FAILED"; exit 1; }
fi
PY=/root/vla-venv/bin/python

# ---- stage B: the hooked feature dump ---------------------------------------
NPZ=$OUT/$MODEL/${SIDE}.npz
mkdir -p "$(dirname "$NPZ")"
if [ -s "$NPZ" ] && [ "$LIMIT" = 0 ]; then
  say "stage B: $NPZ already exists — skipping"
else
  say "stage B: $MODEL on side '$SIDE'${LIMIT:+ (limit $LIMIT)}"
  "$PY" "$SDIR/feature_dump_vla.py" \
      --model "$MODEL" --variation "$SIDE" \
      --token-table "$TABLE" --out "$NPZ" --limit "$LIMIT" \
      || { say "stage B FAILED"; exit 1; }
fi
[ "$LIMIT" = 0 ] || { say "probe done — no FD computed in probe mode"; exit 0; }

# ---- stage C: FD against the real-frame side --------------------------------
ORIG=$OUT/$MODEL/original.npz
if [ "$SIDE" = original ]; then
  say "original side written; FD is computed by the rendered-side jobs"
  exit 0
fi
# All four sides are submitted together, so a rendered side can finish its own
# dump before the original side has written the reference it is compared
# against. Wait for it rather than exiting empty-handed and needing a second
# pass: the dump above is already on disk, so a wait costs only idle GPU, and
# the alternative is a job that reports success having computed no FD.
if [ ! -s "$ORIG" ]; then
  say "waiting for $ORIG (the original side is still running)"
  for _ in $(seq 1 360); do        # 3 h at 30 s
    [ -s "$ORIG" ] && break
    sleep 30
  done
fi
[ -s "$ORIG" ] || { say "original side never appeared; features are written, FD not computed"; exit 0; }
say "stage C: compute_fd"
( cd "$UE" && unset PYTHONPATH
  "$UEPY" scripts/compute_fd.py "$ORIG" "$NPZ" \
    --json "$OUT/$MODEL/fd_${MODEL}_${SIDE}_vs_original.json" ) \
  || { say "stage C FAILED"; exit 1; }
say "ALL DONE"
