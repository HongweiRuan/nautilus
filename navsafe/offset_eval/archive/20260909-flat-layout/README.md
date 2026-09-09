# offset_eval — hand-off perturbation sweep

Displace the ego **once**, on the frame the policy takes over, and see what it
plans instead. Same scenario, same traffic, same reconstruction, same seed — so
whatever changes between two offsets is the policy's sensitivity to that pose.

    output   /avl-west/runs/20260905-handoff-perturb-demo/eval/seed0/<leaf>/<token>/<arm>/<model>/
    code     NexusSim @ 70a8d7ed  (workers `git clone` the cluster checkout and
                                   `git checkout` this SHA, so a change has to be
                                   COMMITTED there to reach them)

## The grid

54 scenarios (2 per populated taxonomy leaf, fewest vehicles first) x 19 arms x
5 models = 5105 cells.

| axis | arms |
|---|---|
| baseline | `base` |
| lateral | `latp/latm 0.5, 1.0, 1.5` m |
| longitudinal | `lonp/lonm 0.5, 1.0, 1.5` m |
| yaw | `yawp/yawm 15, 30, 45` deg |

Every offset was screened offline before it was simulated: the displaced ego had
to stay on the drivable surface and keep 0.3 m from every other actor. A
scenario that failed any arm was rejected and the next-fewest-vehicle scenario in
that leaf took its place. `C-8` is capped at +/-1.0 m lateral, and
`d5812df28c1558ba` cannot take +45 deg, so it carries an `arms_run` list.

Models — one per benchmark category:

| model | category |
|---|---|
| `pdm_closed` | rule-based (privileged) |
| `diffusiondrive` | IL |
| `recogdrive_rl` | RLFT |
| `diffusiondrive_beyonddrive` | augmentation |
| `simwam` (SimWAM-RL) | world-model |

## Three fleets, and why

`nvidia.com/gpu` and the node affinity live in the Job's pod template, which is
immutable, so a change to either means delete-and-recreate. The worker script
reads `nvidia-smi -L` and lays itself out from the card count, so the manifests
and the script cannot disagree.

| fleet | workers | GPU | selection | models | renderer |
|---|---|---|---|---|---|
| `navsafe-perturb-w*` | 8 | 1 | `selection_plain.json` (46) | `models.tsv` (4) | `--cache-size 2` |
| `navsafe-edit-w*` | 8 | 2 | `selection_edit.json` (8) | `models.tsv` (4) | `--cache-size 4` |
| `navsafe-simwam-w*` | 12 | 2 | `selection.json` (54) | `models_simwam.tsv` | `--cache-size 4` |

= 48 GPUs.

**Why the plain/edit split.** A scenario is FOUR 5 s reconstructions
(`<token>s1..s4`), and a recipe's inserted actor is **not in the USDZ** — it is
injected at eval setup by an `edit_assets` RPC that mutates the render server's
*loaded copy* of each scene, with a snapshot kept so `close()` can undo it.
Insert into all four with `--cache-size 2` and the third insert evicts the first,
the fourth evicts the second, and each eviction takes its edit with it. Rendering
then starts at frame 0, which needs the FIRST segment — the first one evicted —
and the server, having reloaded it clean from disk, answers

    INVALID_ARGUMENT: 'navsafe_animal#ph0' is not in list

scored as `termination_reason=infra_failure`, `total_frames: 0`. So the cache
must hold at least as many scenes as the scenario has segments; that is a
correctness floor, not a speed knob. Measured over the same hours: 13/13 of R-4's
cells scored on a `--cache-size 4` fleet while 40/40 failed on `--cache-size 2`.

Only 8 of the 54 scenarios carry a recipe that inserts (`C-7` x1, `I-3` x2,
`R-2` x1, `R-3` x2, `R-4` x2), so only those 8 pay for the second card. The
other 46 insert nothing, an eviction there costs a reload and nothing else, and
one card is correct.

SimWAM is on two cards whatever the scenario: it needs 12.6 GiB of its own.

**Why `ry-gpu-08` is out of the two-card fleets.** Its device plugin fails
`GetPreferredAllocation` for a multi-GPU request — it queries the NVLink state
between the two devices it would hand out and one is gone (the node advertises 7
now, not 8) — while the node stays Ready, so the scheduler keeps placing two-card
pods there and the kubelet keeps rejecting them at admission. 38 rejections in
20 minutes, each burning one of the Job's 20 retries. A one-card request never
takes that path, so the plain fleet keeps the node.

## Running it

    bin/submit.sh          bring all three fleets up, probing until every job is in
    bin/exclude_node.sh    recreate the two-card fleets without a bad node
    bin/admitprobe.py      rename a manifest so --dry-run=server tests the WEBHOOK
                           and not an immutable-field patch

`bin/admitprobe.py` exists because probing a Job under its own name is useless
once the Job exists: a Job spec is immutable, so the dry run fails on `field is
immutable` whatever the utilisation webhook thinks, and a script that reads that
as "refused" waits forever.

Resuming is free and automatic. A cell counts as done only when eval's own
`DONE.` line, `navsafe_metrics.json` **and** `plan_records.json` are all present
(`run_worker.sh`), so a cell that failed or timed out is redone and a finished
one is skipped. Nothing has to be tracked by hand.

## Config the workers read from the ConfigMap

    kubectl create configmap navsafe-perturb-cfg -n cogrob \
      --from-file=run_worker.sh=config/run_worker.sh \
      --from-file=models.tsv=config/models.tsv \
      --from-file=models_simwam.tsv=config/models_simwam.tsv \
      --from-file=selection.json=config/selection.json \
      --from-file=selection_plain.json=config/selection_plain.json \
      --from-file=selection_edit.json=config/selection_edit.json \
      --dry-run=client -o yaml | kubectl apply -f -

A pod reads `/cfg` once at startup, so a ConfigMap change reaches the fleet by
deleting the PODS — the Job controller recreates them and the utilisation
webhook is never consulted. Deleting the JOBS instead risks losing them for the
length of a cooldown.

## Gotchas that cost time here

* `seq -w 0 7` pads to the width of its LARGEST argument and yields `0..7`, not
  `00..07`. Use `printf %02d`.
* Kubernetes parses YAML 1.1, where a bare `Y` is a **boolean**. `ACCEPT_EULA`'s
  value must be quoted or the API rejects the object before the webhook sees it.
* The utilisation webhook refuses on **GPU** utilisation, which measured 13.2%
  across the fleet. Memory was never the violator (27-73% of request, inside the
  20-150% band). Deleting everything does not reset the cooldown — measured: a
  probe immediately after a full teardown was still refused.
* Nautilus caps the memory *limit* at 1.2x the *request*, so a small request with
  a generous limit is not an option.
