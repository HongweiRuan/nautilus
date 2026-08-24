#!/usr/bin/env python3
"""
mine_testsplit.py — mine the nuPlan TEST SPLIT for the scenario types NAVSIM's
navtest doesn't give us, 10 scenarios per type, each a 20 s window that STARTS at
the tagged frame.

RUN ON A POD that mounts /avl-west (e.g. horuan-nexussim):
    OUTDIR=/tmp /root/nexussim-venv/bin/python /tmp/mine_testsplit.py
Stdlib only.

WHY THIS EXISTS
  navtest samples only 2 Hz keyframes out of the test-split logs, so it covers just
  55 of the 73 nuPlan scenario types. The DBs tag ALL 20 Hz frames, so mining the
  full `scenario_tag` table recovers types navtest's sampling missed
  (changing_lane, stopping_with_lead, ...).

HARD CONSTRAINT — SENSOR BLOBS
  Recon needs real camera images. Only 147 of the 1349 test-split logs have real
  dense (10 Hz, full-res) blobs under nuplan-v1.1/sensor_blobs/. The other 1202 have
  at best `rendered_sensor_blobs` (same frames, 2 Hz subsample, re-compressed) which
  would give visibly worse 3DGS than the navhard recipe. So mining is RESTRICTED to
  the blob-backed logs — same data quality as every recon we've trained so far.
  Set REQUIRE_REAL_BLOBS=False to lift this (not recommended).

WINDOW
  t0 = timestamp of the tagged 20 Hz frame; t1 = t0 + 20 s exactly. The pipeline
  then cuts it into four exact 5 s clips (s1..s4), so 20 s is a perfect fit.

SELECTION (per type, greedy, most-constrained first)
  - window must fit inside the log (t0 + 20 s <= log end)
  - windows never overlap each other (within a log AND against the already-selected
    navsafe_5s_720 scenarios, if scenes_720.tsv is provided via PRIOR_TSV)
  - MAX_PER_LOG caps how many scenarios one log may contribute to one type, so the
    10 come from several logs instead of 10 slices of one drive
  - a type that can't reach N_PER_TYPE just gets fewer (reported, not an error)

DEFICIT MODE (default)
  Only mines what navsafe_5s_720 is short of: need = N_PER_TYPE - already_have.
  Set MINE_ALL=1 to mine all 73 types to 10 regardless of the navtest set.

OUTPUTS (OUTDIR)
  scenes_testsplit.tsv    token\tlog\tt0\tt1\ttype\tsource     -> fed to submit_stage.sh
  scenes_testsplit.yaml   type -> [ {token, log, t0, t1} ]      (traceable, grouped)
  coverage_report.txt     per type: navtest_have + mined + total, and what's still short
"""
import os, sys, glob, sqlite3
from collections import defaultdict

# ---- config -----------------------------------------------------------------
N_PER_TYPE          = 10
WINDOW_US           = 20_000_000          # exactly 20 s (pipeline cuts 4 x 5 s)
MAX_PER_LOG         = 3                   # per type, keep the 10 spread over logs
MAX_WINDOWS_PER_LOG = 10                  # total windows one log may contribute
REQUIRE_REAL_BLOBS  = True
MINE_ALL            = os.environ.get("MINE_ALL", "0") == "1"
TEST_SPLIT          = "/avl-west/nuplan/nuplan-v1.1/splits/test"
SENSOR_BLOBS        = "/avl-west/nuplan/nuplan-v1.1/sensor_blobs"
PRIOR_TSV           = os.environ.get("PRIOR_TSV", "/tmp/scenes_720.tsv")   # navtest selection (may be absent)
OUTDIR              = os.environ.get("OUTDIR", os.path.dirname(os.path.abspath(__file__)))
# -----------------------------------------------------------------------------


def blob_backed_logs():
    """test-split logs that have REAL dense sensor blobs (the recon-capable set)."""
    test = {os.path.basename(p)[:-3] for p in glob.glob(f"{TEST_SPLIT}/*.db")}
    if not REQUIRE_REAL_BLOBS:
        return sorted(test)
    blobs = set(os.listdir(SENSOR_BLOBS)) if os.path.isdir(SENSOR_BLOBS) else set()
    return sorted(test & blobs)


def load_prior():
    """{type: count} and {log: [(t0,t1)]} already claimed by the navtest selection."""
    have, claimed = defaultdict(int), defaultdict(list)
    if not os.path.exists(PRIOR_TSV):
        print(f"[warn] PRIOR_TSV {PRIOR_TSV} not found -> treating navtest coverage as 0", flush=True)
        return have, claimed
    for line in open(PRIOR_TSV):
        if line.startswith("#") or not line.strip():
            continue
        f = line.rstrip("\n").split("\t")
        if len(f) < 5:
            continue
        tok, log, t0, t1, typ = f[0], f[1], int(f[2]), int(f[3]), f[4]
        have[typ] += 1
        claimed[log].append((t0, t0 + WINDOW_US))
    return have, claimed


