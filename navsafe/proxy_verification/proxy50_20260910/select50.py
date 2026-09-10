import os
os.environ.update(OMP_NUM_THREADS='1',OPENBLAS_NUM_THREADS='1',MKL_NUM_THREADS='1',MPLBACKEND='Agg')
import pathlib,json,csv,hashlib,datetime,warnings
import numpy as np
from sklearn.cluster import KMeans
from scipy.stats import spearmanr
import matplotlib.pyplot as plt
P=pathlib.Path('/hugsim-storage/NexusSim/docs/experiments/proxy_verification_20260909');I=P/'proxy28_20260910';O=P/'proxy50_20260910';O.mkdir(exist_ok=True)
protocol={'budget':50,'minimum_per_leaf':1,'population':280,'source':'proxy28_20260910/snapshot.json','features':'DS/100 and success, family sqrt count scaling','method':'within-leaf k-means then closest real anchor; dynamic programming allocates k across leaves minimizing total squared anchor reconstruction error','kmeans_n_init':20,'seed':9010,'validation':'fixed original 11/5 retrospective; leave entire family out and refit all allocation/clustering','random_draws':1000,'random_comparator':'same per-leaf allocation as each evaluated panel; uniform without replacement in each leaf; equal within-leaf random weights','primary':'within-leaf DS/SR MAE; secondary aggregate MAE and ranking','no_threshold_tuning':True,'gpu':False,'perturbation':False}
(O/'PROTOCOL.json').write_text(json.dumps(protocol,indent=2))
raw=(I/'snapshot.json').read_bytes();rows=json.loads(raw);info=json.loads((I/'verification.json').read_text());old=json.loads((I/'proxy_set.json').read_text());models=sorted(info['selection_models']+info['heldout_models']);tokens=sorted({r['token'] for r in rows});idx={t:i for i,t in enumerate(tokens)};R={(r['model'],r['token']):r for r in rows}
Y=np.array([[[R[m,t]['ds']/100,float(R[m,t]['success'])] for m in models] for t in tokens]);assert Y.shape==(280,16,2) and np.isfinite(Y).all()
leaves=[s['leaf'] for s in old];strata=[np.array(sorted(idx[t] for t in s['members'])) for s in old];truthleaf=np.array([Y[ix].mean(0) for ix in strata]);truth=Y.mean(0);dev=[models.index(m) for m in info['selection_models']];hold=[models.index(m) for m in info['heldout_models']]
def fam(m):return next((f for f in ('diffusiondrive','mtdrive','recogdrive','simwam') if m.startswith(f)),m)
families=sorted({fam(m) for m in models})
def features(ids):
 x=Y[:,ids,:].reshape(280,-1).copy()
 for j,i in enumerate(ids):x[:,2*j:2*j+2]/=np.sqrt(sum(fam(models[k])==fam(models[i]) for k in ids))
 return x

def fit(ids,budget):
 x=features(ids);opts=[]
 for leaf,ix in zip(leaves,strata):
  v=x[ix];options={};maxk=min(len(ix),len(np.unique(v,axis=0)),budget-27)
  for k in range(1,maxk+1):
   if k==1:labels=np.zeros(len(ix),int)
   else:labels=KMeans(n_clusters=k,n_init=20,random_state=9010,algorithm='lloyd').fit_predict(v)
   groups=[];cost=0.
   for label in sorted(set(labels)):
    members=ix[labels==label];center=x[members].mean(0);anchor=int(members[np.argmin(((x[members]-center)**2).sum(1))]);cost+=float(((x[members]-x[anchor])**2).sum());groups.append((anchor,members))
   if len(groups)==k:options[k]=(cost,groups)
  opts.append(options)
 # Exact allocation optimization over fitted within-leaf options, not globally optimal clustering.
 dp={0:(0.,[])}
 for options in opts:
  new={}
  for total,(cost,ks) in dp.items():
   for k,(extra,_) in options.items():
    if total+k>budget:continue
    candidate=(cost+extra,ks+[k])
    if total+k not in new or candidate[0]<new[total+k][0]-1e-12:new[total+k]=candidate
  dp=new
 assert budget in dp
 cost,ks=dp[budget];return [opts[j][k][1] for j,k in enumerate(ks)],ks,cost

