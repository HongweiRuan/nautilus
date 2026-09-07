#!/usr/bin/env python3
"""Stage B: one FDpi^k feature per anchor from a NavSafe VLA/world-model row.

The evaluator's own `run_feature_dump.py` cannot do this. It hooks agents that
live inside the evaluator's navsim; these models live in NexusSim and run under
their own venv, so the hook has to be installed here, in their process, on the
module the model actually computes.

Same npz contract as the evaluator's dumper, so `compute_fd.py` consumes the
output unchanged:

    features (N,D) float32 (NaN where skipped) | sample_tokens (N,) |
    skip_reason (N,) | agent | variation | hook_module | pool

A skipped row is how a per-model N is expressed: `compute_fd.py` intersects on
sample_tokens and drops NaN rows, so a model that needs earlier frames simply
scores on fewer anchors -- 3,870 of 4,175 for DriveVLA-W0, 3,678 for DriveLaW,
measured on this manifest -- without breaking comparability with itself.

WHY EACH TAP POINT. Every one of these models runs an ITERATIVE head (diffusion
or autoregressive decoding), so a tap inside it fires many times per anchor and
the feature would depend on step count, not on the picture. Each tap below is
therefore the last thing computed ONCE from the image, before the loop starts --
the same place `drivor_f0` taps in the published panel (`image_backbone:output`).
"""
from __future__ import annotations
import argparse, importlib.util, json, os, sys, traceback
from pathlib import Path
from typing import Any, Dict, List

import numpy as np
import torch

SERVER_DIR = Path(os.environ.get(
    "NAVSAFE_VLA_SERVER_DIR",
    "/root/ns/nexussim/modelzoo/navsim/vla_server"))


