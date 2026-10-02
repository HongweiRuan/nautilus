#!/usr/bin/env bash
set -euo pipefail
kubectl get job -n cogrob navsafe-v8-nooverlay-20260923
kubectl get pods -n cogrob -l navsafe-batch=v8-nooverlay -o wide
