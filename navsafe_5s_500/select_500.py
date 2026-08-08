#!/usr/bin/env python3
"""
select_500.py — pick the FINAL 500 scenarios for navsafe, budgeted by TAXONOMY LEAF
(28 leaves), not by scenario type.

RUN ON A POD that mounts /avl-west + /hugsim-storage (e.g. horuan-nexussim):
    OUTDIR=/tmp PRIOR_TSV=/tmp/scenes_720.tsv /root/nexussim-venv/bin/python /tmp/select_500.py
Stdlib only.

THE TARGET
  28 taxonomy leaves, every leaf >= MIN_PER_LEAF (10) scenarios, 500 scenarios total.
  7 leaves have no nuPlan scenario_type at all (C-9 C-10 V-10 V-11 R-3 R-4 I-3) and a
  few more are too scarce to reach 10 — those shortfalls must be GENERATED later. We
  reserve MIN_PER_LEAF for each unit of shortfall, and mine
      500 - (total shortfall reserved for generation)
  from the logs, giving the well-populated leaves more than 10 each.

ONE POOL FOR ALL THREE SOURCES
  navhard is a subset of navtest, and navtest's keyframes all live in the 147 test-split
  logs that ship real dense sensor blobs. So "navhard + navtest + test split" is exactly
  "every tagged frame in those 147 logs" — one scan covers all three. Frames the older
  navtest-based selection already picked are preferred (see REUSE).

REUSE — this is why the selection is not just re-run from scratch
  /avl-west/navsafe-5s-720 already holds finished ncore (and aux) for the 441-scenario
  navtest selection. A scenario carried over keeps its EXACT token/log/t0, so its four
  clip ids are unchanged and its artifacts can simply be moved to the new tree
  (see migrate_artifacts.sh). Selection therefore prefers, in order:
      1. scenarios already converted under navsafe-5s-720
      2. any other candidate frame in the 147 logs
  Nothing is re-reconstructed that already exists.

WINDOW
  Carried-over scenarios keep their original t0 (their clips are already built).
  New ones use t0 = tagged frame, t1 = t0 + 20 s. Either way the pipeline cuts
  four exact 5 s clips from t0, so the two conventions produce identical clip geometry.

OUTPUTS (OUTDIR)
  scenes_500.tsv      token\tlog\tt0\tt1\ttypes\tleaves\tsource   (the conversion set)
  scenes_500.yaml     leaf -> [ scenarios ]                        (traceable)
  leaf_coverage.txt   per leaf: mined / to-generate / total
  reuse_manifest.txt  clip ids that already exist and where they come from
"""
import os, sys, glob, json, sqlite3
from collections import defaultdict

# ---- config -----------------------------------------------------------------
TOTAL          = 500
MIN_PER_LEAF   = 10
WINDOW_US      = 20_000_000
MAX_PER_LOG    = 6                 # per leaf, keep a leaf's scenarios spread over logs
TEST_SPLIT     = "/avl-west/nuplan/nuplan-v1.1/splits/test"
SENSOR_BLOBS   = "/avl-west/nuplan/nuplan-v1.1/sensor_blobs"
PRIOR_TSV      = os.environ.get("PRIOR_TSV", "/tmp/scenes_720.tsv")
PRIOR_ROOT     = "/avl-west/navsafe-5s-720"
CACHE          = os.environ.get("SCAN_CACHE", "/tmp/scan_147.json")
OUTDIR         = os.environ.get("OUTDIR", os.path.dirname(os.path.abspath(__file__)))

