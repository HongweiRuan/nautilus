import os
os.environ.update(OMP_NUM_THREADS='1',OPENBLAS_NUM_THREADS='1',MKL_NUM_THREADS='1')
import json, pathlib, collections, hashlib, csv, warnings
import numpy as np
from sklearn.cluster import KMeans
from scipy.stats import spearmanr, kendalltau
P=pathlib.Path('/root/proxy_verification_20260909')
rows=json.loads((P/'snapshot.json').read_text())
R={(r['model'],r['seed'],r['token']):r for r in rows}
models=sorted({r['model'] for r in rows if r['model']!='pdm_closed'})
family=lambda m: 'diffusiondrive' if m.startswith('diffusiondrive') else ('mtdrive' if m.startswith('mtdrive') else ('recogdrive' if m.startswith('recogdrive') else ('simwam' if m.startswith('simwam') else m)))
hold=[m for m in models if family(m) in ('drivor','recogdrive','simwam')];dev=[m for m in models if m not in hold]
sets=[{r['token'] for r in rows if r['model']==m and r['seed']=='seed0'} for m in models]
tokens=sorted(set.intersection(*sets));alltokens=sorted(set.union(*sets));extra=sorted(set(alltokens)-set(tokens))
meta={};conflicts={}
for t in alltokens:
 rr=[r for r in rows if r['token']==t];labs={tuple(r['leaves']) for r in rr}
 if len(labs)>1:
  p=pathlib.Path('/avl-west/navsafe_eval/dataset')/t/'manifest.json';b=p.read_bytes();d=json.loads(b)['scenario_meta'];leaves=d['taxonomy_leaves'];conflicts[t]={'old':sorted(labs),'canonical':leaves,'source':str(p),'sha256':hashlib.sha256(b).hexdigest()}
 else:leaves=list(next(iter(labs)))
 assert len(leaves)==1,(t,leaves)
 meta[t]={'leaf':leaves[0],'inserted':d.get('has_inserted_actors',rr[0]['inserted']) if len(labs)>1 else rr[0]['inserted'],'types':rr[0]['types']}
assert len(tokens)==270 and len(alltokens)==280 and all(meta[t]['leaf']=='V-8' for t in extra)
leaves=sorted({meta[t]['leaf'] for t in tokens});strata=[np.array([i for i,t in enumerate(tokens) if meta[t]['leaf']==l]) for l in leaves]
def mat(ms,ts=tokens,seed='seed0'):
 return np.array([[[R[(m,seed,t)]['ds']/100,float(R[(m,seed,t)]['success'])] for m in ms] for t in ts])
Y=mat(models);truth=Y.mean(axis=0);mi={m:i for i,m in enumerate(models)}
def select(ms,k):
 X=mat(ms).reshape(len(tokens),-1)
 for j,m in enumerate(ms):X[:,2*j:2*j+2]/=np.sqrt(sum(family(v)==family(m) for v in ms))
 groups=[]
 for ix in strata:
  kk=min(k,len(ix));u=len(np.unique(X[ix],axis=0))
  with warnings.catch_warnings():
   warnings.simplefilter('ignore');labels=KMeans(n_clusters=min(kk,u),random_state=20260909,n_init=20).fit_predict(X[ix])
  gs=[ix[labels==z] for z in sorted(set(labels))]
  while len(gs)<kk:
   j=max(range(len(gs)),key=lambda j:len(gs[j]));g=gs.pop(j);gs.extend([g[::2],g[1::2]])
  for g in gs:
   a=g[np.argmin(((X[g]-X[g].mean(axis=0))**2).sum(axis=1))];groups.append((int(a),g.tolist()))
 return groups
def predict(groups,ms):
 return sum(len(g)/len(tokens)*Y[a,[mi[m] for m in ms]] for a,g in groups)
def stats(actual,pred):
 out={}
 for j,name in enumerate(('DS','SR')):
  a=actual[:,j];p=pred[:,j];e=np.abs(a-p)*100;rho=float(spearmanr(a,p).statistic) if len(a)>1 else None
  pairs=[(i,z) for i in range(len(a)) for z in range(i+1,len(a)) if abs(a[i]-a[z])>=.1-1e-9]
  wrong=sum((a[i]-a[z])*(p[i]-p[z])<=0 for i,z in pairs)
  out[name]={'mae_pp':float(e.mean()),'max_error_pp':float(e.max()),'spearman':rho,'kendall_tau_b':float(kendalltau(a,p).statistic) if len(a)>1 else None,'large_gap_pairs':len(pairs),'large_gap_inversions':int(wrong)}
 return out
def passes(s):return all(v['mae_pp']<=3 and v['max_error_pp']<=5 and v['spearman'] is not None and v['spearman']>=.9-1e-12 and v['large_gap_inversions']==0 for v in s.values())