def scan_log(log, not_needed=frozenset()):
    """-> (log_end_us, [ (token, ts, frozenset(types)) sorted by ts ])

    A frame usually carries SEVERAL tags, so each candidate start frame keeps its
    whole type set: one 20 s window can legitimately count as a scenario for every
    type tagged on its start frame — same recon, several types filled.

    Thinning is TYPE-AWARE, which matters: thinning purely by time (keep one frame
    per second) silently drops whole rare types, because the rare tag often sits on
    a skipped frame. Instead we keep only frames that carry a still-needed type, then
    thin each distinct type-signature's own timeline to WINDOW_US spacing — two
    windows of the same signature closer than 20 s overlap and are mutually
    exclusive anyway, so this loses nothing.
    """
    db = f"{TEST_SPLIT}/{log}.db"
    try:
        con = sqlite3.connect(db)
        ts_by_tok = {t.lower(): int(ts) for t, ts in
                     con.execute("select lower(hex(token)), timestamp from lidar_pc")}
        if not ts_by_tok:
            con.close(); return 0, []
        end = max(ts_by_tok.values())
        tags = defaultdict(set)
        for typ, tok in con.execute("select type, lower(hex(lidar_pc_token)) from scenario_tag"):
            if tok in ts_by_tok:
                tags[tok].add(typ)
        con.close()
    except Exception as e:
        print(f"  [warn] {log}: {e}", flush=True)
        return 0, []
    cands = sorted(((tok, ts_by_tok[tok], frozenset(t)) for tok, t in tags.items()
                    if t - not_needed),                     # keep only useful frames
                   key=lambda x: x[1])
    thinned, last_of_sig = [], {}
    for tok, ts, tset in cands:
        sig = tset - not_needed                             # what this frame can still fill
        prev = last_of_sig.get(sig)
        if prev is None or ts - prev >= WINDOW_US:
            thinned.append((tok, ts, tset)); last_of_sig[sig] = ts
    return end, thinned