def prediction(panel):
 leaf=np.array([sum(len(members)*Y[a] for a,members in groups)/len(strata[j]) for j,groups in enumerate(panel)])
 return leaf,np.einsum('l,lmk->mk',np.array([len(ix)/280 for ix in strata]),leaf)

def metrics(lp,ids):
 aggregate=np.einsum('l,lmk->mk',np.array([len(ix)/280 for ix in strata]),lp);e=100*(lp[:,ids]-truthleaf[:,ids]);ae=np.abs(100*(aggregate[ids]-truth[ids]));perleaf=np.abs(e).mean(1)
 return {'within_leaf_mae_pp':np.abs(e).mean((0,1)).tolist(),'worst_leaf_mae_pp':perleaf.max(0).tolist(),'p90_leaf_mae_pp':np.quantile(perleaf,.9,axis=0).tolist(),'aggregate_mae_pp':ae.mean(0).tolist(),'aggregate_max_error_pp':ae.max(0).tolist(),'spearman':[float(spearmanr(aggregate[ids,j],truth[ids,j]).statistic) for j in range(2)]}

def random_eval(ks,ids,seed):
 rng=np.random.default_rng(seed);lp=np.zeros((1000,28,len(ids),2))
 for b in range(1000):
  for j,(ix,k) in enumerate(zip(strata,ks)):lp[b,j]=Y[rng.choice(ix,k,replace=False)][:,ids,:].mean(0)
 err=np.abs(lp-truthleaf[None,:,ids,:]);total=np.einsum('l,blmk->bmk',np.array([len(ix)/280 for ix in strata]),lp)
 return {'within_leaf_mae_mean_pp':(100*err.mean((1,2))).mean(0).tolist(),'aggregate_mae_mean_pp':(100*np.abs(total-truth[None,ids,:]).mean(1)).mean(0).tolist()},lp
