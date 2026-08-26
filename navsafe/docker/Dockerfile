# =============================================================================
# NexusSim all-in-one image.
#
# One environment that does the WHOLE NexusSim pipeline:
#   convert (wod -> py123d)  |  train  |  export  |  serve-grpc render  |  rollout
#
# Base MUST be NVIDIA NRE (nre-ga): the `/app/run` toolchain (train/export/serve)
# is distributed ONLY as this container and is NOT pip-installable. On top of it
# we add the X11/GL libs IsaacSim needs, plus two ISOLATED venvs so the rollout
# (isaacsim/torch) and the converter (tensorflow-cpu/py123d) don't fight over deps.
#
# LICENSE: the built image CONTAINS NRE. Do NOT push it to a public registry
# (that redistributes NVIDIA's gated NRE, against its EULA). Ship THIS Dockerfile;
# each user builds it with their own NGC credentials:
#   echo "$NGC_API_KEY" | docker login nvcr.io -u '$oauthtoken' --password-stdin
#   docker build -t nexussim-allinone -f docker/Dockerfile .
# =============================================================================
ARG NRE_BASE=nvcr.io/nvidia/nre/nre-ga@sha256:6e0caa70a9148490552520c3dde9ee665c8d094ca10b814601cb8bb306567c90
FROM ${NRE_BASE}

ENV DEBIAN_FRONTEND=noninteractive

# ---- 1) system libs: git/curl + IsaacSim's RTX/MDL(iray) GL runtime deps -----
# nre-ga is a minimal CUDA runtime; without these Kit segfaults in the rtx
# scenerenderer on boot (missing libGLU.so.1 / libXt.so.6 / ...).
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      git curl ca-certificates python3-venv \
      libglu1-mesa libxt6 libgl1 libglx0 libegl1 libglib2.0-0 \
      libxrandr2 libxinerama1 libxcursor1 libxi6 libxext6 libxrender1 \
      libx11-6 libxfixes3 libxdamage1 libsm6 libice6 libgomp1 \
    && rm -rf /var/lib/apt/lists/*

# ---- 2) uv (Ubuntu 24.04 system pip is PEP668-managed; install uv standalone)-
# Pin the install dir to /usr/local/bin (already on PATH): the installer's default
# target is $HOME/.local/bin, and $HOME during a build RUN on this base is NOT
# reliably /root (seen flipping between /root and /home), so don't depend on it.
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# ---- 3) venv-conv: wod -> py123d conversion (CPU-only, isolated) -------------
RUN python -m venv /opt/venv-conv \
    && /opt/venv-conv/bin/pip install --quiet --no-cache-dir \
         "py123d==0.5.1" tensorflow-cpu opencv-python-headless

# ---- 4) venv-sim: IsaacSim + IsaacLab + NexusSim (rollout) -------------------
# IsaacLab pinned to the version the eval targets.
ARG ISAACLAB_REF=v3.0.0-beta
RUN git clone --depth 1 --branch ${ISAACLAB_REF} \
      https://github.com/isaac-sim/IsaacLab.git /opt/IsaacLab

# The NexusSim code comes from the BUILD CONTEXT (this Dockerfile lives IN the repo),
# so NO repo auth is needed — build from the repo root:
#   docker build -t nexussim-allinone -f docker/Dockerfile .
# It's baked as the default; a developer can still mount a fresh checkout at runtime
# via NEXUSSIM_SRC and the entrypoint will editable-reinstall it (no rebuild needed).
ENV UV_PROJECT_ENVIRONMENT=/opt/venv-sim VIRTUAL_ENV=/opt/venv-sim UV_CACHE_DIR=/opt/uv-cache
COPY . /opt/nexussim
RUN --mount=type=cache,target=/opt/uv-cache \
    set -eux; cd /opt/nexussim; \
    uv sync --all-extras --python 3.12; \
    for ext in isaaclab isaaclab_assets isaaclab_tasks isaaclab_rl isaaclab_mimic; do \
      d=/opt/IsaacLab/source/$ext; [ -d "$d" ] && uv pip install --python /opt/venv-sim/bin/python --no-deps -e "$d"; \
    done; \
    uv pip install --python /opt/venv-sim/bin/python lazy_loader einops grpcio protobuf

RUN cp /opt/nexussim/docker/nexussim /usr/local/bin/nexussim && chmod +x /usr/local/bin/nexussim

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/nexussim"]
CMD ["help"]