def main():
    logs = blob_backed_logs()
    print(f"recon-capable test-split logs (real sensor blobs): {len(logs)}", flush=True)
    if not logs:
        sys.exit("no blob-backed logs found — check SENSOR_BLOBS path")

    prior_have, prior_claimed = load_prior()
    print(f"navtest already covers {len(prior_have)} types "
          f"({sum(prior_have.values())} scenarios)", flush=True)

    # types navtest already fills to N — frames that ONLY carry these are useless here,
    # so drop them at scan time (keeps the candidate pool small without losing rare tags)
    not_needed = frozenset() if MINE_ALL else frozenset(
        t for t, c in prior_have.items() if c >= N_PER_TYPE)
    print(f"already-full types excluded from mining: {len(not_needed)}", flush=True)

    # 1) scan every recon-capable log once -> flat candidate pool
    pool = []                       # (log, token, ts, frozenset(types))
    log_end, types_seen = {}, set()
    for i, log in enumerate(logs):
        end, cands = scan_log(log, not_needed)
        if not cands:
            continue
        log_end[log] = end
        for tok, ts, tset in cands:
            pool.append((log, tok, ts, tset))
            types_seen |= tset
        if (i + 1) % 25 == 0:
            print(f"  scanned {i+1}/{len(logs)} logs, {len(types_seen)} types so far", flush=True)
    print(f"scanned {len(log_end)} logs; candidate windows: {len(pool)}; "
          f"types present in blob-backed logs: {len(types_seen)}", flush=True)

    # 2) what do we still need?
    need = {}
    for typ in types_seen:
        n = N_PER_TYPE if MINE_ALL else max(0, N_PER_TYPE - prior_have.get(typ, 0))
        if n > 0:
            need[typ] = n
    print(f"types to mine: {len(need)}  (MINE_ALL={MINE_ALL})", flush=True)

    # 3) GREEDY SET COVER — each round take the window that fills the most still-needed
    #    types at once. Because a start frame carries several tags, one trained recon
    #    can satisfy several types; picking max-coverage windows means fewer recons for
    #    the same coverage. Windows never overlap (no duplicate recon of the same drive).
    taken = defaultdict(list)                       # log -> [(t0,t1)] blocked
    for log, wins in prior_claimed.items():         # never overlap the navtest set
        taken[log].extend(wins)
    n_win_log = defaultdict(int)
    per_log_type = defaultdict(lambda: defaultdict(int))

    def free(log, t0):
        t1 = t0 + WINDOW_US
        if t1 > log_end.get(log, 0):
            return False                            # window runs past end of log
        if n_win_log[log] >= MAX_WINDOWS_PER_LOG:
            return False
        return all(t1 <= a or t0 >= b for a, b in taken[log])

    def credits(log, tset):
        """types this window may be counted for (still needed AND under per-log cap)"""
        return {t for t in tset
                if need.get(t, 0) > 0 and per_log_type[log][t] < MAX_PER_LOG}

    live = [c for c in pool if c[3] & set(need)]
    print(f"  candidates touching a needed type: {len(live)}", flush=True)

    selection = defaultdict(list)                   # type -> [(tok, log, t0, t1)]
    chosen = []                                     # (log, tok, t0, t1, frozenset(credited))
    while True:
        best, best_score = None, 0
        for log, tok, ts, tset in live:
            c = credits(log, tset)
            if len(c) > best_score and free(log, ts):
                best, best_score = (log, tok, ts, c), len(c)
        if not best or best_score == 0:
            break
        log, tok, ts, c = best
        taken[log].append((ts, ts + WINDOW_US))
        n_win_log[log] += 1
        chosen.append((log, tok, ts, ts + WINDOW_US, frozenset(c)))
        for t in c:
            selection[t].append((tok, log, ts, ts + WINDOW_US))
            per_log_type[log][t] += 1
            need[t] -= 1
        need = {k: v for k, v in need.items() if v > 0}
        live = [x for x in live if x[3] & set(need)]

    n_rows = sum(len(v) for v in selection.values())
    print(f"\nmined {len(chosen)} DISTINCT scenarios -> {n_rows} type-slots "
          f"across {len(selection)} types", flush=True)

    # 4) write manifests
    os.makedirs(OUTDIR, exist_ok=True)
    # tsv = the CONVERSION set: one row per DISTINCT scenario (field 5 lists every type
    # it counts for, comma-joined). submit_stage.sh only reads fields 1-4.
    tsv = os.path.join(OUTDIR, "scenes_testsplit.tsv")
    with open(tsv, "w") as fh:
        for log, tok, t0, t1, ctypes in chosen:
            fh.write(f"{tok}\t{log}\t{t0}\t{t1}\t{','.join(sorted(ctypes))}\ttestsplit\n")
    # yaml = grouped by type (one scenario may appear under several types)
    yml = os.path.join(OUTDIR, "scenes_testsplit.yaml")
    with open(yml, "w") as fh:
        fh.write(f"# mined from the nuPlan test split ({len(log_end)} recon-capable logs)\n")
        fh.write(f"# window = 20s starting at the tagged frame\n")
        fh.write(f"# {len(chosen)} distinct scenarios -> {n_rows} type-slots, {len(selection)} types\n")
        for typ in sorted(selection):
            fh.write(f"{typ}:\n")
            for tok, log, t0, t1 in selection[typ]:
                fh.write(f"  - {{token: {tok}, log: {log}, t0: {t0}, t1: {t1}}}\n")

    # 5) coverage report over the full 73-type taxonomy view we can see here
    rep = os.path.join(OUTDIR, "coverage_report.txt")
    all_types = sorted(set(prior_have) | types_seen)
    still_short = []
    with open(rep, "w") as fh:
        fh.write(f"# navtest scenarios: {sum(prior_have.values())} | "
                 f"mined distinct scenarios: {len(chosen)} ({n_rows} type-slots)\n")
        fh.write(f"# type\tnavtest\tmined_testsplit\ttotal\tneed={N_PER_TYPE}\n")
        for typ in all_types:
            a = prior_have.get(typ, 0)
            b = len(selection.get(typ, []))
            fh.write(f"{typ}\t{a}\t{b}\t{a+b}\t{N_PER_TYPE}\n")
            if a + b < N_PER_TYPE:
                still_short.append((typ, a, b, a + b))
    print(f"\nwrote:\n  {tsv}\n  {yml}\n  {rep}", flush=True)
    full = sum(1 for t in all_types if prior_have.get(t, 0) + len(selection.get(t, [])) >= N_PER_TYPE)
    print(f"\ntypes now FULL ({N_PER_TYPE}/{N_PER_TYPE}): {full}/{len(all_types)}", flush=True)
    print(f"types still short: {len(still_short)}", flush=True)
    for typ, a, b, tot in sorted(still_short, key=lambda x: -x[3]):
        print(f"  {typ}: navtest {a} + mined {b} = {tot}/{N_PER_TYPE}", flush=True)


if __name__ == "__main__":
    main()
