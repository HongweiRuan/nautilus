import json,pathlib,math,datetime
P=pathlib.Path('/hugsim-storage/NexusSim/docs/experiments/proxy_verification_20260909')
root=pathlib.Path('/avl-west/navsafe_eval/metrics_all')
old=json.loads((P/'proxy_set.json').read_text())
tokens=sorted({s['token'] for s in old if s['leaf']=='V-8'})
assert len(tokens)==10
models=sorted(p.name for p in root.iterdir() if p.is_dir())
report={'checked_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'root':str(root),'tokens':tokens,'coverage':{}}
for model in models:
 report['coverage'][model]={}
 for seed in ['seed0','seed1024','seed1']:
  good=[];bad=[]
  for token in tokens:
   p=root/model/seed/(token+'.json')
   if not p.exists():bad.append({'token':token,'reason':'missing'});continue
   try:
    d=json.loads(p.read_text());m=d.get('metrics') or {};ds=m.get('driving_score');sr=m.get('success')
    valid=d.get('status')=='scored' and isinstance(ds,(int,float)) and math.isfinite(ds) and sr in (0,1,True,False)
    if valid:good.append(token)
    else:bad.append({'token':token,'reason':'invalid','status':d.get('status')})
   except Exception as e:bad.append({'token':token,'reason':str(e)})
  report['coverage'][model][seed]={'valid':len(good),'bad':bad}
report['all_learned_seed0_complete']=all(v['seed0']['valid']==10 for m,v in report['coverage'].items() if m!='pdm_closed')
out=P/'v8_coverage_20260910';out.mkdir(exist_ok=True)
(out/'coverage.json').write_text(json.dumps(report,indent=2))
print('MODEL seed0 seed1024 seed1')
for m,v in report['coverage'].items():print(m,*[v[s]['valid'] for s in ['seed0','seed1024','seed1']])
print('ALL LEARNED seed0 COMPLETE:',report['all_learned_seed0_complete'])
print('REPORT',out/'coverage.json')
