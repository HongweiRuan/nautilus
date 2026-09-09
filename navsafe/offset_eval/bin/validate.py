#!/usr/bin/env python3
"""Local validation only; never creates cluster resources."""
import importlib.util,json,subprocess
from pathlib import Path
import yaml
P=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('manage',P/'bin/manage.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
def rows(name):
 s=json.loads((P/f'config/scenarios/{name}.json').read_text())
 return {(leaf,p['token']):p for leaf,b in s['leaves'].items() for p in b['picked']},s['grid']['arms']
a,grid=rows('all');plain,gp=rows('plain');edit,ge=rows('edit')
assert not plain.keys() & edit.keys()
assert plain|edit==a and grid==gp==ge
assert sum(len(p.get('arms_run') or grid) for p in a.values())==1021
count=0;names=set()
for model,entry in m.CFG['models'].items():
 lines=[x for x in (P/f'config/models/{model}.tsv').read_text().splitlines() if x and not x.startswith('#')]
 assert len(lines)==1 and lines[0].split('\t')[0]==model
 for partition,data in [('plain',plain),('edit',edit)]:
  workers=entry['workers'][partition]
  assert 0<workers<=len(data)
  for i in range(workers):
   f=P/f'jobs/{model}/{partition}/w{i:02d}.yaml';d=yaml.safe_load(f.read_text())
   assert d==m.manifest(model,partition,i),f'Stale manifest: {f}'
   name=d['metadata']['name'];assert name not in names and len(name)<=63;names.add(name)
   c=d['spec']['template']['spec']['containers'][0];env={x['name']:x['value'] for x in c['env'] if 'value' in x}
   assert all(isinstance(v,str) for v in env.values())
   assert int(env['WORKERS'])==workers and int(env['WORKER_INDEX'])==i
   assert c['resources']['requests']['nvidia.com/gpu']==c['resources']['limits']['nvidia.com/gpu']
   gpus=int(c['resources']['requests']['nvidia.com/gpu'])
   assert partition!='edit' or gpus>=2
   assert model!='drivevla_w0' or (gpus==3 and env['NAVSAFE_VLA_GPU']=='2')
   assert int(c['resources']['limits']['memory'][:-2])<=1.2*int(c['resources']['requests']['memory'][:-2])
   assert env['OUTROOT']==m.CFG['outroot'];count+=1
for f in [P/'scripts/run_worker.sh',P/'bash_offset_eval.sh',* (P/'bin').glob('*.sh')]:
 subprocess.run(['bash','-n',str(f)],check=True)
print(f'PASS: {count} Jobs, {len(a)} disjoint scenarios, 1021 cells/model; GPU/env/resource/partition checks and bash syntax')
