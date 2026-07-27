#!/usr/bin/env bash
# Generates the 9 balanced-collection Job manifests for Flow-Planner-critic2 on
# Nautilus (cogrob). One Job per (k, shard); passes/shards per portable README's
# ~100k-balanced-per-k table. Each Job: rebuild nuplan-critic-rl env -> collect
# passes-mode (num_candidates=1) -> copy /tmp shard replay to CephFS.
set -euo pipefail
OUT_DIR="$(cd "$(dirname "$0")" && pwd)"

params_for() {  # K -> echoes "PASSES SHARDS"
  case "$1" in
    1)  echo "1 1"  ;;
    10) echo "7 1"  ;;
    20) echo "14 1" ;;
    40) echo "27 2" ;;
    80) echo "54 4" ;;
  esac
}

emit() {  # K SI SC PASSES
  local K=$1 SI=$2 SC=$3 P=$4
  local name="horuan-fpc2-h${K}-s${SI}"
  cat > "$OUT_DIR/${name}.yaml" <<YAML
# Balanced collection: k=${K}, shard ${SI}/${SC}, passes=${P} (~100k balanced tx per k
# over the 1008-scenario filter). num_candidates=1 (only candidate 0 is executed+stored
# under schema v3). 2x RTX-3090 / 16 CPU / 96Gi on a cogrob-reserved node.
# Watch: kubectl logs -n cogrob -f job/${name}
apiVersion: batch/v1
kind: Job
metadata:
  name: ${name}
  labels: {k8s-app: ${name}}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 604800   # 7 days (effectively no cap)
  ttlSecondsAfterFinished: 259200 # clean 3 days after finish
  template:
    metadata:
      labels: {k8s-app: ${name}}
    spec:
      restartPolicy: Never
      containers:
        - image: robinwangucsd/metabench:latest
          name: fpc2-collect
          command: ["bash", "-lc"]
          args:
            - |
              set -eo pipefail
              echo "=== [1/2] building nuplan-critic-rl env (idempotent) ==="
              bash /hugsim-storage/flowplanner-critic/environment/setup_nautilus_env.sh
              source /opt/conda/etc/profile.d/conda.sh && conda activate nuplan-critic-rl
              FORK=/hugsim-storage/Flow-Planner-critic2
              DEST=\$FORK/critic-training-data/aqc1008
              cd "\$FORK"; export PYTHONPATH="\$FORK"
              export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 NUMEXPR_NUM_THREADS=1 RAY_DEDUP_LOGS=1
              mkdir -p "\$DEST"
              OUT=\$DEST/replay_aqc1008_h${K}_s${SI}of${SC}.zarr
              if [ -d "\$OUT" ]; then echo "shard \$OUT already collected; skipping"; exit 0; fi
              echo "=== [2/2] collect k=${K} shard ${SI}/${SC} passes=${P} num_candidates=1 ==="
              BASE=/tmp/collect_aqc1008/replay_s${SI}.zarr
              python -u collect.py --config config/collect_aqc_1008_nautilus.yaml \\
                --execution-horizon ${K} --passes ${P} \\
                --shard-index ${SI} --shard-count ${SC} \\
                --workers 16 --out "\$BASE"
              SRC=/tmp/collect_aqc1008/replay_s${SI}_h${K}.zarr
              cp -a "\$SRC" "\$OUT.tmp"; rm -rf "\$OUT"; mv "\$OUT.tmp" "\$OUT"
              python -u -c "from flow_planner.critic_rl.replay import ZarrReplayReader as R; print('h${K} s${SI}/${SC} persisted transitions:', len(R('\$OUT')))"
              echo "COLLECT1008_h${K}_s${SI}of${SC}_DONE_OK -> \$OUT"
          resources:
            requests: {cpu: "16", memory: "160Gi", nvidia.com/gpu: "2", ephemeral-storage: 120Gi}
            limits:   {cpu: "16", memory: "160Gi", nvidia.com/gpu: "2", ephemeral-storage: 120Gi}
          volumeMounts:
            - {name: dshm, mountPath: /dev/shm}
            - {name: avl-west-vol, mountPath: /avl-west}
            - {name: closed-loop-e2e, mountPath: /closed-loop-e2e}
            - {name: hugsim-storage, mountPath: /hugsim-storage}
      volumes:
        - name: dshm
          emptyDir: {medium: Memory, sizeLimit: 24Gi}
        - name: avl-west-vol
          persistentVolumeClaim: {claimName: avl-west-vol}
        - name: closed-loop-e2e
          persistentVolumeClaim: {claimName: closed-loop-e2e}
        - name: hugsim-storage
          persistentVolumeClaim: {claimName: horuan-hugsim-vol}
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - {key: nvidia.com/gpu.product, operator: In, values: [NVIDIA-GeForce-RTX-3090]}
      tolerations:
        - {effect: NoSchedule, key: nautilus.io/reservation, operator: Equal, value: cogrob}
YAML
  echo "wrote ${name}.yaml (k=${K} shard ${SI}/${SC} passes=${P})"
}

for K in 1 10 20 40 80; do
  read P SC <<EOF
$(params_for "$K")
EOF
  for SI in $(seq 0 $((SC-1))); do
    emit "$K" "$SI" "$SC" "$P"
  done
done
