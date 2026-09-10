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
curves=[];chosen=None
for k in range(1,8):
 pred=np.empty((len(dev),2))
 for f in sorted({family(m) for m in dev}):
  train=[m for m in dev if family(m)!=f];test=[m for m in dev if family(m)==f];g=select(train,k);p=predict(g,test)
  for j,m in enumerate(test):pred[dev.index(m)]=p[j]
 s=stats(truth[[mi[m] for m in dev]],pred);entry={'k':k,'n_common':sum(min(k,len(ix)) for ix in strata),'n_with_v8':sum(min(k,len(ix)) for ix in strata)+len(extra),'development':s,'pass':passes(s)};curves.append(entry);print(json.dumps(entry),flush=True)
 if chosen is None and passes(s):chosen=k
(P/'development_curve.json').write_text(json.dumps(curves,indent=2))
if chosen is None:
 (P/'decision.json').write_text(json.dumps({'status':'development_failed','curves':curves},indent=2));raise SystemExit('No size passed: do not claim valid proxy')
groups=select(dev,chosen)
selection=[]
for a,g in groups:
 t=tokens[a];selection.append({'token':t,'leaf':meta[t]['leaf'],'cluster_size':len(g),'weight_270':len(g)/270,'weight_280':len(g)/280,'members':[tokens[i] for i in g],'selection':'kmeans','inserted':meta[t]['inserted']})
for t in extra:selection.append({'token':t,'leaf':'V-8','cluster_size':1,'weight_270':0,'weight_280':1/280,'members':[t],'selection':'census_due_to_missing_model_coverage','inserted':meta[t]['inserted']})
selection.sort(key=lambda r:(r['leaf'],r['token']))
(P/'proxy_set.json').write_text(json.dumps(selection,indent=2));(P/'proxy_tokens.txt').write_text(''.join(r['token']+'\n' for r in selection))
with (P/'proxy_set.csv').open('w') as f:
 w=csv.DictWriter(f,fieldnames=['token','leaf','cluster_size','weight_270','weight_280','selection','inserted']);w.writeheader();w.writerows({k:v for k,v in r.items() if k!='members'} for r in selection)
# Only now unseal reserved families. Never feed these values into selection.
pred=predict(groups,hold);actual=truth[[mi[m] for m in hold]];h=stats(actual,pred)
(P/'holdout_scores.json').write_text(json.dumps([{'model':m,'full_DS':actual[j,0]*100,'proxy_DS':pred[j,0]*100,'full_SR':actual[j,1]*100,'proxy_SR':pred[j,1]*100} for j,m in enumerate(hold)],indent=2))
rng=np.random.default_rng(620260909);random_stats=[]
for repeat in range(1000):
 p=np.zeros_like(pred)
 for ix in strata:
  sampled=rng.choice(ix,min(chosen,len(ix)),replace=False);p+=Y[sampled][:,[mi[m] for m in hold]].mean(axis=0)*len(ix)/len(tokens)
 random_stats.append(np.abs(p-actual).mean(axis=0)*100)
random_stats=np.array(random_stats);random_summary={name:{'median_mae_pp':float(np.median(random_stats[:,j])),'q025_mae_pp':float(np.quantile(random_stats[:,j],.025)),'q975_mae_pp':float(np.quantile(random_stats[:,j],.975)),'fraction_random_no_worse_than_proxy':float(np.mean(random_stats[:,j]<=h[name]['mae_pp']))} for j,name in enumerate(('DS','SR'))}
# Per-model available population and seed audit; no imputation.
score_rows=[]
for seed in ('seed0','seed1024'):
 for m in models+['pdm_closed']:
  available=[t for t in alltokens if (m,seed,t) in R];population=set(available);estimate=np.zeros(2);denom=0;missing_anchor=[]
  for s in selection:
   n=len(set(s['members'])&population)
   if not n:continue
   if s['token'] not in population:missing_anchor.append(s['token']);continue
   r=R[(m,seed,s['token'])];estimate+=n*np.array([r['ds'],100*float(r['success'])]);denom+=n
  ref=np.mean([[R[(m,seed,t)]['ds'],100*float(R[(m,seed,t)]['success'])] for t in available],axis=0)
  score_rows.append({'model':m,'seed':seed,'population_n':len(available),'represented_n':denom,'missing_anchors':missing_anchor,'full_DS':ref[0],'full_SR':ref[1],'proxy_DS':float(estimate[0]/denom),'proxy_SR':float(estimate[1]/denom),'comparison_valid':denom==len(available)})
(P/'all_scores.json').write_text(json.dumps(score_rows,indent=2))
# Non-proxy probability sample, chosen before any perturbation outcomes.
audit=[]
for leaf in sorted({r['leaf'] for r in selection}):
 remaining=[t for t in alltokens if meta[t]['leaf']==leaf and t not in {r['token'] for r in selection}]
 for t in sorted(rng.choice(remaining,min(2,len(remaining)),replace=False).tolist()):audit.append({'token':t,'leaf':leaf,'nonproxy_population':len(remaining),'inclusion_probability':min(2,len(remaining))/len(remaining)})
(P/'perturbation_audit_sample.json').write_text(json.dumps(audit,indent=2))
weights=np.array([r['weight_280'] for r in selection]);inserted_full=np.mean([bool(meta[t]['inserted']) for t in alltokens]);inserted_proxy=sum(r['weight_280']*bool(r['inserted']) for r in selection)
# Known altered-render-scope sensitivity: same frozen anchor mapping, remove these members.
bad={'9135a6d270475c7f','2391f12d7e6a5e7f','442b2cf63c6f570a'};sensitivity=[]
for m in hold:
 pop=[t for t in tokens if t not in bad];badanchors=[tokens[a] for a,g in groups if tokens[a] in bad]
 if badanchors:sensitivity.append({'model':m,'status':'cannot_estimate_after_excluding_selected_anchor','anchors':badanchors});continue
 est=sum(sum(tokens[i] not in bad for i in g)*np.array([R[(m,'seed0',tokens[a])]['ds'],100*float(R[(m,'seed0',tokens[a])]['success'])]) for a,g in groups)/len(pop)
 ref=np.mean([[R[(m,'seed0',t)]['ds'],100*float(R[(m,'seed0',t)]['success'])] for t in pop],axis=0);sensitivity.append({'model':m,'full':ref.tolist(),'proxy':est.tolist(),'abs_error_pp':np.abs(ref-est).tolist()})
report={'status':'baseline_holdout_pass' if passes(h) else 'baseline_holdout_failed','chosen_k':chosen,'n_proxy':len(selection),'development_models':dev,'holdout_models':hold,'holdout_metrics':h,'random_comparison':random_summary,'effective_weight_count':float(1/sum(weights**2)),'inserted_fraction_full':float(inserted_full),'inserted_fraction_proxy':float(inserted_proxy),'label_corrections':conflicts,'sensitivity_excluding_render_workarounds':sensitivity,'perturbation_validated':False,'perturbation_audit_n':len(audit),'scope':'Empirical baseline representativeness for recorded results; V8 census; no certification of heterogeneous source runs or perturbation representativeness.'}
(P/'decision.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2),flush=True)
