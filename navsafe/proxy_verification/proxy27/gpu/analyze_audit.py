
import argparse,json,pathlib,math
import numpy as np
from scipy.stats import t as student_t
ap=argparse.ArgumentParser()
ap.add_argument('--root',default='/avl-west/runs/20260909-proxy27-audit/eval')
ap.add_argument('--selection-dir',default='/hugsim-storage/NexusSim/docs/experiments/proxy_verification_20260909/proxy27')
ap.add_argument('--output',required=True)
a=ap.parse_args();p=pathlib.Path(a.selection_dir)
proxy=json.load(open(p/'proxy_set.json'));audit=json.load(open(p/'audit54.json'))
N=sum(s['cluster_size'] for s in proxy)
missing=[];out=[]
for model in ['drivor','diffusiondrive_simscale']:
 vals={}
 for row in proxy+audit:
  for arm in ['base','latp0.5']:
   f=pathlib.Path(a.root)/'seed0'/row['leaf']/row['token']/arm/model/'navsafe_metrics.json'
   if not f.is_file():missing.append(str(f));continue
   d=json.load(open(f));m=d.get('metrics',{})
   if d.get('status')!='scored' or m.get('driving_score') is None or m.get('success') is None:missing.append(str(f)+' [unscored]');continue
   vals[row['token'],arm]=np.array([float(m['driving_score']),100*float(m['success'])])
 if len(vals)!=2*(len(proxy)+len(audit)):continue
 for condition in ['base','latp0.5','degradation']:
  def v(token):
   return vals[token,'base']-vals[token,'latp0.5'] if condition=='degradation' else vals[token,condition]
  estimate=np.zeros(2);point=np.zeros(2);variances=[]
  for s in proxy:
   n=s['cluster_size'];av=v(s['token'])
   samples=[v(q['token']) for q in audit if q['leaf']==s['leaf']]
   assert len(samples)==2
   mean=np.mean(samples,axis=0)
   estimate+=(av+(n-1)*mean)/N
   point+=n*av/N
   variances.append(((n-1)/N)**2*(1-2/(n-1))*np.var(samples,axis=0,ddof=1)/2)
  var=np.array(variances);total=var.sum(axis=0);err=point-estimate
  for j,metric in enumerate(['DS','SR']):
   df=float(total[j]**2/np.sum(var[:,j]**2)) if np.sum(var[:,j]**2)>0 else None
   half=float(student_t.ppf(.975,df)*math.sqrt(total[j])) if df else None
   interval=[float(err[j]-half),float(err[j]+half)] if half is not None else None
   out.append({'model':model,'condition':condition,'metric':metric,'proxy':float(point[j]),'population_estimate':float(estimate[j]),'error_estimate_pp':float(err[j]),'approximate_marginal_95ci_error_pp':interval,'satterthwaite_df':df,'within_5pp_equivalence':interval is not None and interval[0]>=-5 and interval[1]<=5})
result={'status':'incomplete' if missing else 'audit_complete','population_n':N,'proxy_n':len(proxy),'audit_n':len(audit),'missing':missing,'results':out,'uncertainty_note':'Design-based stratified complement estimate; approximate t interval with finite population correction, only two audit samples per leaf. Intervals are marginal, not simultaneous. Zero estimated variance is treated as inconclusive. This is not proof across all perturbations.'}
pathlib.Path(a.output).write_text(json.dumps(result,indent=2));print(result['status'])
raise SystemExit(1 if missing else 0)
