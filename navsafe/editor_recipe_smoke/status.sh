#!/usr/bin/env bash
set -euo pipefail
kubectl get job -n cogrob ns-editor-c1-c2-drivor-200-v1
kubectl get pods -n cogrob -l job-name=ns-editor-c1-c2-drivor-200-v1 -o wide
