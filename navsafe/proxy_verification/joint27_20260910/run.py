
import os
os.environ.update(OMP_NUM_THREADS='1',OPENBLAS_NUM_THREADS='1',MKL_NUM_THREADS='1')
import pathlib,json,hashlib,time,csv
import numpy as np
from scipy.stats import spearmanr
P=pathlib.Path('/hugsim-storage/NexusSim/docs/experiments/proxy_verification_20260909')
O=P/'joint27_20260910';O.mkdir(exist_ok=True)
protocol=dict(budget=27,one_per_leaf=True,exclude='V-8',input='immutable previous snapshot, seed0 only for fitting',hyperparameters=[0,.01,.1],starts=8,max_sweeps=15,selection_seed=9010,random_baseline_draws=1000,outer='leave entire model family out',inner='leave family out within outer training; select lambda by family-balanced MAE',objective='mean squared aggregate score error + lambda * mean within-leaf representation error; DS/SR equal scales, equal family contribution',final='fit on original 11 development models; original 5 excluded models never select its lambda or anchors',caveat='Retrospective repeated use of existing benchmark; not fresh blind confirmation. No perturbation generalization claim.',gates='retain earlier MAE<=3pp, max<=5pp, rho>=.90; no loosening to call success')
(O/'PROTOCOL.json').write_text(json.dumps(protocol,indent=2))
raw=(P/'snapshot.json').read_bytes();rows=json.loads(raw);R={(r['model'],r['seed'],r['token']):r for r in rows}
old=json.load(open(P/'proxy27/proxy_set.json'));tokens=sorted(t for s in old for t in s['members']);idx={t:i for i,t in enumerate(tokens)}
leaves=[s['leaf'] for s in old];strata=[np.array([idx[t] for t in s['members']]) for s in old];w=np.array([len(ix)/270 for ix in strata])
models=sorted({r['model'] for r in rows if r['model']!='pdm_closed'})
def family(m):
 for f in ('diffusiondrive','mtdrive','recogdrive','simwam'):
  if m.startswith(f):return f
 return m
families=sorted({family(m) for m in models});mi={m:i for i,m in enumerate(models)}
Y=np.array([[[R[m,'seed0',t]['ds']/100,float(R[m,'seed0',t]['success'])] for m in models] for t in tokens])
assert Y.shape==(270,16,2) and np.all(np.isfinite(Y))
truth=Y.mean(axis=0)
def predict(a,ids):return (Y[a][:,ids,:]*w[:,None,None]).sum(axis=0)
def feats(ids):
 x=Y[:,ids,:].reshape(270,-1).copy()
 for j,i in enumerate(ids):x[:,2*j:2*j+2]/=np.sqrt(sum(family(models[k])==family(models[i]) for k in ids))
 return x
def centroid(ids):
 x=feats(ids)
 return np.array([ix[np.argmin(((x[ix]-x[ix].mean(axis=0))**2).sum(axis=1))] for ix in strata])
cache={}
def search(ids,lam):
 key=(tuple(ids),lam)
 if key in cache:return cache[key].copy()
 x=feats(ids);target=x.mean(axis=0);mu=[x[ix].mean(axis=0) for ix in strata]
 local=[((x[ix]-mu[j])**2).mean(axis=1) for j,ix in enumerate(strata)]
 rng=np.random.default_rng(9010);initial=centroid(ids);best=None;bestval=np.inf
 for start in range(8):
  a=initial.copy() if start==0 else np.array([rng.choice(ix) for ix in strata])
  agg=(x[a]*w[:,None]).sum(axis=0)
  for sweep in range(15):
   changed=False
   for j in rng.permutation(27):
    ix=strata[j];candidates=agg+w[j]*(x[ix]-x[a[j]])
    cost=((candidates-target)**2).mean(axis=1)+lam*w[j]*local[j]
    z=int(np.argmin(cost));n=int(ix[z])
    if n!=a[j]:agg=candidates[z];a[j]=n;changed=True
   if not changed:break
  lc=sum(w[j]*((x[a[j]]-mu[j])**2).mean() for j in range(27))
  val=((agg-target)**2).mean()+lam*lc
  if val<bestval-1e-15:bestval=val;best=a.copy()
 cache[key]=best
 return best.copy()
def tune(ids):
 fs=sorted({family(models[i]) for i in ids});scores=[]
 for lam in [0,.01,.1]:
  es=[]
  for f in fs:
   train=[i for i in ids if family(models[i])!=f];test=[i for i in ids if family(models[i])==f]
   a=search(train,lam);es.append(np.abs(predict(a,test)-truth[test]).mean())
  scores.append(float(np.mean(es)))
 return [0,.01,.1][int(np.argmin(scores))],scores
def metrics(pred,actual=truth):
 out={}
 for j,k in enumerate(('DS','SR')):
  e=(pred[:,j]-actual[:,j])*100
  out[k]={'mae_pp':float(np.abs(e).mean()),'max_error_pp':float(np.abs(e).max()),'bias_pp':float(e.mean()),'spearman':float(spearmanr(pred[:,j],actual[:,j]).statistic)}
 return out
