import os
os.environ.update(OMP_NUM_THREADS='1',OPENBLAS_NUM_THREADS='1',MKL_NUM_THREADS='1',MPLBACKEND='Agg')
import json,pathlib,concurrent.futures as cf,hashlib,datetime,csv
import numpy as np
from scipy.stats import spearmanr
import matplotlib.pyplot as plt
P=pathlib.Path('/hugsim-storage/NexusSim/docs/experiments/proxy_verification_20260909');O=P/'proxy28_20260910';O.mkdir(exist_ok=True)
root=pathlib.Path('/avl-west/navsafe_eval/metrics_all')
old=json.loads((P/'proxy_set.json').read_text());tokens=sorted({t for s in old for t in s['members']});assert len(tokens)==280
info=json.loads((P/'proxy27/verification.json').read_text());devnames=info['selection_models'];holdnames=info['evaluation_excluded_models']
models=sorted(devnames+holdnames);assert len(set(models))==16

registry={d['token']:d for d in json.loads(pathlib.Path('/avl-west/navsafe_eval/dataset_manifest.json').read_text())}
oldleaf={t:s['leaf'] for s in old for t in s['members']}
print('Registry coverage',len(set(tokens)&set(registry)),'of 280; missing use prior audited taxonomy',flush=True)
conflicts={t:{'registry':registry[t]['leaves'],'retained_audited_leaf':oldleaf[t]} for t in tokens if t in registry and registry[t]['leaves']!=[oldleaf[t]]}
(O/'taxonomy_discrepancies.json').write_text(json.dumps(conflicts,indent=2))
def readmeta(t):
 p=root/'autovla'/'seed0'/(t+'.json');d=json.loads(p.read_text())['scenario'];d['taxonomy_leaves']=[oldleaf[t]];d['leaf_source']='prior proxy_verification_20260909/proxy_set.json (fixed taxonomy; see taxonomy_discrepancies.json)';return t,d
with cf.ThreadPoolExecutor(max_workers=16) as pool:meta=dict(pool.map(readmeta,tokens))
assert all(len(meta[t]['taxonomy_leaves'])==1 for t in tokens)
leaves=sorted({meta[t]['taxonomy_leaves'][0] for t in tokens},key=lambda l:(l.split('-')[0],int(l.split('-')[1])))
assert len(leaves)==28
strata=[np.array([i for i,t in enumerate(tokens) if meta[t]['taxonomy_leaves'][0]==l]) for l in leaves];weights=np.array([len(ix)/280 for ix in strata])

def readcell(pair):
 m,t=pair;p=root/m/'seed0'/(t+'.json');b=p.read_bytes();d=json.loads(b);v=d.get('metrics') or {}
 assert d.get('status')=='scored',(m,t,d.get('status'))
 assert isinstance(v.get('driving_score'),(int,float)) and np.isfinite(v['driving_score']),(m,t)
 assert v.get('success') in (0,1,True,False),(m,t)
 return {'model':m,'token':t,'seed':'seed0','ds':v['driving_score'],'success':v['success'],'status':d['status'],'sha256':hashlib.sha256(b).hexdigest(),'path':str(p),'source':d.get('source')}
rows=[]
with cf.ThreadPoolExecutor(max_workers=24) as pool:
 for r in pool.map(readcell,[(m,t) for m in models+['pdm_closed'] for t in tokens]):
  rows.append(r)
  if len(rows)%1000==0:print('Read valid cells',len(rows),flush=True)
(O/'snapshot.json').write_text(json.dumps(rows));(O/'scenario_metadata.json').write_text(json.dumps(meta,indent=2))
R={(r['model'],r['token']):r for r in rows};Y=np.array([[[R[m,t]['ds']/100,float(R[m,t]['success'])] for m in models] for t in tokens]);truth=Y.mean(0)
family=lambda m:next((f for f in ('diffusiondrive','mtdrive','recogdrive','simwam') if m.startswith(f)),m)
dev=[models.index(m) for m in devnames];hold=[models.index(m) for m in holdnames]
def feats(ids):
 x=Y[:,ids,:].reshape(280,-1).copy()
 for j,i in enumerate(ids):x[:,2*j:2*j+2]/=np.sqrt(sum(family(models[k])==family(models[i]) for k in ids))
 return x
def select(ids):
 x=feats(ids);return np.array([ix[np.argmin(((x[ix]-x[ix].mean(0))**2).sum(1))] for ix in strata])
a=select(dev);pred=(Y[a]*weights[:,None,None]).sum(0);leaftruth=np.array([Y[ix].mean(0) for ix in strata]);leaferror=100*(Y[a]-leaftruth)
selection=[]
for l,ix,i,w in zip(leaves,strata,a,weights):selection.append({'leaf':l,'token':tokens[i],'weight':float(w),'cluster_size':len(ix),'members':[tokens[j] for j in ix],'method':'within_leaf_k1_centroid','scenario_meta':meta[tokens[i]]})
(O/'proxy_set.json').write_text(json.dumps(selection,indent=2));(O/'proxy_tokens.txt').write_text(''.join(s['token']+'\n' for s in selection))
with (O/'proxy_set.csv').open('w') as f:
 w=csv.DictWriter(f,fieldnames=['leaf','token','weight','cluster_size','method']);w.writeheader();w.writerows({k:s[k] for k in w.fieldnames} for s in selection)