# 28 taxonomy leaves — verbatim from navsafe-vail.github.io/index.html (LEAVES).
LEAVES = [
 ("C-1","Rear-End",["stopping_with_lead","behind_long_vehicle","near_long_vehicle","stopping_at_traffic_light_with_lead","stopping_at_stop_sign_with_lead","stationary_at_traffic_light_with_lead","accelerating_at_traffic_light_with_lead"]),
 ("C-2","Angle / T-Bone",["crossed_by_vehicle","starting_protected_cross_turn"]),
 ("C-3","Sideswipe",["changing_lane_with_lead","changing_lane_with_trail","near_high_speed_vehicle"]),
 ("C-4","Multi-Vehicle",["near_multiple_vehicles"]),
 ("C-5","Intersection",["traversing_intersection","on_intersection","starting_left_turn","starting_right_turn","starting_low_speed_turn","starting_high_speed_turn","starting_protected_noncross_turn"]),
 ("C-6","Roadway Departure",["traversing_pickup_dropoff","on_pickup_dropoff"]),
 ("C-7","Head-On",["traversing_narrow_lane"]),
 ("C-8","Backing",["on_carpark"]),
 ("C-9","Single-Vehicle",[]),
 ("C-10","Wrong-Way (crash)",[]),
 ("V-1","Red-Light / Stop-Sign",["traversing_traffic_light_intersection","on_traffic_light_intersection","on_stopline_traffic_light","starting_straight_traffic_light_intersection_traversal","stopping_at_traffic_light_without_lead","stationary_at_traffic_light_without_lead","accelerating_at_traffic_light","accelerating_at_traffic_light_without_lead","on_stopline_stop_sign","starting_straight_stop_sign_intersection_traversal","stopping_at_stop_sign_without_lead","stopping_at_stop_sign_no_crosswalk","accelerating_at_stop_sign","accelerating_at_stop_sign_no_crosswalk"]),
 ("V-2","Failure to Yield",["starting_unprotected_cross_turn","starting_unprotected_noncross_turn","on_all_way_stop_intersection"]),
 ("V-3","Unsafe Lane Change",["changing_lane","changing_lane_to_left","changing_lane_to_right"]),
 ("V-4","Reckless / Aggressive",["high_lateral_acceleration","high_magnitude_jerk"]),
 ("V-5","Speeding",["high_magnitude_speed","medium_magnitude_speed","low_magnitude_speed"]),
 ("V-6","Tailgating",["following_lane_with_lead","following_lane_with_slow_lead"]),
 ("V-7","Failure to Maintain Lane",["following_lane_without_lead"]),
 ("V-8","Illegal U-Turn / Turn",["starting_u_turn"]),
 ("V-9","Blocking Intersection",["stationary","stationary_in_traffic"]),
 ("V-10","Unsafe Merge / Entry",[]),
 ("V-11","Driving Wrong Way",[]),
 ("R-1","Pedestrian-Involved",["waiting_for_pedestrian_to_cross","near_pedestrian_on_crosswalk","near_pedestrian_on_crosswalk_with_ego","near_multiple_pedestrians","behind_pedestrian_on_driveable","behind_pedestrian_on_pickup_dropoff","near_pedestrian_at_pickup_dropoff","traversing_crosswalk","on_stopline_crosswalk","stopping_at_crosswalk","stationary_at_crosswalk","accelerating_at_crosswalk"]),
 ("R-2","Bicycle-Involved",["behind_bike","crossed_by_bike","near_multiple_bikes"]),
 ("R-3","Micromobility",[]),
 ("R-4","Animal-Involved",[]),
 ("I-1","Obstruction / Hazard",["near_trafficcone_on_driveable","near_barrier_on_driveable"]),
 ("I-2","Work-Zone",["near_construction_zone_sign"]),
 ("I-3","General Incident",[]),
]
LEAF_NAME = {i: n for i, n, _ in LEAVES}
LEAF_OF_TYPE = {t: i for i, _, ts in LEAVES for t in ts}
ALL_LEAVES = [i for i, _, _ in LEAVES]
# -----------------------------------------------------------------------------


def blob_backed_logs():
    test = {os.path.basename(p)[:-3] for p in glob.glob(f"{TEST_SPLIT}/*.db")}
    blobs = set(os.listdir(SENSOR_BLOBS)) if os.path.isdir(SENSOR_BLOBS) else set()
    return sorted(test & blobs)


def scan_all(logs):
    """[(log, token, ts, [types])] for every tagged frame; cached (the scan is the slow part)."""
    if os.path.exists(CACHE):
        d = json.load(open(CACHE))
        print(f"loaded scan cache {CACHE}: {len(d['rows'])} frames, {len(d['ends'])} logs", flush=True)
        return d["rows"], d["ends"]
    rows, ends = [], {}
    for i, log in enumerate(logs):
        try:
            con = sqlite3.connect(f"{TEST_SPLIT}/{log}.db")
            ts_by_tok = {t.lower(): int(ts) for t, ts in
                         con.execute("select lower(hex(token)), timestamp from lidar_pc")}
            if not ts_by_tok:
                con.close(); continue
            ends[log] = max(ts_by_tok.values())
            tags = defaultdict(set)
            for typ, tok in con.execute("select type, lower(hex(lidar_pc_token)) from scenario_tag"):
                if tok in ts_by_tok:
                    tags[tok].add(typ)
            con.close()
        except Exception as e:
            print(f"  [warn] {log}: {e}", flush=True); continue
        for tok, ts in sorted(((t, ts_by_tok[t]) for t in tags), key=lambda x: x[1]):
            rows.append([log, tok, ts, sorted(tags[tok])])
        if (i + 1) % 25 == 0:
            print(f"  scanned {i+1}/{len(logs)} logs, {len(rows)} tagged frames", flush=True)
    json.dump({"rows": rows, "ends": ends}, open(CACHE, "w"))
    print(f"scanned {len(ends)} logs -> {len(rows)} tagged frames (cached to {CACHE})", flush=True)
    return rows, ends


