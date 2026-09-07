#!/usr/bin/env python3
"""Rename a Job manifest to a name that does not exist, so a --dry-run=server
exercises the ADMISSION WEBHOOK rather than an immutable-field patch check.

Two traps, both hit once:
  * Probing under the manifest's own name is useless once the Job exists: a Job
    spec is immutable, so the dry run fails on `field is immutable` whatever the
    webhook thinks, and a script reading that as "refused" waits forever.
  * Kubernetes parses YAML 1.1, where a bare Y is a BOOLEAN, and an env value
    must be a string. The default dumper writes ACCEPT_EULA's 'Y' unquoted and
    the API rejects the whole object before the webhook is ever consulted.
"""
import sys, yaml

class Q(yaml.SafeDumper):
    pass
Q.add_representer(str, lambda d, v: d.represent_scalar("tag:yaml.org,2002:str", v, style="'"))

d = yaml.safe_load(open(sys.argv[1]))
d["metadata"]["name"] = "navsafe-admitprobe"
d["metadata"].pop("labels", None)
yaml.dump(d, open(sys.argv[2], "w"), Dumper=Q, default_flow_style=False, sort_keys=False)
