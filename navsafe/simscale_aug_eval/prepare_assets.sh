#!/usr/bin/env bash
set -euo pipefail

ROOT=${ROOT:-/avl-west/navsafe_eval/aug_zoo/SimScale}
HF=https://huggingface.co/datasets/OpenDriveLab/SimScale/resolve/main/SimScale_ckpts
SIMSCALE_SHA=e7eb8a0ef3bcc41e86ccfdf4d0e5c9bb4a5826a1

if ! command -v curl >/dev/null || ! command -v git >/dev/null; then
  apt-get update -qq
  apt-get install -y -qq curl git ca-certificates
fi

mkdir -p "$ROOT"/{LTF,DiffusionDrive,GTRS_Dense}

fetch() {
  local relative=$1 sha=$2
  local destination="$ROOT/$relative" partial
  partial="$destination.partial"
  mkdir -p "$(dirname "$destination")"
  if [ -f "$destination" ] && echo "$sha  $destination" | sha256sum -c - >/dev/null 2>&1; then
    echo "OK existing $relative"
    return
  fi
  curl -L --fail --retry 5 --retry-all-errors -C - -o "$partial" "$HF/$relative"
  echo "$sha  $partial" | sha256sum -c -
  mv "$partial" "$destination"
}

fetch LTF/ltf_sim_navhard.ckpt 265efc6322ee769510dd32cc7c83b465e73d4704568cef823824540198f04d42
fetch GTRS_Dense/gtrs_dense_resnet_sim_expert_navhard.ckpt 2496b82f5f256d7de09fca656c7634967b8660eb12e5c10386a587283629a7ff
fetch GTRS_Dense/gtrs_dense_resnet_sim_reward_navhard.ckpt 8dad0395332ccd844785cbfc7c9e24cb3f8d8dbf5cb9ca7f8f8dc75478fcf409
fetch GTRS_Dense/gtrs_dense_vov_sim_expert_navhard.ckpt badcf3e7c3e2ecc1d7ecb9fc744c78420c368f96e47b89d1681ade7833cd5e57
fetch GTRS_Dense/gtrs_dense_vov_sim_reward_navhard.ckpt 7567d269bd8d0757cf906c30612bf1ad167ac7310e8af0ead74dc7798fe54c99

if [ ! -d "$ROOT/source/.git" ]; then
  rm -rf "$ROOT/source.partial"
  git clone https://github.com/OpenDriveLab/SimScale.git "$ROOT/source.partial"
  git -C "$ROOT/source.partial" checkout --detach "$SIMSCALE_SHA"
  mv "$ROOT/source.partial" "$ROOT/source"
fi
test "$(git -C "$ROOT/source" rev-parse HEAD)" = "$SIMSCALE_SHA"
test -f "$ROOT/source/traj_final/8192.npy"

echo "SimScale assets ready at ${ROOT}"
