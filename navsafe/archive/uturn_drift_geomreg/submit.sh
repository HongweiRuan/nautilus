#!/usr/bin/env bash
# submit.sh [arm ...]      — default: flatten flatten-calib
#
# One job per (arm, clip).  DRYRUN=1 renders into rendered/ without applying.
#
#   DRYRUN=1 ./submit.sh              # render the default arms, apply nothing
#   ./submit.sh difix-probe           # ~15 min canary: does difix compose, what VRAM
#   ./submit.sh difix-2m base-2m      # the difix question, ~4.5 h x 8 jobs
#   ./submit.sh flatten flatten-calib
#
# CLIPS=<one clip> restricts an arm to a single clip (difix-probe does this itself).
#
# (No associative arrays: macOS ships bash 3.2 and this runs from the Mac, because
# `kubectl apply` must come from the account whose Nautilus utilization is scored.)
set -uo pipefail
cd "$(dirname "$0")"

NS=cogrob
POD="${POD:-horuan-nexussim}"
RUNDIR="${RUNDIR:-20260819-uturn-drift-geomreg}"
# One scene per invocation. SCENE/RUNDIR/LIDARNCORE are overridable so a second
# scenario reuses the whole harness:
#   SCENE=3efebf87894a552e RUNDIR=20260820-stopline-drift-geomreg \
#   LIDARNCORE=/avl-west/runs/20260820-stopline-lidardepth/ncore ./submit.sh ...
SCENE="${SCENE:-891953217984568c}"           # default: V-8 Illegal U-Turn (20 s host)
LIDARNCORE="${LIDARNCORE:-/avl-west/runs/20260820-uturn-lidardepth/ncore}"
PREFIX="${PREFIX:-uturn}"                     # job-name prefix; say which scene
ALLCLIPS="${SCENE}s1 ${SCENE}s2 ${SCENE}s3 ${SCENE}s4"
TPL=templates/train_arm.yaml

# The baseline recon budget, verbatim from ../navsafe_5s_500/templates/train.yaml.
B5M='dataset.n_samples_per_epoch=160000 model.strategy.add.max_n_gaussians=5000000 model.strategy.add.end_iteration=140000 model.strategy.relocate.end_iteration=140000 model.strategy.perturb.end_iteration=160000 system.optimizers.0.scheduler.args.T_max=160000'
# Same schedule, 2M gaussians. 5M measured ~18 GB, so 2M is ~7 GB and leaves ~17 GB
# of a 3090 for the difix model plus its two extra novel-view renders per difix step.
B2M='dataset.n_samples_per_epoch=160000 model.strategy.add.max_n_gaussians=2000000 model.strategy.add.end_iteration=140000 model.strategy.relocate.end_iteration=140000 model.strategy.perturb.end_iteration=160000 system.optimizers.0.scheduler.args.T_max=160000'
# 6k-step canary: densification pulled forward so gaussians actually grow, difix on at
# step 3000 so we learn within ~15 min instead of 3 h whether it composes and fits.
BPROBE='dataset.n_samples_per_epoch=6000 model.strategy.add.max_n_gaussians=2000000 model.strategy.add.start_iteration=500 model.strategy.add.end_iteration=5000 model.strategy.relocate.end_iteration=5000 model.strategy.perturb.end_iteration=6000 system.optimizers.0.scheduler.args.T_max=6000'

# difix.training's schedule ships tuned for a 30k-step run (start 20000, milestones
# 25000/28000). Ours is 160k, so hold the ratios: 0.667 / 0.833 / 0.933.
DFX='difix.training.enabled=true difix.training.start_step=106000 difix.training.p_scheduler.milestones=[133000,149000] difix.cache_dir=/avl-west/nre_cache/difix'
DFXPROBE='difix.training.enabled=true difix.training.start_step=3000 difix.training.p_scheduler.milestones=[4500,5500] difix.cache_dir=/avl-west/nre_cache/difix'

