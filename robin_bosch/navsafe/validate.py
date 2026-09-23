#!/usr/bin/env python3
from pathlib import Path
import csv, sys, yaml
root=Path(__file__).resolve().parent
tokens=[x.strip() for x in (root/'full_test_tokens.txt').read_text().splitlines() if x.strip()]
if len(tokens)!=280 or len(set(tokens))!=280:
    raise SystemExit(f'expected 280 unique tokens, got {len(tokens)} rows / {len(set(tokens))} unique')
raw=[line for line in (root/'models.tsv').read_text().splitlines() if line.strip()]
if not raw or raw[0].lstrip('# ').split('\t')[:4] != ['label','model_type','checkpoint','extra_env']:
    raise SystemExit('models.tsv header is invalid')
rows=list(csv.reader([line for line in raw[1:] if not line.lstrip().startswith('#')], delimiter='\t'))
if not rows: raise SystemExit('models.tsv has no models')
jobfile=Path(sys.argv[1]) if len(sys.argv)>1 else root/'job.yaml'
job=yaml.safe_load(jobfile.read_text())
assert job['kind']=='Job' and job['spec']['completionMode']=='Indexed'
assert job['spec']['completions']==job['spec']['parallelism']
for env in job['spec']['template']['spec']['containers'][0].get('env',[]):
    if 'value' in env and not isinstance(env['value'],str):
        raise SystemExit(f'env {env["name"]} value must be a quoted string')
for r in rows:
    assert len(r)==4 and r[1]=='drivor_action' and r[2].startswith('/root/bosch-summer/'), r
print(f"OK: 280 unique scenarios, {len(rows)} models, {job['spec']['completions']} indexed worker(s), {jobfile.name}")
