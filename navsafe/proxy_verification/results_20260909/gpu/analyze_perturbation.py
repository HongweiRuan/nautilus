"""CPU-only verification of a completed, approved GPU audit; never launches jobs."""
import argparse,json,pathlib,numpy as np
ap=argparse.ArgumentParser();ap.add_argument('--root',default='/avl-west/runs/20260909-proxy-verification-v1/eval');ap.add_argument('--proxy',default='/hugsim-storage/NexusSim/docs/experiments/proxy_verification_20260909/proxy_set.json');ap.add_argument('--output',required=True);a=ap.parse_args()
proxy=json.load(open(a.proxy));lookup={t:s['leaf'] for s in proxy for t in s['members']};tokens=sorted(lookup);weights={s['token']:s['weight_280'] for s in proxy};results=[];missing=[]
for model in ('drivor','diffusiondrive_simscale'):
 values={}
 for arm in ('base','latp0.5'):
  v={}
  for t in tokens:
   p=pathlib.Path(a.root)/'seed0'/lookup[t]/t/arm/model/'navsafe_metrics.json'
   if not p.is_file():missing.append(str(p));continue
   d=json.load(open(p));m=d.get('metrics',{})
   if d.get('status')!='scored' or m.get('driving_score') is None or m.get('success') is None:missing.append(str(p)+' [unscored]');continue
   v[t]=np.array([float(m['driving_score']),100*float(m['success'])])
  if len(v)!=len(tokens):continue
  values[arm]={'full':np.mean(list(v.values()),axis=0),'proxy':sum(weights[t]*v[t] for t in weights)}
 if len(values)!=2:continue
 row={'model':model}
 for arm in ('base','latp0.5'):
  d=values[arm];row[arm]={k:v.tolist() for k,v in d.items()};row[arm]['abs_error_pp']=np.abs(d['full']-d['proxy']).tolist()
 full=values['base']['full']-values['latp0.5']['full'];pred=values['base']['proxy']-values['latp0.5']['proxy']
 row['degradation']={'full':full.tolist(),'proxy':pred.tolist(),'abs_error_pp':np.abs(full-pred).tolist()};row['pass']=all(e<=5+1e-12 for arm in ('base','latp0.5','degradation') for e in row[arm]['abs_error_pp']);results.append(row)
out={'status':'incomplete' if missing else ('passed' if all(r['pass'] for r in results) else 'failed'),'missing_count':len(missing),'missing':missing,'results':results,'scope':'two models; baseline and +0.5m lateral arm only; DS/SR order'}
pathlib.Path(a.output).write_text(json.dumps(out,indent=2));print(out['status'],len(missing));raise SystemExit(0 if out['status']=='passed' else 1)
