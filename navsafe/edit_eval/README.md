# edit_eval — 24 edited scenarios, five shards

What this run measures: whether the edited-scenario benchmark still behaves
after two corrections that landed on 2026-09-06.

* **The hand-off is now 8 frames everywhere.** V-10's ten recipes were frozen
  at 20 while the other seventy were at 8, and `eval_py123d.py:878` takes the
  *recipe's* value over the command line — so every earlier campaign that
  passed `--ego-replay-frames 20` actually ran 71 scenarios at 8 and 9 at 20.
  V-10's leaf and all ten of its recipes were re-baked at 8.
* **The camera rig is `recon`, not `navsim`.** Three earlier campaigns
  (`recheck-edit80`, `car-rescale-check`, `v10-cutin`) were rendered under the
  synthetic pinhole because a worker script exported the override. Nothing here
  sets `NUREC_GRPC_CAM_RIG`, so the renderer's calibrated default is used.

Neither of those is comparable with what came before, so this is a fresh run
into a fresh directory rather than a resume.

## What runs

| | |
|---|---|
| scenarios | 24 — two per edited leaf, and **all ten of V-10** |
| shards | 5 Jobs × 2 GPUs (one `nre`, one `sim`), **serial inside each shard** |
| per shard | 5, 5, 5, 5, 4 |
| policy | DrivoR, `drivor_Nav1_25epochs.pth`, LQR controller, replan 5 |
| episode | 8 replay frames + **150 eval frames**, terminate on collision |
| vis | `--enable-vis`, front + left + right (`CAM_F0,CAM_L0,CAM_R0` rendered, `CAM_L0,CAM_R0` panelled) |
| recipes | `/hugsim-storage/NexusSim/nexussim/navsafe/recipes/benchmark` — the authority |
| scenarios on disk | `/avl-west/navsafe_dev/full_test_mirror` — the published release |
| output | `/avl-west/runs/20260907-edit24-handoff8/` |

V-10 gets all ten because it is the leaf that changed. The other seven get the
same two hosts the 2026-09-05 twelve-scenario batch used, so the two runs can
be compared; `scenarios.txt` says why each pair was chosen.

## "The current recipes" is checked, not assumed

There are three copies of the eighty frozen recipes — the repo on the cluster,
the local clone, and `/avl-west/navsafe_dev/recipes/editing90` (which is what
`nexussim/navsafe/world/k8s_jobs.py:368` defaults to). They are kept identical
by hand, so this campaign names the authority outright and then verifies:

* before anything starts, each shard asserts that every recipe it is about to
  use is frozen at `replay_frames: 8`, and refuses to run if one is not;
* the sha256 of each recipe file is written to
  `$OUTROOT/logs/recipes-w<N>.sha256`, so a score can be traced to the exact
  file that produced it;
* after each episode the log is checked for eval_py123d's override warning,
  which should now never fire.

## Files

    scenarios.txt      the 24, in shard order, with the reason for each pick
    run_nre.sh         renderer container: serve-grpc over this shard's usdz
    run_sim.sh         eval container: bootstrap, preflight, then N rollouts
    templates/shard.yaml   the Job, with __NAME__/__IDX__/__N__/… placeholders
    submit.sh          renders and applies the five Jobs, one at a time
    status.sh          job/pod state and per-shard progress
    rendered/          the yaml actually submitted (written by submit.sh)

## Submitting

    ./submit.sh

It creates the `navsafe-editeval-cfg` ConfigMap from the two worker scripts and
`scenarios.txt`, then applies the five Jobs one at a time, backing off 5 min on
an admission refusal and 1 min on a transport error.

Overridable: `N`, `OUTROOT`, `REPLAY`, `EVALF`, `BACKOFF`, `NS`.

### What a different account needs

Everything here is namespace-scoped to `cogrob`, so a different account can
submit it unchanged **provided it can write to that namespace**. `submit.sh`
checks the three things that are not obvious before it applies anything:

* access to namespace `cogrob`;
* the PVCs `avl-west-vol` and `horuan-hugsim-vol` visible in it;
* the `ngc-pull` image-pull secret (a warning, not a stop — the pull only fails
  later if it is genuinely absent).

The reserved-node toleration and affinity are pod-level, not account-level, so
they do not need anything extra. The one thing that *is* account-level is the
utilisation policy the admission webhook applies — which is the point of
submitting from a different account.

## Watching it

    ./status.sh                      # jobs, pods, last 3 log lines per shard
    POD=<a pod with /avl-west> ./status.sh   # also counts .done and gifs

Per-scenario logs land in `$OUTROOT/logs/<LEAF>.<token>.log`; the renderer's in
`$OUTROOT/logs/nre-w<N>.log`. A shard that finishes writes
`$OUTROOT/logs/sim-done-w<N>` holding the eval's exit code — that file is also
how `nre` knows to stop, so the pod completes and gives its two GPUs back.

## Resuming

A scenario with a `.done` marker in its output directory is skipped, so a
re-applied Job picks up where it stopped. To force a redo, delete the marker or
the whole `$OUTROOT/<LEAF>.<token>/` directory.
