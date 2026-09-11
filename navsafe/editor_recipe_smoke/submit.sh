#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
case "${1:---dry-run}" in
 --dry-run) kubectl create --dry-run=server -f "$HERE/job.yaml" ;;
 --submit) kubectl create -f "$HERE/job.yaml" ;;
 *) echo "Usage: $0 [--dry-run|--submit]" >&2; exit 2 ;;
esac
