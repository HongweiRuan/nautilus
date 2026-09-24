#!/usr/bin/env python3
"""Overnight driver for Robin's full-280 NavSafe evals (runs on the laptop; kubectl + git).

Phase A: best before/after (job robin-drivor-action-full280-best-pp, already running)
Phase B: section 9 epoch 19 before/after + section 10b GTRS before, started only after phase A is complete and pushed.

For every campaign: a failed worker index (retries exhausted) is re-submitted as its own one-index job; when every job
of the campaign has finished, completeness is checked (280 scored cells per model); missing / excluded cells are
re-run with a fill job on exactly those scenarios (up to 3 rounds); then the results are exported with
export_results.py into robin_bosch_results/<dest> and pushed. Job creation refused by the Nautilus utilization webhook
is retried every loop. Every action is logged as a line starting with "EVENT".
"""
import json, os, re, subprocess, sys, time

NS = "cogrob"
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = "/Users/hongwei/Desktop/avl/nautilus"
RESULTS = f"{REPO}/robin_bosch_results"
OUT = "/avl-west/navsafe_eval/robin_drivor_action_full280/pure_pursuit"
TOKENS = f"{HERE}/full_test_tokens.txt"
STATE = f"{HERE}/orchestrate_state.json"
CM = "robin-drivor-action-navsafe-cfg"
HELPER = "horuan-robin-helper"
SLEEP = 300
CAMPAIGNS = [
    dict(key="best", phase="A", yaml="job-full280-best-pp-r3.yaml", job="robin-drivor-action-full280-best-pp-r3",
         models=["drivor_action_best_before", "drivor_action_best_after"], filt="drivor_action_best_(before|after)",
         dest="best_beforeafter_280", code=None),
    dict(key="sec9", phase="B", yaml="job-full280-sec9ep19-pp.yaml", job="robin-drivor-action-full280-sec9ep19-pp",
         models=["drivor_action_il19_before", "drivor_action_il19_after"], filt="drivor_action_il19_(before|after)",
         dest="sec9epoch19", code="/hugsim-storage/bosch-summer-v2"),
    dict(key="gtrs", phase="B", yaml="job-full280-gtrs10b-pp.yaml", job="robin-drivor-action-full280-gtrs10b-pp",
         models=["drivor_action_gtrs_before"], filt="drivor_action_gtrs_before", dest="10b", code="/hugsim-storage/bosch-summer-v2"),
]
# The four renderer-crash scenarios of the leaderboard (metrics_all/README.md): they die in _get_calibrated_tracks on the
# shipped code and are re-run exactly as the leaderboard did - 5d12ad55 with the real fix (condition-identical), the other
# three with the opt-in replace-scope workaround (reduced asset-replace coverage: reported separately, not silently).
CRASH_ENV = {"5d12ad55fdd858e1": (("NAVSAFE_INSERT_CLASS_PER_SCENE", "1"),),
             "2391f12d7e6a5e7f": (("NAVSAFE_REPLACE_SCOPE", "source"),),
             "442b2cf63c6f570a": (("NAVSAFE_REPLACE_SCOPE", "source"),),
             "9135a6d270475c7f": (("NAVSAFE_REPLACE_SCOPE", "source"),)}
RERUN_HOSTS = ["06", "07", "11", "12", "14"]   # ry-gpu-08 keeps losing GPUs (every best-pp worker there failed twice)


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def sh(cmd, inp=None, check=False, timeout=600):
    r = subprocess.run(cmd, input=inp, capture_output=True, text=True, timeout=timeout, shell=isinstance(cmd, str))
    if check and r.returncode:
        raise RuntimeError(f"{cmd}: {r.stderr.strip()[:400]}")
    return r


def load_state():
    return json.load(open(STATE)) if os.path.exists(STATE) else {}


def save_state(s):
    json.dump(s, open(STATE, "w"), indent=1)


def job_info(name):
    r = sh(["kubectl", "get", "job", "-n", NS, name, "-o", "json"])
    if r.returncode:
        return None
    j = json.loads(r.stdout); st = j.get("status", {})
    conds = {c["type"] for c in st.get("conditions", []) if c.get("status") == "True"}
    failed = [int(x) for part in (st.get("failedIndexes") or "").split(",") if part for x in _rng(part)]
    return dict(done=bool(conds & {"Complete", "Failed"}), failed=failed, active=st.get("active", 0) or 0,
                completions=j["spec"].get("completions"))


def _rng(part):
    a, _, b = part.partition("-")
    return range(int(a), int(b or a) + 1)


