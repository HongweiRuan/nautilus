#!/usr/bin/env python3
"""Confirm an ablation arm's Hydra overrides actually landed in the parsed config.

A train job is 4.5 h; publishing its usdz under an arm name that the run did not
actually use is worse than losing the run, because the comparison then silently
measures nothing.  Called from templates/train_arm.yaml as:

    python3 arm_check.py <parsed.yaml> '<json dict of dotted-key -> expected value>'
"""
import json
import sys

import yaml


def dig(cfg, dotted):
    node = cfg
    for part in dotted.split("."):
        node = node[part]
    return node


def main(argv):
    cfg = yaml.safe_load(open(argv[1]))
    want = json.loads(argv[2])
    got = {k: dig(cfg, k) for k in want}
    print("[arm-check] parsed config:", got, flush=True)
    bad = {k: (got[k], want[k]) for k in want if got[k] != want[k]}
    if bad:
        print("[arm-check] MISMATCH (got, want):", bad, flush=True)
        return 1
    print("[arm-check] OK", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