# ---- the arms -------------------------------------------------------------
# "base" is deliberately absent: the 5M / no-difix recon already exists in the corpus.
arm_overrides() {
  case "$1" in
    # -- geometry regularization (MTGS's single-traversal half) --------------
    # The anti-needle regularizer: penalize gaussians whose longest axis exceeds
    # max_to_median_ratio_threshold (default 1.0) times the median one. Needles are
    # invisible edge-on from the training ray and flare into blobs once the camera
    # moves sideways, which is exactly the drift failure. 0.005 is NRE's suggested
    # weight; MTGS's 1.0 is not comparable because their threshold is r=10.
    #
    # MTGS's OTHER geometric term, the surface-normal loss, is NOT here: NRE's
    # loss.normal is SUPERVISED ("[NormalLoss] target labels should contain normal
    # labels, but got None") and the aux pipeline does not produce them — `nrml` is a
    # reserved signal slot, "not produced by the default pipeline today". Using it
    # needs an external normal estimator written back as an aux zarr signal.
    flatten)       echo 'loss.gaussian_flatten.lambda_=0.005' ;;
    # ... plus the camera-pose optimizer. MTGS states nuPlan localization is imprecise
    # and optimizes poses (lr 1e-4); NRE's free-pose-calib defaults match (lr 1e-4,
    # start_global_step 250, T_max auto-derived to 159750).
    # It must be forced with ++: a plain override is rejected at composition time
    # ("Could not override 'model.calib.enabled'. To append ... use +model.calib.enabled")
    # even though the key IS present in the final parsed config. arm_check reads the
    # value back out of parsed.yaml, so a ++ that silently does nothing still fails.
    flatten-calib) echo 'loss.gaussian_flatten.lambda_=0.005 ++model.calib.enabled=true' ;;
    # Pose optimizer alone, to separate the two effects if flatten-calib wins.
    calib)         echo '++model.calib.enabled=true' ;;


    # -- difix: can training-time novel-view supervision buy back gaussians? --
    # difix.training renders the scene at +/-3 m lateral each difix step and supervises
    # it against the Difix generative prior. That is the closest single-traversal stand-in
    # for MTGS's multi-traversal supervision, and it is the one lever that acts directly
    # on the views we cannot otherwise constrain.
    difix-probe)   echo "$DFXPROBE" ;;
    difix-2m)      echo "$DFX" ;;
    # 2M without difix. Not a control in the strict sense (the target is the 5M corpus
    # recon), but it is 4 cheap jobs and it is the difference between "difix bought us
    # 3M gaussians" and "2M was always enough for this scene".
    base-2m)       echo '' ;;

    # -- lidar depth supervision, finally possible on nuPlan ------------------
    # Reads the RE-CONVERTED store (arm_src) which carries a second component,
    # lidar_top_structured: nuPlan's TOP sensor with a beam model recovered by
    # fitting the six-DoF extrinsic that makes each `ring` a constant-elevation
    # cone (residual 0.010-0.022 deg). The merged cloud is unchanged, so
    # initialisation must stay pinned to it (arm_road_lidar) or the comparison
    # measures a bigger init point set rather than the supervision.
    lidardepth)    echo 'loss.lidar.lambda_=0.005' ;;
    *) return 1 ;;
  esac
}

# Where the clip's NCore store lives. Everything but lidardepth reads the corpus.
arm_src() {
  case "$1" in
    lidardepth) echo "$LIDARNCORE/clips/\$C" ;;
    *)          echo '/avl-west/navsafe_5s_500/$C/clips/$C' ;;
  esac
}

# Lidar ids + how many rays per training sample. ZERO rays is the long-standing
# default: the merged nuPlan cloud has no spinning model, so it can only seed
# Gaussians, never supervise them. lidardepth is the first arm able to set it.
arm_lidar() {
  case "$1" in
    # ONLY the structured component may be listed. NRE demands model parameters
    # for EVERY id in dataset.lidar_ids once rays are sampled --
    #   ValueError: lidar model parameters are mandatory ... not available for 'lidar_top_360fov'
    # -- and listing the merged cloud alongside makes its views produce a null
    # sensor-to-world pair, which surfaces later and far less legibly as
    #   RuntimeError: T_sensor_world_startend_allviews: data pointer is invalid
    lidardepth) echo 'dataset.lidar_ids=[lidar_top_structured] dataset.train_lidar_ids=[lidar_top_structured] dataset.val_lidar_ids=[lidar_top_structured] dataset.n_train_sample_lidar_rays=1024' ;;
    *)          echo 'dataset.lidar_ids=[lidar_top_360fov] dataset.train_lidar_ids=[lidar_top_360fov] dataset.val_lidar_ids=[lidar_top_360fov] dataset.n_train_sample_lidar_rays=0' ;;
  esac
}

# Which lidar seeds road/background Gaussians. It has to be one the dataset
# actually loads, so lidardepth seeds from the structured cloud too. That is the
# arm's one uncontrolled difference and it is NOT negligible: TOP-only supplies
# 778 671 background points against the other arms' 800 000 cap (-2.7 %) but only
# 326 352 road points against their 400 000 cap (-18 %). Read the road-surface
# result with that in mind.
arm_road_lidar() {
  case "$1" in
    lidardepth) echo '[lidar_top_structured]' ;;
    *)          echo 'null' ;;
  esac
}

arm_budget() {
  case "$1" in
    flatten|flatten-calib|calib)         echo "$B5M" ;;
    lidardepth)                          echo "$B5M" ;;
    difix-2m|base-2m)            echo "$B2M" ;;
    difix-probe)                 echo "$BPROBE" ;;
    *) return 1 ;;
  esac
}

# difix.training spins up its own novel-view dataloader (num_workers 4) on top of the
# training loader, so the difix arms need more CPU/RAM than the baseline shape.
# 32Gi because that is the only value with evidence behind it: every U-turn arm
# completed at 32Gi, and 14400Mi (45 %) OOMKilled 24 pods. Do NOT trust an early
# training sample when sizing this -- memory climbs the whole run as MCMC
# densifies. Measured on the way up: 5.1 GiB early, 7.4 GiB at 4 h and still
# rising, dead somewhere past 14.4 GiB. The true peak is still unmeasured; if the
# utilization metric needs the request cut, measure a FINISHED run first.
arm_cpu() { case "$1" in difix-*) echo 4 ;; *) echo 2 ;; esac; }
arm_mem() { case "$1" in difix-*) echo 48Gi ;; *) echo 32Gi ;; esac; }

