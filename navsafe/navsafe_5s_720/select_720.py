#!/usr/bin/env python3
"""
select_720.py — pick 10 nuPlan scenarios per scenario_type (720 total) for the
navsafe 5s pipeline: navhard first, backfill from navtest, resolve each to its
20s (log, t0, t1) window, and flag types that even all of navtest can't fill.

RUN ON A POD that mounts /avl-west and /hugsim-storage (e.g. horuan-nexussim):
    /root/nexussim-venv/bin/python /tmp/select_720.py
Needs only the stdlib (sqlite3, pickle, glob) + PyYAML if available (else JSON).

WHAT MAPS A TOKEN TO A SCENARIO TYPE
  There is NO scenario_type field in the navsim pkls. The only source is the
  nuPlan DB `scenario_tag` table: (type, lidar_pc_token). The navsim token IS the
  hex(lidar_pc_token) (validated: 00c1e4eb4a045f20 -> on_intersection,
  on_traffic_light_intersection, traversing_intersection,
  traversing_traffic_light_intersection). A token carries MULTIPLE types.

WINDOW (t0,t1): navsim test pkls, 4 history + 40 future frames = the same ~20s
  window the bridgesim converter used (identical logic to build_scenes.py).

SELECTION POLICY  (tweak the constants below)
  pool      = navhard (421 sd_ tokens)  ∪  navtest (navtest.yaml tokens)
  per type  = navhard candidates first, then navtest, stable by token order
  PREFER_UNIQUE=True -> each token assigned to ONE type only (greedy, rarest type
    first) so the 720 are DISTINCT scenarios. Set False to let a token serve
    several types (fewer unique conversions; per-type lists may overlap).
  A type that can't reach N_PER_TYPE even after navtest -> short_types.txt
  (needs self-generated scenes LATER — this task does not generate them).

OUTPUTS (OUTDIR, default the script's own dir)
  scenes_720.yaml  type -> [ {token, log, t0, t1, source} ]   (traceable, grouped)
  scenes_720.tsv   token\tlog\tt0\tt1\ttype\tsource            (DISTINCT tokens; fed to submit_stage.sh)
  short_types.txt  type\thave\tneed                            (types < N across all navtest)
"""
import os, sys, glob, pickle, sqlite3, json
from collections import defaultdict

# ---- config -----------------------------------------------------------------
N_PER_TYPE     = 10
PREFER_UNIQUE  = True
BRIDGE         = "/hugsim-storage/bridgesim_converter_navhard"          # sd_<token> dirs (navhard 421)
NAVSIM_PKLS    = "/avl-west/navsim/test_navsim_logs/test"               # 2Hz frames (token, log, timestamp)
NAVTEST_YAML   = "/hugsim-storage/MetaBench_fresh/navsim/navsim/planning/script/config/common/train_test_split/scene_filter/navtest.yaml"
NUPLAN_SPLITS  = "/avl-west/nuplan/nuplan-v1.1/splits"                  # */<log>.db (scenario_tag)
OUTDIR         = os.environ.get("OUTDIR", os.path.dirname(os.path.abspath(__file__)))
NUM_HIST, FUT_EXTRACT = 4, 40                                           # navhard_two_stage.yaml + --num-future-frames-extract
HIST_OFF, WIN = NUM_HIST - 1, NUM_HIST + FUT_EXTRACT                    # token at index 3; 44-frame window
# -----------------------------------------------------------------------------


def load_navhard_tokens():
    return {d[3:] for d in os.listdir(BRIDGE) if d.startswith("sd_")}


def load_navtest_tokens():
    """Parse the `tokens:` list out of navtest.yaml without importing hydra/yaml."""
    toks, in_tokens = set(), False
    for line in open(NAVTEST_YAML):
        s = line.strip()
        if s.startswith("tokens:"):
            in_tokens = True; continue
        if in_tokens:
            if s.startswith("- "):
                toks.add(s[2:].strip().strip("'\""))
            elif s and not s.startswith("#") and not s.startswith("- "):
                break   # next top-level key
    return toks


def resolve_windows(tokens):
    """token -> (log, t0, t1) by scanning the navsim pkls (build_scenes.py logic)."""
    resolved, edge = {}, []
    want = set(tokens)
    for pkl in sorted(glob.glob(NAVSIM_PKLS + "/*.pkl")):
        frames = sorted(pickle.load(open(pkl, "rb")), key=lambda f: f["timestamp"])
        idx = {f["token"]: i for i, f in enumerate(frames)}
        for tok in want & idx.keys():
            i_cur = idx[tok]; s = i_cur - HIST_OFF; e = s + WIN - 1
            if s < 0 or e >= len(frames):
                edge.append(tok); continue
            resolved[tok] = (frames[i_cur]["log_name"],
                             int(frames[s]["timestamp"]), int(frames[e]["timestamp"]))
    return resolved, edge


