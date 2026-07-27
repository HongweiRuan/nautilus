#!/usr/bin/env python3
"""navhard 421-scene batch orchestrator (filesystem-as-state).

Drives every scene in navhard_scenes.tsv through the 6-stage pipeline
    convert -> aux -> arrow -> train -> export -> eval
by submitting one templated k8s Job per (stage, scene), respecting concurrency
caps, and advancing scenes as their artifacts appear on the PVC.

State is the PVC filesystem: a stage is "done" iff its output artifact exists
under /avl-west/navsafe/. This makes the controller idempotent and resumable —
kill it anytime, re-run, it picks up where the artifacts left off. Job objects
are the "running" state (labels batch=navsafe, stage=<stage>).

DAG (not a straight chain): arrow parallels aux+train+export; eval needs BOTH
export AND arrow.

Runs either:
  * locally (Mac): PVC checks via `kubectl exec navsafe-util`, kubectl via kubeconfig.
  * in-cluster (Deployment): PVC mounted at /avl-west (fast os.path), kubectl via SA.

  python orchestrate.py --once --dry-run              # one pass, log only
  python orchestrate.py --once --max-scenes 2         # one real pass, first 2 scenes
  python orchestrate.py --loop --interval 60          # continuous (the Deployment mode)
"""
from __future__ import annotations
import argparse, json, os, subprocess, sys, time
from pathlib import Path

NS = "cogrob"
NAVSAFE = "/avl-west/navsafe"
UTIL_POD = "deploy/navsafe-util"  # a Deployment (self-heals at the 6h pod deadline)
# Export stage dropped: training emits artifacts/last.usdz in-process (correct
# track count); a separate export re-reads the store and re-classifies borderline
# dynamic tracks => state_dict size mismatch on busy scenes. eval serves the train usdz.
STAGES = ["convert", "aux", "arrow", "train", "eval"]
DEPS = {"convert": [], "aux": ["convert"], "arrow": ["convert"],
        "train": ["aux"], "eval": ["train", "arrow"]}
GPU_STAGES = {"aux", "train", "eval"}
CPU_STAGES = {"convert", "arrow"}
# Submission priority: eval FIRST but hard-capped low (eval_cap) so it always keeps a
# steady floor running (else train/aux abundance starves it to 0), while the cap keeps
# eval's ~20min 0%-GPU IsaacSim-setup idle to only a few slots so it doesn't drag the
# util metric / trip the util-policy. train+aux (100% GPU) fill everything else.
GPU_PRIORITY = ["eval", "train", "aux"]
CPU_PRIORITY = ["arrow", "convert"]
HERE = Path(__file__).resolve().parent


def sh(cmd: list[str], check=True, quiet=False) -> str:
    r = subprocess.run(cmd, capture_output=True, text=True)
    if check and r.returncode != 0 and not quiet:
        sys.stderr.write(f"[cmd-fail] {' '.join(cmd[:6])}...\n{r.stderr[-800:]}\n")
    return r.stdout


# ---- PVC access: local os.path if mounted, else via `kubectl exec navsafe-util` ----
LOCAL_PVC = os.path.isdir(f"{NAVSAFE}/state")


def pvc_bash(script: str) -> str:
    if LOCAL_PVC:
        return subprocess.run(["bash", "-c", script], capture_output=True, text=True).stdout
    # Single-shot; callers that need a completion guarantee (probe_done) retry on a
    # missing sentinel. `deploy/navsafe-util` targets whatever pod is live, so it rides
    # across the util Deployment's 6h-deadline recreation.
    return sh(["kubectl", "exec", "-n", NS, UTIL_POD, "--", "bash", "-c", script], quiet=True)