def create(yaml_text, name):
    r = sh(["kubectl", "create", "-n", NS, "-f", "-"], inp=yaml_text)
    if r.returncode == 0:
        log(f"EVENT submitted {name}")
        return True
    if "AlreadyExists" in r.stderr:
        return True
    log(f"EVENT submit of {name} refused ({r.stderr.strip()[:200]}); will retry")
    return False


def rightsize(t):
    return t.replace("memory: 115Gi", "memory: 80Gi")   # 40Gi starved IsaacSim env build (cgroup memory.max hit, cells hung to the 45 min timeout)


def hosts(t, hs):
    return re.sub(r"(                - ry-gpu-\d\d\.sdsc\.optiputer\.net\n)+",
                  "".join(f"                - ry-gpu-{h}.sdsc.optiputer.net\n" for h in hs), t)


def rerun_yaml(c, index, n):
    t = rightsize(open(f"{HERE}/{c['yaml']}").read())
    name = f"{c['job']}-w{index}-r{n}"
    t = t.replace(f"name: {c['job']}\n", f"name: {name}\n", 1).replace(f"navsafe-batch: {c['job']}\n", f"navsafe-batch: {name}\n")
    old = """        - name: WORKER_INDEX
          valueFrom:
            fieldRef:
              fieldPath: metadata.annotations['batch.kubernetes.io/job-completion-index']"""
    assert old in t
    t = t.replace(old, f"        - name: WORKER_INDEX\n          value: '{index}'")
    t = re.sub(r"  completions: \d+\n  parallelism: \d+\n", "  completions: 1\n  parallelism: 1\n", t)
    t = re.sub(r"  maxFailedIndexes: \d+", "  maxFailedIndexes: 1", t)
    return name, hosts(t, RERUN_HOSTS)


def fill_yaml(c, tokfile_key, ntok, n, env=(), suffix=""):
    t = rightsize(open(f"{HERE}/{c['yaml']}").read())
    name = f"{c['job']}-fill{n}{suffix}"
    workers = max(1, min(ntok, 6))
    t = t.replace(f"name: {c['job']}\n", f"name: {name}\n", 1).replace(f"navsafe-batch: {c['job']}\n", f"navsafe-batch: {name}\n")
    t = re.sub(r"(        - name: WORKERS\n          value: )'\d+'", rf"\g<1>'{workers}'", t)
    for k, v in env:
        t = t.replace("        - name: WORKERS\n", f"        - name: {k}\n          value: '{v}'\n        - name: WORKERS\n", 1)
    t = re.sub(r"(        - name: EXPECTED_TOKENS\n          value: )'\d+'", rf"\g<1>'{ntok}'", t)
    t = re.sub(r"(        - name: TOKENS_FILE\n          value: )\S+", rf"\g<1>/cfg/{tokfile_key}", t)
    assert f"/cfg/{tokfile_key}" in t, "fill job: TOKENS_FILE not replaced"
    t = re.sub(r"  completions: \d+\n  parallelism: \d+\n", f"  completions: {workers}\n  parallelism: {workers}\n", t)
    t = re.sub(r"  maxFailedIndexes: \d+", f"  maxFailedIndexes: {workers}", t)
    return name, hosts(t, RERUN_HOSTS)


def update_configmap(extra=()):
    files = ["run_worker.sh", "drivor_action.py", "models.tsv", "models_drivor.tsv"] + sorted(
        f for f in os.listdir(HERE) if f.endswith(".txt") and (f.endswith("tokens.txt") or "remaining" in f or f.startswith("fill_")))
    files += [f for f in extra if f not in files]
    args = ["kubectl", "create", "configmap", CM, "-n", NS] + [f"--from-file={f}={HERE}/{f}" for f in files] + ["--dry-run=client", "-o", "yaml"]
    y = sh(args, check=True).stdout
    sh(["kubectl", "apply", "-f", "-"], inp=y, check=True)


FALLBACK_PODS = [("horuan-nexussim", "nexussim-container")]   # long-lived pods of ours that mount /avl-west
HELPER_C = []          # ["-c", container] when the check pod has several containers


