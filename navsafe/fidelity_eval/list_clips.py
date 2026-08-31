#!/usr/bin/env python3
"""Print the clip ids the scorer's manifest covers, one per line, and mark
which still need rendering. Run ON THE POD (reads CephFS).

    list_clips.py            -> every clip in the manifest
    list_clips.py --todo     -> only those missing either harmonizer config

Kept as a file rather than inlined in the submitter: quoting it through
`kubectl exec bash -lc '...'` mangled the json escapes and the list came back
empty, which the submitter then reported as "could not read the manifest".
"""
import json, os, sys

MAN = "/avl-west/render_quality_eval/manifest.json"
R = "/avl-west/fidelity_eval/grpc"

clips = [f"{s['sid']}s{k}" for s in json.load(open(MAN))["scenarios"] for k in (1, 2, 3, 4)]
if "--todo" not in sys.argv:
    print("\n".join(clips)); sys.exit()

def has(cfg, c):
    d = os.path.join(R, cfg, c)
    if not os.path.isdir(d):
        return False
    for _, _, fs in os.walk(d):
        if any(f.endswith((".jpg", ".jpeg")) for f in fs):
            return True
    return False

todo = [c for c in clips if not (has("hoff", c) and has("hon", c))]
print("\n".join(todo))