families=sorted({family(m) for m in models});oof=np.zeros_like(pred);oofleaf=np.zeros_like(leaferror);folds=[]
for fam in families:
 train=[i for i,m in enumerate(models) if family(m)!=fam];test=[i for i,m in enumerate(models) if family(m)==fam];aa=select(train)
 oof[test]=(Y[aa][:,test,:]*weights[:,None,None]).sum(0)
 oofleaf[:,test,:]=100*(Y[aa][:,test,:]-leaftruth[:,test,:])
 folds.append({'heldout_family':fam,'tokens':[tokens[i] for i in aa]})
rng=np.random.default_rng(9010);random_total=[];random_leaf=[]
for b in range(1000):
 aa=np.array([rng.choice(ix) for ix in strata]);rp=(Y[aa]*weights[:,None,None]).sum(0)
 random_total.append(np.abs(rp-truth).mean(0)*100);random_leaf.append(np.abs(Y[aa]-leaftruth).mean((0,1))*100)
def score(p,ids):
 e=(p[ids]-truth[ids])*100
 return {'mae_pp':np.abs(e).mean(0).tolist(),'max_error_pp':np.abs(e).max(0).tolist(),'spearman':[float(spearmanr(p[ids,j],truth[ids,j]).statistic) for j in range(2)]}
old27=json.loads((P/'proxy27/proxy_set.json').read_text());oldmap={s['leaf']:s['token'] for s in old27}
result={'created_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'population':280,'leaves':28,'model_count':16,'metric_order':['DS','SR'],'selection_models':devnames,'heldout_models':holdnames,'fixed_all_descriptive':score(pred,list(range(16))),'fixed_development_descriptive':score(pred,dev),'fixed_heldout_retrospective':score(pred,hold),'familyout_procedure':score(oof,list(range(16))),'fixed_within_leaf_mae_pp':np.abs(leaferror).mean((0,1)).tolist(),'fixed_heldout_within_leaf_mae_pp':np.abs(leaferror[:,hold]).mean((0,1)).tolist(),'familyout_within_leaf_mae_pp':np.abs(oofleaf).mean((0,1)).tolist(),'random_total_mae_mean_pp':np.mean(random_total,0).tolist(),'random_within_leaf_mae_mean_pp':np.mean(random_leaf,0).tolist(),'changed_previous_leaves':[s['leaf'] for s in selection if s['leaf'] in oldmap and s['token']!=oldmap[s['leaf']]],'v8_selection':next(s['token'] for s in selection if s['leaf']=='V-8'),'folds':folds,'limitations':['No perturbation validation; baseline only.','Selection uses 11 development models; fixed heldout data were inspected previously.','Single binary outcome cannot generally match within-leaf SR.','Metadata does not establish quantitative density or geometry representativeness.','Source controller/renderer conditions may differ; see source README.']}
(O/'verification.json').write_text(json.dumps(result,indent=2))
with (O/'leaf_diagnostics.csv').open('w') as f:
 w=csv.writer(f);w.writerow(['leaf','token','n','all_DS_MAE_pp','all_SR_MAE_pp','heldout_DS_MAE_pp','heldout_SR_MAE_pp','familyout_DS_MAE_pp','familyout_SR_MAE_pp','scenario_types','has_inserted_actors'])
 for j,s in enumerate(selection):w.writerow([s['leaf'],s['token'],s['cluster_size'],*np.abs(leaferror[j]).mean(0),*np.abs(leaferror[j,hold]).mean(0),*np.abs(oofleaf[j]).mean(0),json.dumps(meta[s['token']].get('scenario_types')),meta[s['token']].get('has_inserted_actors')])
with (O/'model_scores.csv').open('w') as f:
 w=csv.writer(f);w.writerow(['model','split','full_DS','proxy_DS','full_SR','proxy_SR'])
 for i,m in enumerate(models):w.writerow([m,'development' if i in dev else 'heldout',100*truth[i,0],100*pred[i,0],100*truth[i,1],100*pred[i,1]])
fig,axs=plt.subplots(1,2,figsize=(10,4))
for k,ax in enumerate(axs):
 ax.scatter(100*leaftruth[:,dev,k].ravel(),100*Y[a][:,dev,k].ravel(),s=12,alpha=.3,label='Development')
 ax.scatter(100*leaftruth[:,hold,k].ravel(),100*Y[a][:,hold,k].ravel(),s=18,alpha=.6,label='Held-out (retrospective)')
 ax.plot([0,100],[0,100],'k--',lw=1);ax.set(xlabel='Full leaf mean (%)',ylabel='Selected scenario score (%)',title=['DS','Success vs leaf SR'][k],xlim=(-3,103),ylim=(-3,103));ax.legend(fontsize=7)
fig.suptitle('Fixed 28-scenario panel: model × leaf comparisons');fig.tight_layout();fig.savefig(O/'within_leaf.png',dpi=180);fig.savefig(O/'within_leaf.pdf');plt.close(fig)
checks={'valid_seed0_cells':len(rows),'models_including_pdm':17,'unique_selected':len(set(a)),'one_per_leaf':all(a[j] in ix for j,ix in enumerate(strata)),'weights_sum':float(weights.sum()),'leaf_sizes':[len(ix) for ix in strata]}
assert len(a)==28 and checks['one_per_leaf'] and abs(weights.sum()-1)<1e-10
(O/'checks.json').write_text(json.dumps(checks,indent=2))
print(json.dumps({k:v for k,v in result.items() if k not in ('folds','selection_models','heldout_models')},indent=2),flush=True)