joint=np.empty_like(truth);center=np.empty_like(truth);random=np.empty((1000,len(models),2));folds=[]
start=time.time()
for f in families:
 train=[i for i,m in enumerate(models) if family(m)!=f];test=[i for i,m in enumerate(models) if family(m)==f]
 lam,cv=tune(train);a=search(train,lam);c=centroid(train)
 joint[test]=predict(a,test);center[test]=predict(c,test)
 rng=np.random.default_rng(10203)
 for b in range(1000):random[b,test,:]=predict([rng.choice(ix) for ix in strata],test)
 folds.append({'family':f,'test_models':[models[i] for i in test],'lambda':lam,'inner_mae':[v*100 for v in cv],'joint_tokens':[tokens[i] for i in a]})
 print('outer',f,'lambda',lam,'elapsed',round(time.time()-start),flush=True)
oldinfo=json.load(open(P/'proxy27/verification.json'));dev=[mi[m] for m in oldinfo['selection_models']];hold=[mi[m] for m in oldinfo['evaluation_excluded_models']]
lam,cv=tune(dev);a=search(dev,lam);c=centroid(dev)
assert {tokens[i] for i in c}=={s['token'] for s in old},'centroid reproduction mismatch'
selection=[]
for j,i in enumerate(a):selection.append({'leaf':leaves[j],'token':tokens[i],'weight':float(w[j]),'cluster_size':len(strata[j]),'members':[tokens[k] for k in strata[j]],'method':'joint_set_search','lambda':lam})
assert len({s['token'] for s in selection})==27
assert all(a[j] in strata[j] for j in range(27))
(O/'proxy_set.json').write_text(json.dumps(selection,indent=2));(O/'proxy_tokens.txt').write_text(''.join(s['token']+'\n' for s in selection))
with (O/'proxy_set.csv').open('w') as f:
 writer=csv.DictWriter(f,fieldnames=['leaf','token','weight','cluster_size','method','lambda']);writer.writeheader();writer.writerows({k:v for k,v in s.items() if k!='members'} for s in selection)
np.savez(O/'comparison_arrays.npz',full=truth,joint_oof=joint,centroid_oof=center,random_oof=random,models=models)
rm=np.mean(np.abs(random-truth[None,:,:]),axis=1)*100
final_joint=predict(a,hold);final_centroid=predict(c,hold);full=truth[hold]
rng=np.random.default_rng(10203);fr=[]
for b in range(1000):fr.append(predict([rng.choice(ix) for ix in strata],hold))
fr=np.array(fr);ferr=np.abs(fr-full).mean(axis=1)*100
# Paired family-level bootstrap uncertainty, not 1000 random draws as independent policies.
famdiff=[]
for fam in families:
 ids=[i for i,m in enumerate(models) if family(m)==fam]
 famdiff.append((np.abs(joint[ids]-truth[ids]).mean(axis=0)-np.abs(center[ids]-truth[ids]).mean(axis=0))*100)
rng=np.random.default_rng(30405);boot=np.array([np.array(famdiff)[rng.integers(0,len(families),len(families))].mean(axis=0) for _ in range(5000)])
result={'protocol':protocol,'model_count':len(models),'family_count':len(families),'source_sha256':hashlib.sha256(raw).hexdigest(),'oof_joint':metrics(joint),'oof_centroid':metrics(center),'oof_random_mean_mae_pp':rm.mean(axis=0).tolist(),'oof_random_median_mae_pp':np.median(rm,axis=0).tolist(),'family_mean_joint_minus_centroid_mae_pp':np.mean(famdiff,axis=0).tolist(),'family_bootstrap_95ci_joint_minus_centroid':np.quantile(boot,[.025,.975],axis=0).tolist(),'final_lambda':lam,'final_inner_mae_pp':[v*100 for v in cv],'final_excluded_joint':metrics(final_joint,full),'final_excluded_centroid':metrics(final_centroid,full),'final_random_mean_mae_pp':ferr.mean(axis=0).tolist(),'final_random_fraction_no_worse':np.mean(ferr<=np.abs(final_joint-full).mean(axis=0)*100,axis=0).tolist(),'changed_tokens':len(set(s['token'] for s in selection)-set(s['token'] for s in old)),'folds':folds,'perturbation_validated':False}
result['final_precision_gate_pass']=all(v['mae_pp']<=3 and v['max_error_pp']<=5 and v['spearman']>=.9-1e-12 for v in result['final_excluded_joint'].values())
# Independent seed outcomes only for held-out models, same frozen anchors.
yy=np.array([[[R[models[i],'seed1024',t]['ds']/100,float(R[models[i],'seed1024',t]['success'])] for i in hold] for t in tokens])
result['final_excluded_seed1024']=metrics((yy[a]*w[:,None,None]).sum(axis=0),yy.mean(axis=0))
with (O/'final_test_models.csv').open('w') as f:
 ww=csv.writer(f);ww.writerow(['model','full_DS','joint_DS','centroid_DS','full_SR','joint_SR','centroid_SR'])
 for j,i in enumerate(hold):ww.writerow([models[i],100*full[j,0],100*final_joint[j,0],100*final_centroid[j,0],100*full[j,1],100*final_joint[j,1],100*final_centroid[j,1]])
(O/'results.json').write_text(json.dumps(result,indent=2))
print(json.dumps({k:v for k,v in result.items() if k not in ('folds','protocol')},indent=2),flush=True)
