#!/usr/bin/env bash
# Compatibility entry point; arguments are now model names, not fleet names.
set -euo pipefail
exec "$(dirname "$0")/bin/submit.sh" "$@"