def _load_server_module(name: str):
    """Import a vla_server file as a module, so its own preprocessing is reused.

    Reimplementing the resize, the prompt or the normalisation here would be a
    second copy that silently drifts from the one the closed-loop eval runs.
    """
    path = SERVER_DIR / f"{name}_server.py"
    if not path.exists():
        raise SystemExit(f"server module not found: {path}")
    spec = importlib.util.spec_from_file_location(f"_vs_{name}", path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


class Capture:
    """Holds the hooked module's pooled output for the current anchor."""

    def __init__(self, pool: str):
        self.pool, self.value, self.calls, self.raw_shape = pool, None, 0, None

    def reset(self):
        self.value, self.calls, self.raw_shape = None, 0, None

    def take(self, t: torch.Tensor):
        self.calls += 1
        t = t.detach().float()
        self.raw_shape = tuple(t.shape)
        if self.pool == "token":        # (B, L, D) -> (B, D)
            v = t.mean(dim=1) if t.ndim == 3 else t
        elif self.pool == "spatial":    # (B, C, H, W) -> (B, C)
            v = t.flatten(2).mean(-1) if t.ndim == 4 else t
        elif self.pool == "last_dim":
            v = t.reshape(-1, t.shape[-1]).mean(0, keepdim=True)
        else:
            raise ValueError(f"unknown pool {self.pool!r}")
        self.value = v.reshape(-1).cpu().numpy().astype(np.float32)


# ---------------------------------------------------------------- adapters
#
# Each adapter builds the model through its own server module and returns
# (model_obj, hook_target, pool, hook_desc, run_one). `run_one(row, img_paths)`
# performs exactly the forward the closed-loop eval performs.

def _simwam(a, mod):
    """SimWAM: the action expert of a world-action model. One frame, no history.

    Tap: `video_expert.pre_dit`. `infer_action` calls it ONCE, on the VAE latents
    of the single input frame plus the cached prompt and the proprio vector, and
    only then enters the 10-step action diffusion — read off
    src/simwam/models/wan22/simwam.py, not assumed. Its output["tokens"] is
    (B, L, D): the model's own representation of the scene it was shown, which
    is the same kind of quantity `drivor_f0` contributes to the panel.

    The model comes from the server's own `build()`. An earlier version of this
    adapter repeated those forty lines instead, and was already wrong by the
    time it first ran: 70a8d7ed had moved construction to the CPU because
    building on the card overruns a 24 GB 3090, and the copy here still asked
    the factory for cuda.
    """
    import argparse as _ap
    import torch as _t
    ns = _ap.Namespace(
        repo=a.repo, checkpoint=a.checkpoint, task=a.task,
        num_inference_steps=a.num_inference_steps,
        action_horizon=a.action_horizon, seed=a.seed,
        device=None, model_base_path=a.model_base_path,
    )
    model, ctx = mod.build(ns)

    def run_one(row, paths):
        st = list(row["cmd_onehot"]) + list(row["vel"]) + list(row["acc"])
        cmd, vel, acc = st[0:4], st[4:6], st[6:8]
        # SimWAM's own order: velocity, acceleration, command.
        proprio = _t.tensor(vel + acc + cmd, dtype=_t.float32)
        with _t.no_grad():
            model.infer_action(
                prompt=None, context=ctx[0], context_mask=ctx[1],
                input_image=mod._image_tensor(str(paths[0])),
                action_horizon=int(a.action_horizon),
                proprio=proprio,
                num_inference_steps=int(a.num_inference_steps),
                seed=int(a.seed),
            )

    # (object, attribute), not the module: pre_dit is a method on video_expert.
    return (model, (model.video_expert, "pre_dit"), "token",
            "video_expert.pre_dit:return[tokens] (pre-diffusion scene tokens)",
            run_one)


ADAPTERS = {"simwam": _simwam}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True, choices=sorted(ADAPTERS))
    ap.add_argument("--variation", required=True,
                    help="farm name, or 'original' for the real navsim frames")
    ap.add_argument("--render-root", default="/avl-west/drivearena_bench/render/navsim")
    ap.add_argument("--gt-root", default="/avl-west/navsim/test_sensor_blobs/test")
    ap.add_argument("--token-table", default="/avl-west/fidelity_eval/fdpik_vla/token_table.json")
    ap.add_argument("--out", required=True)
    ap.add_argument("--limit", type=int, default=0, help="probe mode: first N anchors")
    # simwam
    ap.add_argument("--repo", default="/avl-west/navsafe_eval/vla_repos/SimWAM")
    ap.add_argument("--checkpoint", default="/avl-west/navsafe_eval/model_zoo/simwam/weights/SimWAM-RL.pt")
    ap.add_argument("--task", default="navsim_uncond_front_384x672_1e-4")
    ap.add_argument("--num-inference-steps", type=int, default=10)
    ap.add_argument("--action-horizon", type=int, default=8)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--model-base-path",
                    default="/avl-west/navsafe_eval/model_zoo/_base/diffsynth")
    a = ap.parse_args()

    table: Dict[str, Any] = json.load(open(a.token_table))
    tokens: List[str] = sorted(table)
    if a.limit:
        tokens = tokens[: a.limit]

    root = Path(a.gt_root) if a.variation == "original" \
        else Path(a.render_root) / f"{a.variation}_navtest_frame"

    mod = _load_server_module(a.model)
    model, target, pool, hook_desc, run_one = ADAPTERS[a.model](a, mod)
    cap = Capture(pool)

    def _capture(out):
        t = out["tokens"] if isinstance(out, dict) and "tokens" in out else out
        if isinstance(t, (tuple, list)):
            t = t[0]
        cap.take(t)

    # A tap is either an nn.Module (forward hook) or an (object, attribute)
    # pair naming a METHOD to wrap. SimWAM's `pre_dit` is the latter: it is a
    # method on video_expert, not a submodule, so register_forward_hook does
    # not apply to it -- an earlier version assumed a module and died with
    # "'function' object has no attribute 'register_forward_hook'".
    # Wrapping is not a lesser substitute: the value wanted IS this call's
    # return, and a wrapper sees exactly the calls the model makes.
    if isinstance(target, tuple):
        _obj, _attr = target
        _orig = getattr(_obj, _attr)

        def _wrapped(*args, **kwargs):
            out = _orig(*args, **kwargs)
            _capture(out)
            return out

        setattr(_obj, _attr, _wrapped)

        class _H:
            @staticmethod
            def remove():
                setattr(_obj, _attr, _orig)

        handle = _H()
    else:
        handle = target.register_forward_hook(
            lambda _m, _a, out: _capture(out))

    feats: List[np.ndarray] = []
    skips: List[str] = []
    dim = None
    for n, tok in enumerate(tokens, 1):
        row = table[tok]
        paths = [root / row["image"]] + [root / p for p in row["prev"]]
        missing = [str(p) for p in paths if not p.exists()]
        if missing:
            feats.append(None); skips.append(f"missing_frame:{Path(missing[0]).name}")
            continue
        cap.reset()
        try:
            run_one(row, paths)
        except Exception as exc:  # noqa: BLE001
            feats.append(None); skips.append(f"forward_error:{type(exc).__name__}")
            print(f"[{tok}] {traceback.format_exc()}", file=sys.stderr)
            continue
        if cap.value is None:
            feats.append(None); skips.append("hook_did_not_fire"); continue
        if cap.calls != 1:
            # A tap that fires per diffusion step would make the feature depend
            # on the step count rather than on the picture; refuse rather than
            # silently average.
            handle.remove()
            raise SystemExit(
                f"hook fired {cap.calls} times for one anchor (raw {cap.raw_shape}); "
                f"tap point {hook_desc!r} is inside the iterative head")
        if dim is None:
            dim = cap.value.shape[0]
        elif cap.value.shape[0] != dim:
            feats.append(None); skips.append("dim_mismatch"); continue
        feats.append(cap.value); skips.append("")
        if n % 200 == 0:
            print(f"  {n}/{len(tokens)}", flush=True)
    handle.remove()

    if dim is None:
        raise SystemExit("no anchor produced a feature")
    arr = np.full((len(tokens), dim), np.nan, dtype=np.float32)
    for i, f in enumerate(feats):
        if f is not None:
            arr[i] = f
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    np.savez(a.out,
             features=arr,
             sample_tokens=np.asarray(tokens, dtype="<U32"),
             skip_reason=np.asarray(skips, dtype="<U48"),
             agent=a.model, variation=a.variation,
             hook_module=hook_desc, pool=pool)
    ok = sum(1 for s in skips if s == "")
    print(f"wrote {a.out}: {ok}/{len(tokens)} anchors, D={dim}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