def probe_done(tokens: list[str]) -> dict[str, set]:
    """Return {token: set(done_stages)} by scanning output artifacts on the PVC.
    Returns None if the probe didn't complete (so the caller skips the pass).

    Uses 5 `find` traversals (one per stage marker) instead of ~5 stats/scene — the
    per-scene form did ~2100 sequential NFS stats/pass, slow enough to intermittently
    truncate the exec output (missing sentinel -> spurious skip / GPU drain)."""
    script = f'''
NS={NAVSAFE}
find $NS/ncore -maxdepth 3 -name 'pai_*.json' 2>/dev/null | while read f; do n=$(basename "$f" .json); echo "convert ${{n#pai_}}"; done
find $NS/ncore -maxdepth 3 -name '*.aux-meta.json' 2>/dev/null | while read f; do echo "aux $(basename "$f" .aux-meta.json)"; done
find $NS/arrow/logs/nuplan_test -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while read d; do echo "arrow $(basename "$d")"; done
find $NS/training -maxdepth 4 -name 'last.usdz' 2>/dev/null | while read f; do echo "train $(basename "$(dirname "$(dirname "$f")")")"; done
find $NS/eval -maxdepth 4 -name 'metrics.json' 2>/dev/null | while read f; do echo "eval $(basename "$(dirname "$(dirname "$(dirname "$f")")")")"; done
echo __PROBE_OK__'''
    out = ""
    for _ in range(3):
        out = pvc_bash(script)
        if "__PROBE_OK__" in out:
            break
        time.sleep(5)
    if "__PROBE_OK__" not in out:
        return None
    want = set(tokens)
    done: dict[str, set] = {t: set() for t in tokens}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        stage, tok = parts
        if tok in want and stage in STAGES:
            done[tok].add(stage)
    return done


# ---- Job state ----
def job_states() -> dict[str, str]:
    """{'<stage>-<token>': 'active'|'succeeded'|'failed'} for batch=navsafe jobs."""
    out = sh(["kubectl", "get", "jobs", "-n", NS, "-l", "batch=navsafe",
              "-o", "json"], quiet=True)
    states: dict[str, str] = {}
    try:
        items = json.loads(out or "{}").get("items", [])
    except json.JSONDecodeError:
        return states
    for it in items:
        name = it["metadata"]["name"]  # navsafe-<stage>-<token>
        st = it.get("status", {})
        if st.get("active", 0):
            states[name] = "active"
        elif st.get("succeeded", 0):
            states[name] = "succeeded"
        elif st.get("failed", 0):
            states[name] = "failed"
        else:
            states[name] = "active"  # just created, not yet scheduled
    return states


def jobname(stage: str, token: str) -> str:
    return f"navsafe-{stage}-{token}"


# ---- attempts bookkeeping (single JSON on PVC) ----
def load_attempts() -> dict:
    out = pvc_bash(f'cat {NAVSAFE}/state/attempts.json 2>/dev/null || echo "{{}}"')
    try:
        return json.loads(out or "{}")
    except json.JSONDecodeError:
        return {}


def save_attempts(att: dict):
    blob = json.dumps(att).replace("'", "'\\''")
    pvc_bash(f"mkdir -p {NAVSAFE}/state && printf '%s' '{blob}' > {NAVSAFE}/state/attempts.json")


# ---- submission ----
def render(stage: str, row: dict) -> str:
    tmpl_dir = os.environ.get("TEMPLATE_DIR", str(HERE / "templates"))
    text = Path(tmpl_dir, f"{stage}.yaml").read_text()
    return (text.replace("__SCENE__", row["token"]).replace("__LOG__", row["log"])
            .replace("__T0__", row["t0"]).replace("__T1__", row["t1"]))


def submit(stage: str, row: dict, dry: bool):
    """Return (ok, denied). denied=True for Nautilus util-policy / webhook denials
    (transient, cluster-wide) so the caller can back off instead of spamming."""
    y = render(stage, row)
    if dry:
        print(f"  [dry] would submit {jobname(stage, row['token'])}")
        return True, False
    r = subprocess.run(["kubectl", "apply", "-f", "-"], input=y, capture_output=True, text=True)
    ok = r.returncode == 0
    denied = (not ok) and any(s in r.stderr for s in
                              ("utilization is too low", "denied the request", "webhook"))
    if ok:
        print(f"  [submit] {jobname(stage, row['token'])} -> ok")
    elif denied:
        print(f"  [submit] {jobname(stage, row['token'])} -> DENIED (util-policy/webhook), backing off pass")
    else:
        print(f"  [submit] {jobname(stage, row['token'])} -> FAIL: {r.stderr[-160:]}")
    return ok, denied


def delete_job(stage: str, token: str):
    sh(["kubectl", "delete", "job", jobname(stage, token), "-n", NS,
        "--ignore-not-found"], quiet=True)