def helper():
    """A pod that mounts /avl-west for completeness checks and exports: our small helper pod if the cluster lets us create it,
    else a long-lived pod of ours (FALLBACK_PODS), else any running pod of our own NavSafe jobs (creation of new pods/jobs can
    be refused by the utilization webhook; pods made by a job's controller are not). Returns the pod name or raises."""
    global HELPER, HELPER_C
    HELPER_C = []
    ok = sh(["kubectl", "get", "pod", "-n", NS, "horuan-robin-helper"]).returncode == 0
    if not ok:
        ok = sh(["kubectl", "apply", "-f", f"{HERE}/helper_pod.yaml"]).returncode == 0
    if ok and sh(["kubectl", "wait", "-n", NS, "--for=condition=Ready", "pod/horuan-robin-helper", "--timeout=600s"], timeout=700).returncode == 0:
        HELPER = "horuan-robin-helper"
    else:
        HELPER = None
        for pod, ctr in FALLBACK_PODS:
            r = sh(["kubectl", "get", "pod", "-n", NS, pod, "-o", "jsonpath={.status.phase}"])
            if r.returncode == 0 and r.stdout.strip() == "Running":
                HELPER, HELPER_C = pod, ["-c", ctr]
                break
        if HELPER is None:
            r = sh(["kubectl", "get", "pods", "-n", NS, "--no-headers", "-o", "custom-columns=N:.metadata.name,S:.status.phase"])
            run = [l.split()[0] for l in r.stdout.splitlines() if l.split()[1:] == ["Running"] and l.startswith("robin-drivor-action-")]
            if not run:
                raise RuntimeError("no pod available for checks (helper refused, none of our pods running)")
            HELPER = run[0]
    sh(["kubectl", "cp", *HELPER_C, f"{HERE}/export_results.py", f"{NS}/{HELPER}:/tmp/export_results.py"], check=True)
    sh(["kubectl", "cp", *HELPER_C, TOKENS, f"{NS}/{HELPER}:/tmp/full_test_tokens.txt"], check=True)
    log(f"using pod {HELPER} for checks")
    return HELPER


def drop_helper():
    if HELPER == "horuan-robin-helper":
        sh(["kubectl", "delete", "pod", "-n", NS, HELPER, "--wait=false"])


def missing_tokens(c):
    """Scenarios where some model of the campaign has no scored cell (a log with DONE and status scored)."""
    code = f"""
import json,os,re
toks=[l.split()[0] for l in open('/tmp/full_test_tokens.txt') if l.strip()]
miss=[]
for t in toks:
    for m in {c['models']!r}:
        L='{OUT}/'+m+'/seed0/'+t+'.log'; J='{OUT}/'+m+'/seed0/'+t+'/navsafe_metrics.json'
        ok=os.path.exists(L) and os.path.exists(J) and re.search(r'^\\[eval_py123d\\] DONE\\.', open(L,errors='ignore').read(), re.M) and json.load(open(J)).get('status')=='scored'
        if not ok: miss.append(t); break
print(json.dumps(miss))
"""
    r = sh(["kubectl", "exec", "-n", NS, *HELPER_C, HELPER, "--", "python3", "-c", code], check=True, timeout=1800)
    return json.loads(r.stdout.strip().splitlines()[-1])


def export_and_push(c, note):
    dest = f"{RESULTS}/{c['dest']}"
    remote = f"/tmp/export_{c['key']}"
    sh(["kubectl", "exec", "-n", NS, *HELPER_C, HELPER, "--", "bash", "-c", f"rm -rf {remote} && python3 /tmp/export_results.py {OUT} /tmp/full_test_tokens.txt {remote} {' '.join(c['models'])} && tar -czf {remote}.tgz -C {remote} ."],
       check=True, timeout=1800)
    sh(["kubectl", "cp", *HELPER_C, f"{NS}/{HELPER}:{remote}.tgz", f"/tmp/export_{c['key']}.tgz"], check=True, timeout=1800)
    sh(f"rm -rf '{dest}' && mkdir -p '{dest}' && tar -xzf /tmp/export_{c['key']}.tgz -C '{dest}'", check=True)
    open(f"{dest}/README.md", "w").write(
        f"# {c['dest']}\n\nRobin bosch-summer `drivor_action` on the NavSafe full 280-scenario set, pure-pursuit controller, seed 0, "
        f"NexusSim 649ddde, leaderboard scenario edits kept (`--recipe-dir benchmark`), no injected hazards.\n\n"
        f"Models: {', '.join('`' + m + '`' for m in c['models'])}. Raw outputs: `{OUT}/<model>/seed0/`. {note}\n\n"
        "See `summary.md` for means and the per-scenario table, `table.tsv` for every sub-metric, `<model>/<token>.json` for each cell.\n")
    paths = [f"robin_bosch_results/{c['dest']}"] + [f"robin_bosch/navsafe/{f}" for f in os.listdir(HERE)
             if os.path.isfile(f"{HERE}/{f}") and f.endswith((".py", ".sh", ".yaml", ".tsv", ".txt", ".md")) and not f.startswith("orchestrate_")]
    sh(["git", "-C", REPO, "add", "--"] + paths, check=True)
    msg = (f"Robin bosch results: {c['dest']} (NavSafe full 280, pure pursuit, seed 0)\n\n{note}\n\n"
           "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>\n"
           "Claude-Session: https://claude.ai/code/session_01Q13xaPK7t7RunavB5NeHPX")
    r = sh(["git", "-C", REPO, "commit", "-m", msg])
    if r.returncode and "nothing to commit" not in r.stdout + r.stderr:
        raise RuntimeError(r.stdout + r.stderr)
    for i in range(5):
        r = sh(["git", "-C", REPO, "push", "origin", "HEAD"], timeout=300)
        if r.returncode == 0:
            log(f"EVENT pushed {c['dest']}")
            return
        sh(["git", "-C", REPO, "pull", "--rebase", "origin", "main"], timeout=300)
        time.sleep(30)
    raise RuntimeError("git push failed: " + r.stderr[:400])


