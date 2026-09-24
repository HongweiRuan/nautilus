"""Collect one NavSafe campaign's results into a self-contained folder (runs in any pod that mounts /avl-west, stdlib only).

  python3 export_results.py OUTROOT TOKENS_FILE DEST MODEL [MODEL ...]

DEST/<model>/<token>.json   the cell's navsafe_metrics.json (scored or excluded, as written by the evaluator)
DEST/table.tsv              one row per token x model: driving score, route completion, termination, penalty channels,
                            and the EPDMS sub-metrics parsed from the cell log's DONE line
DEST/summary.md             per-model means, completeness, and a per-scenario driving-score table
"""
import collections, json, os, re, shutil, statistics as st, sys

EPDMS = ["route_completion", "epdms", "no_at_fault_collisions", "drivable_area_compliance", "driving_direction_compliance",
         "traffic_light_compliance", "time_to_collision_within_bound", "lane_keeping", "history_comfort", "extended_comfort",
         "ego_progress", "collision_count", "avg_speed"]
COLS = ["status", "DS", "success", "RC_pct", "penalty", "termination", "term_frame", "detail", "frames", "warmup", "off_route_pct",
        "coll_vehicle", "coll_ped", "coll_layout", "red_light", "comfort"] + EPDMS


def cell(outroot, model, tok):
    d = f"{outroot}/{model}/seed0/{tok}"; j = f"{d}/navsafe_metrics.json"; log = f"{d}.log"
    if not os.path.exists(j):
        return None
    m = json.load(open(j))
    b = m.get("driving_score_breakdown") or {}
    ch = {c["channel"]: c for c in b.get("channels", [])}
    t = m.get("termination") or {}
    r = dict(status=m.get("status"), DS=(m.get("metrics") or {}).get("driving_score"),
             success=int(bool((m.get("metrics") or {}).get("success"))), comfort=(m.get("metrics") or {}).get("comfort"),
             RC_pct=b.get("route_completion_pct"), penalty=b.get("penalty"), termination=t.get("reason"), term_frame=t.get("frame"),
             detail=(t.get("detail") or "").replace("\t", " "), frames=(m.get("frames") or {}).get("total"),
             warmup=(m.get("frames") or {}).get("warmup_excluded"),
             off_route_pct=(ch.get("outside_route_lanes") or {}).get("pct"),
             coll_vehicle=(ch.get("collisions_vehicle") or {}).get("count"), coll_ped=(ch.get("collisions_pedestrian") or {}).get("count"),
             coll_layout=(ch.get("collisions_layout") or {}).get("count"), red_light=(ch.get("red_light") or {}).get("count"))
    if os.path.exists(log):
        s = open(log, errors="ignore").read()
        mm = re.search(r"\[eval_py123d\] DONE\. results=.*?'metrics': \{(.*?)\}", s)
        if mm:
            for k in EPDMS:
                v = re.search(r"'" + k + r"': ([-\d.eE]+)", mm.group(1))
                r[k] = round(float(v.group(1)), 4) if v else None
    return r, j


def main(outroot, tokens_file, dest, models):
    toks = [l.split()[0] for l in open(tokens_file) if l.strip() and not l.startswith("#")]
    os.makedirs(dest, exist_ok=True)
    res = collections.defaultdict(dict)
    with open(f"{dest}/table.tsv", "w") as fh:
        fh.write("\t".join(["token", "model"] + COLS) + "\n")
        for t in toks:
            for m in models:
                c = cell(outroot, m, t)
                if not c:
                    continue
                r, j = c; res[m][t] = r
                os.makedirs(f"{dest}/{m}", exist_ok=True); shutil.copy(j, f"{dest}/{m}/{t}.json")
                fh.write("\t".join([t, m] + ["" if r.get(k) is None else str(r.get(k)) for k in COLS]) + "\n")
    L = [f"# NavSafe results: {', '.join(models)}", "",
         f"Source: `{outroot}` (seed 0). {len(toks)} scenarios. Per-cell metrics: `<model>/<token>.json`; all sub-metrics: `table.tsv`.", "",
         "## Mean over scored scenarios", "", "| model | scored | excluded | missing | DS | success % | RC % | DAC | TTC | EP | EPDMS | goal / collision / off-road |",
         "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for m in models:
        sc = [r for r in res[m].values() if r["status"] == "scored"]
        ex = sum(1 for r in res[m].values() if r["status"] != "scored"); miss = len(toks) - len(res[m])
        f = lambda k: (f"{st.mean([r[k] for r in sc if r.get(k) is not None]):.3f}" if any(r.get(k) is not None for r in sc) else "-")
        term = collections.Counter(r["termination"] for r in sc)
        L.append(f"| {m} | {len(sc)} | {ex} | {miss} | {st.mean(r['DS'] for r in sc):.2f} | {100*st.mean(r['success'] for r in sc):.1f} | "
                 f"{st.mean(r['RC_pct'] for r in sc):.1f} | {f('drivable_area_compliance')} | {f('time_to_collision_within_bound')} | "
                 f"{f('ego_progress')} | {f('epdms')} | {term.get('goal_reached', 0)} / "
                 f"{term.get('contact_at_fault', 0) + term.get('contact_not_at_fault', 0)} / {term.get('off_drivable', 0)} |" if sc else f"| {m} | 0 | {ex} | {miss} | - |")
    suf = {"goal_reached": "", "off_drivable": "o", "contact_at_fault": "c", "contact_not_at_fault": "n"}
    L += ["", "## Driving score per scenario", "", "suffix: o = off drivable, c = at-fault contact, n = not-at-fault contact, ? = other; x = excluded (infra failure); · = missing", "",
          "| token | " + " | ".join(models) + " |", "|---|" + "---|" * len(models)]
    for t in toks:
        row = []
        for m in models:
            r = res[m].get(t)
            row.append("·" if not r else ("x" if r["status"] != "scored" else f"{r['DS']:.0f}{suf.get(r['termination'], '?')}"))
        L.append(f"| {t} | " + " | ".join(row) + " |")
    open(f"{dest}/summary.md", "w").write("\n".join(L) + "\n")
    print("exported", {m: len(res[m]) for m in models})


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:])