fixed28,k28,c28=fit(dev,28);assert [tokens[g[0][0]] for g in fixed28]==[s['token'] for s in old]
fixed50,k50,c50=fit(dev,50);l28,_=prediction(fixed28);l50,_=prediction(fixed50)
print('Fixed 50 allocation',dict(zip(leaves,k50)),flush=True)
allids=list(range(16));result={'metric_order':['DS','SR'],'source_sha256':hashlib.sha256(raw).hexdigest(),'created_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'fixed_all_descriptive':{'28':metrics(l28,allids),'50':metrics(l50,allids)},'fixed_heldout_retrospective':{'28':metrics(l28,hold),'50':metrics(l50,hold)},'selection_models':info['selection_models'],'heldout_models':info['heldout_models'],'allocation':dict(zip(leaves,k50)),'training_distortion':{'28':c28,'50':c50}}
oof28=np.zeros_like(l28);oof50=np.zeros_like(l50);random_oof=np.zeros((1000,28,16,2));folds=[]
for f in families:
 train=[i for i,m in enumerate(models) if fam(m)!=f];test=[i for i,m in enumerate(models) if fam(m)==f]
 p28,_,_=fit(train,28);p50,ks,_=fit(train,50);q28,_=prediction(p28);q50,_=prediction(p50);oof28[:,test]=q28[:,test];oof50[:,test]=q50[:,test]
 _,rp=random_eval(ks,test,9010);random_oof[:,:,test,:]=rp
 folds.append({'family':f,'allocation':dict(zip(leaves,ks)),'tokens':[tokens[a] for g in p50 for a,_ in g]})
 print('Validated family',f,flush=True)
result['familyout_procedure']={'28':metrics(oof28,allids),'50':metrics(oof50,allids)}
re=np.abs(random_oof-truthleaf[None]);rt=np.einsum('l,blmk->bmk',np.array([len(ix)/280 for ix in strata]),random_oof)
result['familyout_random50']={'within_leaf_mae_mean_pp':(re.mean((1,2))*100).mean(0).tolist(),'aggregate_mae_mean_pp':(np.abs(rt-truth[None]).mean(1)*100).mean(0).tolist()}
result['fixed_random50_heldout'],_=random_eval(k50,hold,9010)
# Paired family bootstrap: 50 minus 28, negative means improvement.
fd=[]
for f in families:
 ids=[i for i,m in enumerate(models) if fam(m)==f];fd.append(100*(np.abs(oof50[:,ids]-truthleaf[:,ids])-np.abs(oof28[:,ids]-truthleaf[:,ids])).mean((0,1)))
fd=np.array(fd);rng=np.random.default_rng(9010);boot=fd[rng.integers(0,len(fd),size=(10000,len(fd)))].mean(1)
result['family_balanced_leaf_error_delta50_minus28']={'mean_pp':fd.mean(0).tolist(),'bootstrap95_pp':np.quantile(boot,[.025,.975],axis=0).tolist(),'note':'approximate; families treated exchangeable; previously inspected data'}
result['folds']=folds
# Selection leakage check: change ONLY held-out outcomes and recompute entire final selection.
saved=Y[:,hold,:].copy();Y[:,hold,:]=np.random.default_rng(98).random(saved.shape);mut,mutk,_=fit(dev,50);Y[:,hold,:]=saved
serialize=lambda p:[[(a,tuple(g)) for a,g in groups] for groups in p]
assert serialize(mut)==serialize(fixed50) and mutk==k50
selection=[]
for j,groups in enumerate(fixed50):
 for a,mem in groups:selection.append({'leaf':leaves[j],'token':tokens[a],'cluster_size':len(mem),'leaf_size':len(strata[j]),'weight':len(mem)/280,'leaf_weight':len(mem)/len(strata[j]),'members':[tokens[i] for i in mem]})
assert len(selection)==50 and len({s['token'] for s in selection})==50 and len({s['leaf'] for s in selection})==28
assert sorted(t for s in selection for t in s['members'])==tokens
assert abs(sum(s['weight'] for s in selection)-1)<1e-10
checks={'unique_scenarios':50,'covered_leaves':28,'clusters_partition_280':True,'weights_sum':sum(s['weight'] for s in selection),'reproduced_fixed28':True,'heldout_mutation_no_effect':True,'no_gpu':True}
(O/'checks.json').write_text(json.dumps(checks,indent=2));(O/'verification.json').write_text(json.dumps(result,indent=2));(O/'proxy_set.json').write_text(json.dumps(selection,indent=2));(O/'proxy_tokens.txt').write_text(''.join(s['token']+'\n' for s in selection))
with (O/'proxy_set.csv').open('w') as f:
 w=csv.DictWriter(f,fieldnames=['leaf','token','cluster_size','leaf_size','weight','leaf_weight']);w.writeheader();w.writerows({k:s[k] for k in w.fieldnames} for s in selection)
with (O/'leaf_comparison.csv').open('w') as f:
 w=csv.writer(f);w.writerow(['leaf','n50','fixed28_heldout_DS','fixed50_heldout_DS','fixed28_heldout_SR','fixed50_heldout_SR','oof28_DS','oof50_DS','oof28_SR','oof50_SR'])
 for j,l in enumerate(leaves):
  a=100*np.abs(l28[j,hold]-truthleaf[j,hold]).mean(0);b=100*np.abs(l50[j,hold]-truthleaf[j,hold]).mean(0);c=100*np.abs(oof28[j]-truthleaf[j]).mean(0);d=100*np.abs(oof50[j]-truthleaf[j]).mean(0);w.writerow([l,k50[j],a[0],b[0],a[1],b[1],c[0],d[0],c[1],d[1]])
np.savez(O/'predictions.npz',models=models,leaves=leaves,truthleaf=truthleaf,fixed28=l28,fixed50=l50,oof28=oof28,oof50=oof50)
fig,axs=plt.subplots(1,2,figsize=(12,4));x=np.arange(28)
for k,ax in enumerate(axs):
 ax.plot(x,100*np.abs(oof28-truthleaf).mean(1)[:,k],'o-',ms=3,label='28 scenarios');ax.plot(x,100*np.abs(oof50-truthleaf).mean(1)[:,k],'o-',ms=3,label='50 scenarios');ax.set_xticks(x,leaves,rotation=90);ax.set_ylabel('Within-leaf MAE (pp)');ax.set_title(['DS','SR'][k]);ax.legend();ax.grid(alpha=.2)
fig.suptitle('Family-out validation: selection procedure, not a single fixed panel');fig.tight_layout();fig.savefig(O/'leaf_comparison.png',dpi=180);fig.savefig(O/'leaf_comparison.pdf');plt.close(fig)
print(json.dumps({k:v for k,v in result.items() if k not in ('folds','selection_models','heldout_models')},indent=2),flush=True)
