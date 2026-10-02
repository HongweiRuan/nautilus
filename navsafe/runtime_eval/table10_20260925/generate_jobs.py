#!/usr/bin/env python3
from pathlib import Path

tokens = "0027991369e05ab2 0578756b879c55d0 0a51eb8adf8e5391 13bb7469606159e9 1dc437ce152e55fa 2d24100bcb1e57e2 4874da28248a5026 6ad48974e9985e1f"
image = "nvcr.io/nvidia/nre/nre-ga@sha256:6e0caa70a9148490552520c3dde9ee665c8d094ca10b814601cb8bb306567c90"
nodes = [f"ry-gpu-{n:02d}.sdsc.optiputer.net" for n in (6, 7, 8, 11, 12, 13, 14)]
docs = []
for i, c in enumerate((1, 2, 4, 8)):
    cpu = 4 + 2 * c
    mem = 32 + 8 * c
    name = f"navsafe-table10-c{c}-20260925"
    node_lines = "\n".join(f"                      - {n}" for n in nodes)
    docs.append(f"""apiVersion: batch/v1
kind: Job
metadata:
  name: {name}
  namespace: cogrob
  labels: {{ app: navsafe-table10-20260925, concurrency: \"{c}\" }}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 14400
  ttlSecondsAfterFinished: 604800
  template:
    metadata:
      labels: {{ app: navsafe-table10-20260925, concurrency: \"{c}\" }}
    spec:
      restartPolicy: Never
      imagePullSecrets: [{{ name: ngc-pull }}]
      containers:
        - name: eval
          image: {image}
          imagePullPolicy: IfNotPresent
          command: [\"/opt/nvidia/nvidia_entrypoint.sh\", \"bash\", \"/cfg/run_worker.sh\"]
          env:
            - {{ name: WORKER_INDEX, value: \"{i}\" }}
            - {{ name: WORKERS, value: \"4\" }}
            - {{ name: CONCURRENCY, value: \"{c}\" }}
            - {{ name: SEEDS, value: \"1\" }}
            - {{ name: TABLE10_TOKENS, value: \"{tokens}\" }}
            - {{ name: NEXUSSIM_SHA, value: \"620ab1a27d209e46c76e818b6ea4fe30024d3d9b\" }}
            - {{ name: OUTROOT, value: \"/avl-west/navsafe_runtime/table10_drivor_20260925/c{c}\" }}
            - {{ name: MODELS_TSV, value: \"/cfg/models.tsv\" }}
            - {{ name: NGC_API_KEY, valueFrom: {{ secretKeyRef: {{ name: ngc-api-key, key: NGC_API_KEY }} }} }}
            - {{ name: HF_TOKEN, valueFrom: {{ secretKeyRef: {{ name: hf-token, key: HF_TOKEN }} }} }}
            - {{ name: HYDRA_FULL_ERROR, value: \"1\" }}
            - {{ name: ACCEPT_EULA, value: \"Y\" }}
            - {{ name: OMNI_KIT_ACCEPT_EULA, value: \"Y\" }}
          resources:
            requests: {{ cpu: \"{cpu}\", memory: \"{mem}Gi\", nvidia.com/gpu: \"2\", ephemeral-storage: \"60Gi\" }}
            limits:   {{ cpu: \"{cpu}\", memory: \"{mem}Gi\", nvidia.com/gpu: \"2\", ephemeral-storage: \"60Gi\" }}
          volumeMounts:
            - {{ name: dshm, mountPath: /dev/shm }}
            - {{ name: cfg, mountPath: /cfg }}
            - {{ name: avl-west-vol, mountPath: /avl-west }}
            - {{ name: hugsim-storage, mountPath: /hugsim-storage }}
      volumes:
        - {{ name: dshm, emptyDir: {{ medium: Memory, sizeLimit: 24Gi }} }}
        - {{ name: cfg, configMap: {{ name: navsafe-table10-20260925-cfg, defaultMode: 493 }} }}
        - {{ name: avl-west-vol, persistentVolumeClaim: {{ claimName: avl-west-vol }} }}
        - {{ name: hugsim-storage, persistentVolumeClaim: {{ claimName: horuan-hugsim-vol }} }}
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/hostname
                    operator: In
                    values:
{node_lines}
                  - key: nvidia.com/gpu.product
                    operator: In
                    values: [NVIDIA-GeForce-RTX-3090]
      tolerations:
        - {{ effect: NoSchedule, key: nautilus.io/reservation, operator: Equal, value: cogrob }}
        - {{ effect: NoSchedule, key: nautilus.io/cogrob, operator: Exists }}
""")
Path("jobs.base.yaml").write_text("\n---\n".join(docs))
