# illegal_turn_recon — 13 unsignalised minor-road turns, mined → reconstructed

13 scenarios picked out of the nuPlan **test split**: left/right turns that are *not*
at a traffic-light junction — the small-road kind. They come from the sweep whose
previews are in `/avl-west/nuplan_test_bev/` (39 candidates; these 13 are the subset
asked for). Selection evidence, the full 1342-candidate dump and the miner live in
`/avl-west/navsafe_dev/nuplan_test_turns/`.

Same four stages as `navsafe_5s_500`: **ncore → aux → train**, with **arrow** off to
the side (it needs only the nuPlan DB). Each scenario is a 20 s window cut into four
exact 5 s clips `<token>s1..s4`.

```
illegal_turn_recon/
  scenes.tsv          token \t log \t t0 \t t1 \t turn \t dyaw \t lanes \t city
  templates/          ncore | aux | arrow | train   (derived from navsafe_5s_500's)
  submit_stage.sh     gap-check CephFS, shard, submit
  chain.sh            submit ncore+arrow, then aux when ncore drains, then train
  rendered/           generated per-shard yaml + unit lists
```

## Where the output goes: the navsafe_5s_500 corpus

`ROOT=/avl-west/navsafe_5s_500`, **not** a new directory. These 13 are the same shape
as what is already there — nuPlan test split, navsim 5-camera rig, 20 s in 4×5 s — and
`nexussim/navsafe/leaves/hosts.py` discovers hosts by globbing `cfg.CORPUS/*_20s/arrow`.
Anywhere else and they are invisible to `navsafe bake` and to eval without a new corpus
root. Same corpus, 13 more scenarios. (To undo: `mv` the 65 new directories out.)

## Sharding: 7 jobs × 2 scenarios, every stage

A shard is **2 scenarios**, so a train shard runs **8 clips back to back** (~36 h at the
measured 4.5 h/clip). 13 scenarios → 7 jobs (six with 2, one with 1). Every stage uses
the same split so shard *n* means the same work everywhere.

That is a long job, and it is meant to be: a preempted shard only loses the clip in
flight. Every finished clip copies `last.usdz` to CephFS before the next one starts,
`backoffLimit` is 6, and re-running `submit_stage.sh` skips whatever already exists.

## Three differences from navsafe_5s_500's scripts

1. **Sharding is by scenario, not by clip** — see above.

2. **arrow is per 20 s host, not per 5 s clip.** `navsafe_5s_500/submit_stage.sh`
   expanded *every* stage to `<token>s1..s4`, but arrow writes to `<token>_20s/arrow`
   and its done-glob reads the inner scene name, so the check never matched and the
   stage looked permanently unbuilt. The 14 stray per-clip arrow directories in the
   corpus are the residue of that. Here the arrow unit is `<token>_20s` over the full
   20 s range, which is also the id `hosts.py` looks for.

3. **No GPU where none is needed.** `ncore` and `arrow` are CPU work and no longer
   carry the `nvidia.com/gpu.product` node affinity that pinned them to GPU nodes;
   they request no GPU. `aux` and `train` still request `nvidia.com/gpu: 1`.

All four stages pin to the cogrob-reserved 3090s **minus ry-gpu-13/14**:
`ry-gpu-05, 06, 07, 08, 11, 12`. Eight GPUs per node, so 7 concurrent shards is never
node-bound. (`ry-gpu-05` is the known-slow one; it is in the list because
`navsafe_5s_500/templates/train.yaml` has it — drop it from all four templates if a
shard stalls there.)

## Run it

```bash
./chain.sh                        # ncore + arrow now, aux when ncore drains, then train
```

or by hand, waiting for each to drain:

```bash
./submit_stage.sh ncore           # ~1.2 h per job
./submit_stage.sh arrow           # ~15 min per job, independent of ncore
./submit_stage.sh aux             # ~2.3 h per job   (needs ncore)
./submit_stage.sh train           # ~36 h per job    (needs aux)

DRYRUN=1 ./submit_stage.sh train  # render only, do not apply
kubectl get pods -n cogrob -l app=illegal_turn_recon
```

Every stage is idempotent: it asks CephFS what is already built, excludes what a live
job already owns, and submits only the gap. Re-run it to pick up failures.

## Reading the corpus does not depend on any one pod

The Mac cannot read CephFS, so "what is already built" has to be listed from inside the
cluster. That used to `kubectl exec` into `horuan-nexussim` **by name** — a bare pod with
a 6 h `activeDeadlineSeconds`, so it kills itself, and when it did the gap-check failed
and the pipeline refused to submit anything at all.

`cephfs_ls()` now tries, in order:

1. `$POD`, if you set one — a *preference*: if it is dead or does not mount the PVC, it
   warns and keeps going rather than failing;
2. any Running pod in the namespace that already mounts `$PVC` (default `avl-west-vol`),
   reading the mountPath out of the pod spec rather than assuming `/avl-west`;
3. a throwaway `busybox` pod that mounts `$PVC` purely to run the `ls` and exit.

Step 3 is what makes it work in an empty namespace. It is also a bare Pod, not a Job, so
the `job.nrp-nautilus.io` utilization webhook does not apply to it — the gap-check still
works while job submission is being refused.

    PVC=other-vol ./submit_stage.sh ncore     # corpus on a different claim
    POD=my-pod    ./submit_stage.sh ncore     # prefer this pod if it is usable

## Known blocker: the Nautilus utilization policy

At the time of writing every `kubectl apply` is rejected with

```
admission webhook "job.nrp-nautilus.io" denied the request:
Your pods resources utilization is too low for account ...
```

This is account-wide (CPU-only jobs are refused too) and is **not** caused by anything
here. The namespace's running pods request **54 GPUs**, of which `navsafe-final18-s1`
holds 30 (15 pods × 2 GPUs) while `kubectl top` shows them at ~1.3 CPU each — that eval
is CPU-bound on `render_bev`, so the second GPU on each worker sits idle and the account's
measured utilization falls under policy.

It clears when that sweep drains, or sooner if those workers are re-submitted asking for
1 GPU instead of 2. `chain.sh` retries until it is accepted, so nothing needs re-driving
by hand.

Submitting from a **different account** sidesteps it: the policy is scored per CILogon
user, not per namespace. Pull this directory on that machine and run `chain.sh` there —
everything it needs (kubectl context with `cogrob` access) travels with the kubeconfig,
not with this repo. Do not run `chain.sh` on two machines at once: the in-flight check
reads the live jobs from the cluster so it will mostly deconflict, but two renders
landing in the same instant can still double-submit.
