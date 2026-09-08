#!/usr/bin/env bash
# Submit from an account the utilization webhook is not throttling.
#
#   ./submit.sh ready   4 cells: ddv2_sel, a 6th panel agent, no new code
#   ./submit.sh vla     SimWAM: original + the three rendered sides, all at once
#
# No probe job: the four go out together and the first to reach the model is
# the probe. Nothing is lost if the tap is wrong -- the dumper refuses loudly
# when the hook fires more than once per anchor -- and a rendered side that
# finishes before the original waits up to 3 h for the reference rather than
# exiting with no FD.
#
# These sit in the PUBLIC queue: no reservation, us-west + us-central, 3090 or
# A10, cpu 2.
#
# "AlreadyExists" is fine. "pods resources utilization is too low" means this
# account is throttled too; wait and re-run, do not loop.
set -uo pipefail
cd "$(dirname "$0")"
rc=0
apply() { for f in "$@"; do [ -e "$f" ] && { kubectl apply -f "$f" || rc=1; }; done; }
cfg() {
  kubectl create configmap navsafe-fdpik-vla-cfg -n cogrob \
    --from-file=vla/vla_fdpik_worker.sh \
    --from-file=vla/feature_dump_vla.py \
    --from-file=vla/token_table.py \
    --dry-run=client -o yaml | kubectl apply -f - || rc=1
}
case "${1:-ready}" in
  ready) apply jobs/*.yaml ;;
  vla)        cfg; kubectl apply -f jobs_vla/simwam/ || rc=1 ;;
  mtdrive)    cfg; kubectl apply -f jobs_vla/mtdrive/ || rc=1 ;;
  recogdrive) cfg; kubectl apply -f jobs_vla/recogdrive/ || rc=1 ;;
  # `kubectl apply -f` takes ONE path per flag, so a glob spanning several
  # files is silently truncated to the first. A directory per model is applied
  # whole, which is also what makes "just this model" a natural request.
  *) echo "usage: $0 <ready|vla|mtdrive|recogdrive>"; exit 2 ;;
esac
echo "--- submitted (${1:-ready}) ---"
kubectl get jobs -n cogrob 2>/dev/null | grep -E "fdpik|NAME"
exit $rc