def read_scenes(tsv: Path, only=None, limit=None) -> list[dict]:
    rows = []
    for i, line in enumerate(tsv.read_text().splitlines()):
        if i == 0 or not line.strip():
            continue
        f = line.split("\t")
        # token log t0 t1 db_split map map_ok db_ready nframes
        row = {"token": f[0], "log": f[1], "t0": f[2], "t1": f[3],
               "map_ok": f[6], "db_ready": f[7]}
        if row["db_ready"] != "Y" or row["map_ok"] != "Y":
            continue
        if only and row["token"] not in only:
            continue
        rows.append(row)
    if limit:
        rows = rows[:limit]
    return rows


def reconcile(rows, gpu_cap, cpu_cap, max_attempts, dry, max_submit_per_pass=8, eval_cap=8) -> dict:
    # Completion is derived from k8s JOB status, not a PVC scan: a *succeeded* job
    # means that stage is fully done (a running/failed job is not — this inherently
    # avoids the partial-write races the artifact probe had, e.g. aux's 4 itars or a
    # half-written store). One fast `kubectl get jobs` call; no util-pod dependency,
    # no slow NFS traversal. Valid within ttlSecondsAfterFinished (3 days); the run
    # finishes well inside that, and succeeded jobs persist across loop restarts.
    jobs = job_states()
    if not jobs:
        # No jobs visible at all almost certainly means the kubectl call failed, not a
        # genuinely empty run — skip rather than resubmit everything from scratch.
        print("[pass] SKIPPED — job query returned nothing; not submitting")
        return {"done_scenes": -1, "running": 0, "stuck": 0, "submitted": 0,
                "gpu_active": 0, "cpu_active": 0, "total": len(rows)}
    att = load_attempts()
    att_dirty = False

    gpu_active = sum(1 for n, s in jobs.items() if s == "active"
                     and n.split("-")[1] in GPU_STAGES)
    cpu_active = sum(1 for n, s in jobs.items() if s == "active"
                     and n.split("-")[1] in CPU_STAGES)
    # eval spends its first ~20min in an IsaacSim build at 0% GPU; too many concurrent
    # evals drag the account's aggregate GPU-utilization below Nautilus's util-policy
    # threshold -> it denies ALL new submits -> GPU can't fill. Cap eval so the idle
    # slots stay few; aux+train (both 100% GPU) fill the rest.
    eval_active = sum(1 for n, s in jobs.items() if s == "active"
                      and n.split("-")[1] == "eval")

    # gather submittable (stage, row) candidates
    cand_gpu, cand_cpu = [], []
    stats = {"done_scenes": 0, "running": 0, "stuck": 0, "submitted": 0}
    for r in rows:
        tok = r["token"]
        # done stages = jobs that SUCCEEDED (active/failed/absent are not-done).
        d = {s for s in STAGES if jobs.get(jobname(s, tok)) == "succeeded"}
        if len(d) == len(STAGES):
            stats["done_scenes"] += 1
            continue
        for stage in STAGES:
            if stage in d or not set(DEPS[stage]).issubset(d):
                continue
            name = jobname(stage, tok)
            st = jobs.get(name)
            if st == "active":
                stats["running"] += 1
                continue
            if st == "succeeded":
                continue  # artifact will appear next probe; nothing to do
            if st == "failed":
                k = f"{tok}:{stage}"
                n = att.get(k, 0)
                if n >= max_attempts:
                    stats["stuck"] += 1
                    continue
                att[k] = n + 1
                att_dirty = True
                if not dry:
                    delete_job(stage, tok)
                print(f"  [retry {n+1}/{max_attempts}] {name}")
            # no job (or just-deleted failed) -> candidate
            (cand_gpu if stage in GPU_STAGES else cand_cpu).append((stage, r))

    # submit by priority. Cap ATTEMPTS at the remaining budget (not just successes)
    # and back off the whole pass on a util-policy/webhook denial — otherwise a
    # cluster-wide denial makes us try every candidate, spamming the admission
    # webhook (which then times out). Next pass retries after the metric recovers.
    def order(cands, prio):
        return sorted(cands, key=lambda sr: prio.index(sr[0]))

    # Also cap NEW submits per pass (ramp-rate limit): submitting a big burst at
    # once (e.g. filling 0->50 after a restart) re-trips the Nautilus util-policy.
    # Ramp gradually — a few per pass reaches the cap over several passes.
    per_pass = [max_submit_per_pass]  # list = mutable across both loops
    # PARTITION the GPU: reserve eval_cap slots for eval, the rest for aux+train. A
    # single shared budget starves eval — the huge aux/train backlog fills all 50
    # slots and eval (though first-priority) never sees a free one. With a partition,
    # aux+train are capped at gpu_cap-eval_cap so eval always has physical slots.
    at_active = sum(1 for n, s in jobs.items() if s == "active"
                    and n.split("-")[1] in ("aux", "train"))
    eval_budget = max(0, eval_cap - eval_active)
    other_budget = max(0, (gpu_cap - eval_cap) - at_active)
    for stage, r in order(cand_gpu, GPU_PRIORITY):
        if per_pass[0] <= 0:
            break
        if stage == "eval":
            if eval_budget <= 0:
                continue
        else:
            if other_budget <= 0:
                continue
        ok, denied = submit(stage, r, dry)
        if ok:
            stats["submitted"] += 1
            per_pass[0] -= 1
            if stage == "eval":
                eval_budget -= 1
            else:
                other_budget -= 1
        elif denied:
            # eval denials shouldn't stall aux/train (and vice-versa): skip this
            # candidate but keep filling the other partition.
            if stage == "eval":
                eval_budget = 0
            else:
                break
    cpu_budget = max(0, cpu_cap - cpu_active)
    for stage, r in order(cand_cpu, CPU_PRIORITY):
        if cpu_budget <= 0 or per_pass[0] <= 0:
            break
        cpu_budget -= 1
        ok, denied = submit(stage, r, dry)
        if ok:
            stats["submitted"] += 1
            per_pass[0] -= 1
        elif denied:
            break

    if att_dirty and not dry:
        save_attempts(att)
    stats["gpu_active"] = gpu_active
    stats["cpu_active"] = cpu_active
    stats["total"] = len(rows)
    return stats


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tsv", default=f"{NAVSAFE}/navhard_scenes.tsv")
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--loop", action="store_true")
    ap.add_argument("--interval", type=int, default=60)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--max-scenes", type=int, default=None)
    ap.add_argument("--scenes", default=None, help="comma-separated token subset")
    ap.add_argument("--gpu-cap", type=int, default=int(os.environ.get("GPU_CAP", 28)))
    ap.add_argument("--cpu-cap", type=int, default=int(os.environ.get("CPU_CAP", 10)))
    ap.add_argument("--max-attempts", type=int, default=2)
    ap.add_argument("--max-submit-per-pass", type=int, default=8,
                    help="ramp-rate limit: max NEW job submits per reconcile pass")
    ap.add_argument("--eval-cap", type=int, default=8,
                    help="max concurrent eval jobs (their ~20min 0%-GPU setup drags the util-policy)")
    a = ap.parse_args()

    # tsv may live on the PVC (exec-mode) — pull it locally if not directly readable
    tsv_path = Path(a.tsv)
    if not tsv_path.exists():
        txt = pvc_bash(f"cat {a.tsv}")
        tsv_path = Path("/tmp/navhard_scenes.tsv")
        tsv_path.write_text(txt)
    only = set(a.scenes.split(",")) if a.scenes else None
    rows = read_scenes(tsv_path, only=only, limit=a.max_scenes)
    print(f"[orchestrate] {len(rows)} scenes | pvc={'local' if LOCAL_PVC else 'exec:'+UTIL_POD} "
          f"| gpu_cap={a.gpu_cap} cpu_cap={a.cpu_cap} | dry={a.dry_run}")

    def one():
        s = reconcile(rows, a.gpu_cap, a.cpu_cap, a.max_attempts, a.dry_run,
                      a.max_submit_per_pass, a.eval_cap)
        print(f"[pass] done={s['done_scenes']}/{s['total']} running={s['running']} "
              f"submitted={s['submitted']} gpu={s['gpu_active']}/{a.gpu_cap} "
              f"cpu={s['cpu_active']}/{a.cpu_cap} stuck={s['stuck']}", flush=True)
        return s

    if a.loop:
        while True:
            s = one()
            if s["done_scenes"] == s["total"]:
                print("[orchestrate] ALL SCENES DONE"); break
            time.sleep(a.interval)
    else:
        one()


if __name__ == "__main__":
    main()