def token_types(tokens_by_log):
    """{token: set(types)} from each log's nuPlan DB scenario_tag table."""
    out = defaultdict(set)
    for log, toks in tokens_by_log.items():
        dbs = glob.glob(f"{NUPLAN_SPLITS}/*/{log}.db")
        if not dbs:
            print(f"  [warn] no DB for log {log} ({len(toks)} tokens)", flush=True); continue
        con = sqlite3.connect(dbs[0])
        rows = con.execute("select lower(hex(lidar_pc_token)), type from scenario_tag").fetchall()
        con.close()
        tset = set(toks)
        for tok_hex, typ in rows:
            if tok_hex in tset:
                out[tok_hex].add(typ)
    return out


def main():
    navhard = load_navhard_tokens()
    navtest = load_navtest_tokens()
    print(f"navhard tokens: {len(navhard)}   navtest tokens: {len(navtest)}", flush=True)

    pool = navhard | navtest
    windows, edge = resolve_windows(pool)
    print(f"windows resolved: {len(windows)}/{len(pool)}  (edge-truncated {len(edge)})", flush=True)

    # group resolved tokens by log so each DB is opened once
    tokens_by_log = defaultdict(list)
    for tok, (log, _, _) in windows.items():
        tokens_by_log[log].append(tok)
    types = token_types(tokens_by_log)
    print(f"tokens with >=1 scenario_type: {len(types)}", flush=True)

    # type -> candidate tokens, navhard first then navtest, stable by token
    by_type = defaultdict(lambda: {"navhard": [], "navtest": []})
    for tok in sorted(windows):
        for typ in types.get(tok, ()):
            by_type[typ]["navhard" if tok in navhard else "navtest"].append(tok)

    # rarest type first so multi-tag tokens don't starve small types (matters when PREFER_UNIQUE)
    order = sorted(by_type, key=lambda t: len(by_type[t]["navhard"]) + len(by_type[t]["navtest"]))

    used, selection, short = set(), {}, []
    for typ in order:
        picked = []
        for src in ("navhard", "navtest"):
            for tok in by_type[typ][src]:
                if len(picked) >= N_PER_TYPE:
                    break
                if PREFER_UNIQUE and tok in used:
                    continue
                picked.append((tok, src)); used.add(tok)
        selection[typ] = picked
        have = len(picked)
        total_avail = len(set(by_type[typ]["navhard"]) | set(by_type[typ]["navtest"]))
        if have < N_PER_TYPE:
            short.append((typ, have, N_PER_TYPE, total_avail))

    n_types = len(selection)
    n_sel = sum(len(v) for v in selection.values())
    n_uniq = len({t for v in selection.values() for t, _ in v})
    print(f"\ntypes: {n_types}   selected rows: {n_sel}   distinct scenarios: {n_uniq}", flush=True)
    print(f"short types (<{N_PER_TYPE}): {len(short)}", flush=True)

    os.makedirs(OUTDIR, exist_ok=True)
    # grouped yaml (hand-written so no PyYAML dependency; valid YAML)
    yml = os.path.join(OUTDIR, "scenes_720.yaml")
    with open(yml, "w") as fh:
        fh.write(f"# {n_types} types x up to {N_PER_TYPE}  ->  {n_sel} rows, {n_uniq} distinct scenarios\n")
        fh.write(f"# PREFER_UNIQUE={PREFER_UNIQUE}  navhard-first  window=4hist+40fut(~20s)\n")
        for typ in sorted(selection):
            fh.write(f"{typ}:\n")
            for tok, src in selection[typ]:
                log, t0, t1 = windows[tok]
                fh.write(f"  - {{token: {tok}, log: {log}, t0: {t0}, t1: {t1}, source: {src}}}\n")
    # flat tsv of DISTINCT tokens (the actual conversion set; submit_stage.sh reads this)
    tsv = os.path.join(OUTDIR, "scenes_720.tsv")
    seen = set()
    with open(tsv, "w") as fh:
        for typ in sorted(selection):
            for tok, src in selection[typ]:
                if tok in seen:
                    continue
                seen.add(tok)
                log, t0, t1 = windows[tok]
                fh.write(f"{tok}\t{log}\t{t0}\t{t1}\t{typ}\t{src}\n")
    # short types (need self-generated scenes later)
    st = os.path.join(OUTDIR, "short_types.txt")
    with open(st, "w") as fh:
        fh.write("# type\thave\tneed\tavailable_in_navhard+navtest\n")
        for typ, have, need, avail in sorted(short):
            fh.write(f"{typ}\t{have}\t{need}\t{avail}\n")

    print(f"\nwrote:\n  {yml}\n  {tsv}  ({len(seen)} distinct tokens)\n  {st}  ({len(short)} short types)", flush=True)
    if short:
        print("\nSHORT TYPES (all-navtest still < N — flag in index.html, generate later):", flush=True)
        for typ, have, need, avail in sorted(short):
            print(f"  {typ}: have {have}/{need} (only {avail} exist)", flush=True)


if __name__ == "__main__":
    main()