def load_prior():
    """[(token, log, t0, t1)] from the 441-scenario navtest selection (artifacts exist)."""
    out = []
    if not os.path.exists(PRIOR_TSV):
        print(f"[warn] {PRIOR_TSV} missing — no reuse", flush=True); return out
    for line in open(PRIOR_TSV):
        if line.startswith("#") or not line.strip():
            continue
        f = line.rstrip("\n").split("\t")
        if len(f) >= 4:
            out.append((f[0], f[1], int(f[2]), int(f[3])))
    return out


def main():
    logs = blob_backed_logs()
    print(f"recon-capable logs (real dense sensor blobs): {len(logs)}", flush=True)
    rows, ends = scan_all(logs)

    types_at = {(r[0], r[1]): set(r[3]) for r in rows}
    ts_at = {(r[0], r[1]): r[2] for r in rows}

    def leaves_of(types):
        return {LEAF_OF_TYPE[t] for t in types if t in LEAF_OF_TYPE}

    # ---- per-leaf candidate lists (one pass) + availability upper bound --------
    by_leaf_cands = defaultdict(list)
    for log, tok, ts, tps in rows:
        if ts + WINDOW_US > ends.get(log, 0):
            continue
        for l in leaves_of(tps):
            by_leaf_cands[l].append((log, tok, ts, frozenset(tps)))
    avail = defaultdict(int)
    for leaf in ALL_LEAVES:
        seen = defaultdict(list)
        for log, tok, ts, tps in by_leaf_cands[leaf]:
            if all(ts >= b or ts + WINDOW_US <= a for a, b in seen[log]):
                seen[log].append((ts, ts + WINDOW_US)); avail[leaf] += 1
    print("\nleaf availability (upper bound):", flush=True)
    for leaf in ALL_LEAVES:
        print(f"  {leaf:5s} {LEAF_NAME[leaf][:26]:28s} {avail[leaf]}", flush=True)

    # ---- quota: floor 10 each (or all that exist); shortfall reserved for generation
    floor = {l: min(MIN_PER_LEAF, avail[l]) for l in ALL_LEAVES}
    to_generate = {l: MIN_PER_LEAF - floor[l] for l in ALL_LEAVES}
    gen_total = sum(to_generate.values())
    mine_budget = TOTAL - gen_total
    print(f"\nto generate: {gen_total} ({sum(1 for l in ALL_LEAVES if to_generate[l])} leaves)"
          f"   mine budget (DISTINCT scenarios): {mine_budget}", flush=True)

    # ---- selection: reuse first, then fill ------------------------------------
    taken = defaultdict(list)                 # log -> [(t0,t1)]
    got = defaultdict(int)                    # leaf -> count
    per_log_leaf = defaultdict(lambda: defaultdict(int))
    chosen = []                               # (token, log, t0, t1, types, leaves, source)
    picked_keys = set()

    def fits(log, t0):
        t1 = t0 + WINDOW_US
        if t1 > ends.get(log, 0):
            return False
        return all(t1 <= a or t0 >= b for a, b in taken[log])

    def take(tok, log, t0, t1, tps, source):
        """credit EVERY leaf this scenario carries (a scenario legitimately belongs to
        several leaves); MAX_PER_LOG still keeps one drive from dominating a leaf."""
        lv = {l for l in leaves_of(tps) if per_log_leaf[log][l] < MAX_PER_LOG}
        if not lv:
            return False
        taken[log].append((t0, t0 + WINDOW_US))
        for l in lv:
            got[l] += 1; per_log_leaf[log][l] += 1
        chosen.append((tok, log, t0, t1, sorted(tps), sorted(lv), source))
        picked_keys.add((log, tok))
        return True

    # reuse pool, indexed by leaf: scenarios that already have artifacts on CephFS
    prior = load_prior()
    prior_by_key = {(log, tok): (tok, log, t0, t1) for tok, log, t0, t1 in prior}
    reuse_by_leaf = defaultdict(list)
    for tok, log, t0, t1 in prior:
        tps = types_at.get((log, tok), set())
        for l in leaves_of(tps):
            reuse_by_leaf[l].append((log, tok, t0, t1, frozenset(tps)))

    # per-(leaf,pool) cursor: an entry we skip can never become usable again
    # (picked_keys, taken[] and per_log_leaf[] only grow), so never rescan from 0.
    cur = defaultdict(int)

    def try_fill(leaf, reuse_only=False):
        """add ONE unused scenario that serves `leaf`; reuse first (its recon exists)."""
        pools = ((0, reuse_by_leaf[leaf]),) if reuse_only else (
                 (0, reuse_by_leaf[leaf]), (1, by_leaf_cands[leaf]))
        for pid, pool in pools:
            is_reuse = pid == 0
            i = cur[(leaf, pid)]
            while i < len(pool):
                item = pool[i]; i += 1
                if is_reuse:
                    log, tok, t0, t1, tps = item
                else:
                    log, tok, t0, tps = item; t1 = t0 + WINDOW_US
                if (log, tok) in picked_keys:
                    continue
                if per_log_leaf[log][leaf] >= MAX_PER_LOG or not fits(log, t0):
                    continue                   # permanently unusable (both only tighten)
                if take(tok, log, t0, t1, tps, "reuse-720" if is_reuse else "mined"):
                    cur[(leaf, pid)] = i
                    return True
            cur[(leaf, pid)] = i
        return False

    # 1) floors first — every leaf reaches MIN_PER_LEAF (or all that exist), reuse preferred
    for leaf in sorted(ALL_LEAVES, key=lambda l: avail[l]):
        while got[leaf] < floor[leaf] and len(chosen) < mine_budget:
            if not try_fill(leaf):
                break

    # 2) top up to the DISTINCT-scenario budget, always feeding the thinnest leaf.
    #    Budget is counted in DISTINCT scenarios, not leaf-slots: one scenario usually
    #    credits several leaves, so quota-based counting stops far short of the target.
    #    Pass A drains the already-converted pool before Pass B mines anything new —
    #    every carried-over scenario is ncore+aux work we do not repeat.
    for reuse_only in (True, False):
        while len(chosen) < mine_budget:
            openl = [l for l in ALL_LEAVES if got[l] < avail[l]]
            if not openl:
                break
            progressed = False
            for leaf in sorted(openl, key=lambda l: got[l]):
                if len(chosen) >= mine_budget:
                    break
                if try_fill(leaf, reuse_only=reuse_only):
                    progressed = True
                    break                 # re-sort so the next pick feeds the new thinnest
            if not progressed:
                break
        # cursors must restart for pass B: pass A only advanced the reuse pools
        if reuse_only:
            print(f"  after reuse pass: {len(chosen)} scenarios "
                  f"({sum(1 for c in chosen if c[6] == 'reuse-720')} reused)", flush=True)

    n = len(chosen)
    n_reuse = sum(1 for c in chosen if c[6] == "reuse-720")
    print(f"\nselected {n} scenarios ({n_reuse} reused + {n - n_reuse} newly mined)", flush=True)

    # ---- outputs ---------------------------------------------------------------
    os.makedirs(OUTDIR, exist_ok=True)
    with open(os.path.join(OUTDIR, "scenes_500.tsv"), "w") as fh:
        for tok, log, t0, t1, tps, lv, src in chosen:
            fh.write(f"{tok}\t{log}\t{t0}\t{t1}\t{','.join(tps)}\t{','.join(lv)}\t{src}\n")
    by_leaf = defaultdict(list)
    for c in chosen:
        for l in c[5]:
            by_leaf[l].append(c)
    with open(os.path.join(OUTDIR, "scenes_500.yaml"), "w") as fh:
        fh.write(f"# {n} scenarios ({n_reuse} reused from navsafe-5s-720), 28 taxonomy leaves\n")
        for l in ALL_LEAVES:
            fh.write(f"{l}:  # {LEAF_NAME[l]} — {len(by_leaf[l])} scenarios"
                     f"{', +%d to generate' % to_generate[l] if to_generate[l] else ''}\n")
            for tok, log, t0, t1, tps, lv, src in by_leaf[l]:
                fh.write(f"  - {{token: {tok}, log: {log}, t0: {t0}, t1: {t1}, source: {src}}}\n")
    with open(os.path.join(OUTDIR, "leaf_coverage.txt"), "w") as fh:
        fh.write(f"# leaf\tname\tmined\tto_generate\ttotal\tavailable_in_logs\n")
        for l in ALL_LEAVES:
            fh.write(f"{l}\t{LEAF_NAME[l]}\t{len(by_leaf[l])}\t{to_generate[l]}"
                     f"\t{len(by_leaf[l]) + to_generate[l]}\t{avail[l]}\n")
    with open(os.path.join(OUTDIR, "reuse_manifest.txt"), "w") as fh:
        for tok, log, t0, t1, tps, lv, src in chosen:
            if src == "reuse-720":
                for k in range(1, 5):
                    fh.write(f"{tok}s{k}\t{PRIOR_ROOT}\n")

    print("\nper-leaf result:", flush=True)
    for l in ALL_LEAVES:
        g = to_generate[l]
        print(f"  {l:5s} {LEAF_NAME[l][:26]:28s} mined {len(by_leaf[l]):3d}"
              f"{'  + generate %2d' % g if g else ''}", flush=True)
    print(f"\nTOTAL mined {n} + to-generate {gen_total} = {n + gen_total}", flush=True)


if __name__ == "__main__":
    main()