OUT=P/'proxy27'
groups=select(dev,1)
selection=[]
for a,g in groups:
 t=tokens[a]
 selection.append({'token':t,'leaf':meta[t]['leaf'],'cluster_size':len(g),'weight':len(g)/270,'inserted':meta[t]['inserted'],'members':[tokens[i] for i in g]})
selection.sort(key=lambda x:(x['leaf'].split('-')[0],int(x['leaf'].split('-')[1])))
assert len(selection)==27 and len({x['leaf'] for x in selection})==27
assert all(x['leaf']!='V-8' for x in selection)
assert sorted(t for x in selection for t in x['members'])==tokens
assert abs(sum(x['weight'] for x in selection)-1)<1e-12
X=mat(dev).reshape(len(tokens),-1)
for j,m in enumerate(dev):X[:,2*j:2*j+2]/=np.sqrt(sum(family(v)==family(m) for v in dev))
for a,g in groups:
 dist=((X[g]-X[g].mean(axis=0))**2).sum(axis=1)
 assert np.isclose(((X[a]-X[g].mean(axis=0))**2).sum(),dist.min())
(OUT/'proxy_set.json').write_text(json.dumps(selection,indent=2))
(OUT/'proxy_tokens.txt').write_text(''.join(s['token']+'\n' for s in selection))
with (OUT/'proxy_set.csv').open('w') as f:
 w=csv.DictWriter(f,fieldnames=['leaf','token','cluster_size','weight','inserted']);w.writeheader();w.writerows({k:v for k,v in s.items() if k!='members'} for s in selection)
summary={};scores=[]
for name,ms in [('development',dev),('selection_excluded_families',hold),('all_learned',models)]:
 pred=predict(groups,ms);actual=truth[[mi[m] for m in ms]];summary[name]=stats(actual,pred)
 for j,m in enumerate(ms):
  if name=='all_learned':scores.append({'model':m,'full_DS':actual[j,0]*100,'proxy_DS':pred[j,0]*100,'full_SR':actual[j,1]*100,'proxy_SR':pred[j,1]*100})
(OUT/'baseline_scores.json').write_text(json.dumps(scores,indent=2))
summary['status']='selected_for_exploratory_perturbation_analysis_not_certified_full_benchmark_replacement'
summary['selection_models']=dev;summary['evaluation_excluded_models']=hold
summary['proxy_n']=27;summary['population_n']=270;summary['perturbation_validated']=False
summary['validation_note']='Retrospective diagnostics: same family split as preceding study, not a new blind test.'
rng=np.random.default_rng(20260910);rnd=[]
for _ in range(1000):
 pred=sum(len(ix)/270*Y[rng.choice(ix),[mi[m] for m in hold]] for ix in strata)
 rnd.append(np.abs(pred-truth[[mi[m] for m in hold]]).mean(axis=0)*100)
summary['random_comparison']={k:{'median_mae_pp':float(np.median(np.array(rnd)[:,j])),'fraction_random_no_worse':float(np.mean(np.array(rnd)[:,j]<=summary['selection_excluded_families'][k]['mae_pp']))} for j,k in enumerate(['DS','SR'])}
audit=[]
for s in selection:
 rem=[t for t in s['members'] if t!=s['token']]
 for t in sorted(rng.choice(rem,2,replace=False).tolist()):audit.append({'token':t,'leaf':s['leaf'],'remaining_leaf_n':len(rem),'inclusion_probability':2/len(rem)})
(OUT/'audit54.json').write_text(json.dumps(audit,indent=2))
old=json.load(open(P/'gpu/selection.json'));inputs={q['token']:q for b in old['leaves'].values() for q in b['picked']}
checks=[]
for s in selection:
 q=inputs[s['token']];checks.append({'token':s['token'],'data_root_exists':pathlib.Path(q['data_root']).is_dir(),'bundle_exists':pathlib.Path(q['bundle']).is_dir(),'ego_frames':q['ego_frames'],'handoff':q['handoff']})
assert all(x['data_root_exists'] and x['bundle_exists'] and x['ego_frames']>x['handoff']+20 for x in checks)
(OUT/'input_checks.json').write_text(json.dumps(checks,indent=2))
summary['input_checks']='27/27 passed; CPU existence only, not GPU render validation'
summary['source_snapshot_sha256']=hashlib.sha256((P/'snapshot.json').read_bytes()).hexdigest()
(OUT/'verification.json').write_text(json.dumps(summary,indent=2))
gpu=OUT/'gpu';gpu.mkdir(exist_ok=True)
blocks={}
for s in selection+audit:blocks.setdefault(s['leaf'],{'picked':[]})['picked'].append(inputs[s['token']])
(gpu/'selection.json').write_text(json.dumps({'grid':old['grid'],'leaves':blocks},indent=2))
print(json.dumps(summary,indent=2))
print('SELECTION')
for s in selection:print(s['leaf'],s['token'])