def step(c, s):
    """Advance one campaign; returns True when it is exported and pushed."""
    cs = s.setdefault(c["key"], {"started": c["phase"] == "A", "reruns": {}, "fills": 0, "jobs": [c["job"]], "pushed": False})
    if cs["pushed"]:
        return True
    if not cs["started"]:
        name = c["job"]
        if create(open(f"{HERE}/{c['yaml']}").read(), name):
            cs["started"] = True
        return False
    base = job_info(c["job"])
    if base is None:
        log(f"EVENT {c['job']} not found")
        return False
    # re-submit worker indexes that exhausted their retries
    for idx in base["failed"]:
        n = cs["reruns"].get(str(idx), 0)
        rname = f"{c['job']}-w{idx}-r{n}" if n else None
        prev = job_info(rname) if rname else None
        need = n == 0 or (prev is not None and prev["done"] and prev["failed"])
        if need and n < 3:
            name, y = rerun_yaml(c, idx, n + 1)
            if create(y, name):
                cs["reruns"][str(idx)] = n + 1
                cs["jobs"].append(name)
    infos = [job_info(j) for j in cs["jobs"]]
    if not all(i and i["done"] for i in infos):
        return False
    # every job of the campaign has finished: completeness
    helper()
    miss = missing_tokens(c)
    log(f"EVENT {c['key']}: all jobs finished; scenarios with a missing/unscored cell: {len(miss)}")
    if miss and cs["fills"] < 3:
        cs["fills"] += 1
        groups = {}
        for t in miss:
            groups.setdefault(CRASH_ENV.get(t, ()), []).append(t)
        made = []
        for gi, (env, toks) in enumerate(sorted(groups.items())):
            suffix = "" if not env else f"-crash{gi}"
            key = f"fill_{c['key']}_{cs['fills']}{suffix}.txt"
            open(f"{HERE}/{key}", "w").write("\n".join(toks) + "\n")
            made.append((key, len(toks), env, suffix))
            if env:
                cs.setdefault("crash_env", {}).update({t: [list(e) for e in env] for t in toks})
        update_configmap([m[0] for m in made])
        for key, ntok, env, suffix in made:
            name, y = fill_yaml(c, key, ntok, cs["fills"], env, suffix)
            if create(y, name):
                cs["jobs"].append(name)
        drop_helper()
        return False
    note = "All 280 scenarios scored for every model." if not miss else f"{len(miss)} scenario(s) still missing after 3 fill rounds: {', '.join(miss)}."
    ce = cs.get("crash_env") or {}
    if ce:
        note += (" Renderer-crash scenarios re-run as on the leaderboard (metrics_all/README.md): "
                 + "; ".join(f"{t} with {' '.join('='.join(e) for e in env)}" for t, env in sorted(ce.items()))
                 + ". NAVSAFE_INSERT_CLASS_PER_SCENE=1 is a real fix (same conditions as the rest); NAVSAFE_REPLACE_SCOPE=source reduces"
                 " asset-replace coverage, so those cells are not condition-identical - report them separately.")
    export_and_push(c, note)
    drop_helper()
    cs["pushed"] = True
    log(f"EVENT {c['key']} DONE: {note}")
    return True


def main():
    s = load_state()
    log("EVENT orchestrator started")
    while True:
        try:
            a_done = step(CAMPAIGNS[0], s)
            if a_done:
                done_b = [step(c, s) for c in CAMPAIGNS[1:]]
                if all(done_b):
                    save_state(s)
                    log("EVENT ALL DONE")
                    return
        except Exception as e:  # keep going; the next loop retries
            log(f"EVENT error: {type(e).__name__}: {str(e)[:500]}")
        save_state(s)
        time.sleep(SLEEP)


if __name__ == "__main__":
    main()