arm_clips() { case "$1" in difix-probe) echo "${SCENE}s1" ;; *) echo "$ALLCLIPS" ;; esac; }

arm_check() {
  case "$1" in
    flatten)       echo '{"loss.gaussian_flatten.lambda_": 0.005, "loss.normal.lambda_": 0.0, "model.calib.enabled": false, "model.strategy.add.max_n_gaussians": 5000000, "difix.training.enabled": false}' ;;
    flatten-calib) echo '{"loss.gaussian_flatten.lambda_": 0.005, "loss.normal.lambda_": 0.0, "model.calib.enabled": true,  "model.strategy.add.max_n_gaussians": 5000000, "difix.training.enabled": false}' ;;
    calib)         echo '{"loss.normal.lambda_": 0.0, "loss.gaussian_flatten.lambda_": 0.0,   "model.calib.enabled": true,  "model.strategy.add.max_n_gaussians": 5000000, "difix.training.enabled": false}' ;;
    difix-2m)      echo '{"model.strategy.add.max_n_gaussians": 2000000, "difix.training.enabled": true,  "difix.training.start_step": 106000}' ;;
    difix-probe)   echo '{"model.strategy.add.max_n_gaussians": 2000000, "difix.training.enabled": true,  "difix.training.start_step": 3000}' ;;
    base-2m)       echo '{"model.strategy.add.max_n_gaussians": 2000000, "difix.training.enabled": false}' ;;
    lidardepth)    echo '{"dataset.n_train_sample_lidar_rays": 1024, "loss.lidar.lambda_": 0.005, "dataset.lidar_ids": ["lidar_top_structured"], "dataset.train_lidar_ids": ["lidar_top_structured"], "model.strategy.add.max_n_gaussians": 5000000}' ;;
    *) return 1 ;;
  esac
}
# ---------------------------------------------------------------------------

if [ $# -gt 0 ]; then ARMS="$*"; else ARMS="flatten flatten-calib"; fi

for ARM in $ARMS; do
  arm_overrides "$ARM" >/dev/null || { echo "!! unknown arm '$ARM'"; exit 1; }
done

mkdir -p rendered

# arm_check.py must be on the PVC before any job reaches its verification step
if [ -z "${DRYRUN:-}" ]; then
  kubectl exec -n $NS $POD -- mkdir -p /avl-west/runs/$RUNDIR /avl-west/nre_cache/difix || exit 1
  kubectl cp arm_check.py $NS/$POD:/avl-west/runs/$RUNDIR/arm_check.py || exit 1
  echo "[submit] arm_check.py -> /avl-west/runs/$RUNDIR/"
fi

for ARM in $ARMS; do
  OV=$(arm_overrides "$ARM"); CK=$(arm_check "$ARM"); BG=$(arm_budget "$ARM")
  CPU=$(arm_cpu "$ARM");      MEM=$(arm_mem "$ARM")
  SRC=$(arm_src "$ARM");      RL=$(arm_road_lidar "$ARM"); LD=$(arm_lidar "$ARM")
  for C in ${CLIPS:-$(arm_clips "$ARM")}; do
    OUT=rendered/$PREFIX-$ARM${SUFFIX:-}-$C.yaml
    sed -e "s|__PREFIX__|$PREFIX|g" \
        -e "s|__JOBSUFFIX__|${SUFFIX:-}|g" \
        -e "s|__ARM__|$ARM|g" \
        -e "s|__CLIP__|$C|g" \
        -e "s|__RUNDIR__|$RUNDIR|g" \
        -e "s|__BUDGET__|$BG|g" \
        -e "s|__OVERRIDES__|$OV|g" \
        -e "s|__ARMCHECK__|$CK|g" \
        -e "s|__CPU__|$CPU|g" \
        -e "s|__SRC__|$SRC|g" \
        -e "s|__LIDAR__|$LD|g" \
        -e "s|__ROADLIDAR__|$RL|g" \
        -e "s|__MEM__|$MEM|g" \
        "$TPL" > "$OUT"
    if [ -n "${DRYRUN:-}" ]; then echo "[dryrun] $OUT"; else
      kubectl apply -f "$OUT" && echo "[submit] $PREFIX-$ARM${SUFFIX:-}-$C"
    fi
  done
done

echo
echo "watch:   kubectl get pods -n $NS -l app=uturn_drift_geomreg,scene=$PREFIX"
echo "logs:    kubectl logs -n $NS -l arm=<arm>,clip=<clip> --tail=50"
echo "results: /avl-west/runs/$RUNDIR/recon/<arm>/<clip>/artifacts/last.usdz"
