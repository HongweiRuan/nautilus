
import pathlib,json,hashlib,csv
import numpy as np
from scipy.stats import spearmanr
P=pathlib.Path('/hugsim-storage/NexusSim/docs/experiments/proxy_verification_20260909')
S=P/'proxy27';O=S/'tinybenchmarks_validation';O.mkdir(exist_ok=True)
raw=(P/'snapshot.json').read_bytes();rows=json.loads(raw);sel=json.load(open(S/'proxy_set.json'))
before=hashlib.sha256((S/'proxy_set.json').read_bytes()).hexdigest()
tokens=sorted(t for s in sel for t in s['members'])
test=['drivor','recogdrive_il','recogdrive_rl','simwam','simwam_rl']
assert len(tokens)==270 and len(set(tokens))==270 and len(sel)==27
assert len({s['leaf'] for s in sel})==27 and all(s['leaf']!='V-8' for s in sel)
assert abs(sum(s['weight'] for s in sel)-1)<1e-12
r={(x['model'],x['seed'],x['token']):x for x in rows}
def values(seed):
 out=np.empty((270,5,2))
 for i,t in enumerate(tokens):
  for j,m in enumerate(test):
   d=r[m,seed,t];assert d['status']=='scored' and isinstance(d['success'],bool)
   out[i,j]=[d['ds'],100*float(d['success'])]
 return out
idx={t:i for i,t in enumerate(tokens)}
strata=[np.array([idx[t] for t in s['members']]) for s in sel]
weights=np.array([s['weight'] for s in sel]);anchors=[idx[s['token']] for s in sel]
output={'method':'tinyBenchmarks section 5 test-model score estimation; correctness-anchor vanilla estimator, not IRT++','source':'https://arxiv.org/html/2402.14992v2#S5','selection_sha256':before,'snapshot_sha256':hashlib.sha256(raw).hexdigest(),'test_models':test,'test_families':3,'proxy_n':27,'population_n':270,'blind_new_test':False,'perturbation_validated':False,'seeds':{}}
for seed in ['seed0','seed1024']:
 y=values(seed);full=y.mean(axis=0);pred=(y[anchors]*weights[:,None,None]).sum(axis=0)
 rng=np.random.default_rng(20260910);random_mae=[]
 for b in range(1000):
  ii=[rng.choice(ix) for ix in strata];p=(y[ii]*weights[:,None,None]).sum(axis=0)
  random_mae.append(np.abs(p-full).mean(axis=0))
 random_mae=np.array(random_mae)
 result={}
 for j,metric in enumerate(['DS','SR']):
  e=pred[:,j]-full[:,j]
  result[metric]={'mae_pp':float(np.abs(e).mean()),'max_abs_error_pp':float(np.abs(e).max()),'rmse_pp':float(np.sqrt(np.mean(e**2))),'signed_bias_pp':float(e.mean()),'spearman':float(spearmanr(full[:,j],pred[:,j]).statistic),'random_mean_mae_pp':float(random_mae[:,j].mean()),'random_median_mae_pp':float(np.median(random_mae[:,j])),'random_mae_percentiles_2_5_97_5':np.quantile(random_mae[:,j],[.025,.975]).tolist(),'fraction_random_no_worse':float(np.mean(random_mae[:,j]<=np.abs(e).mean()))}
 output['seeds'][seed]=result
 with (O/(seed+'_per_model.csv')).open('w') as f:
  w=csv.writer(f);w.writerow(['model','full_DS','proxy_DS','DS_error_pp','full_SR','proxy_SR','SR_error_pp'])
  for j,m in enumerate(test):w.writerow([m,full[j,0],pred[j,0],pred[j,0]-full[j,0],full[j,1],pred[j,1],pred[j,1]-full[j,1]])
 np.save(O/(seed+'_random_mae.npy'),random_mae)
assert hashlib.sha256((S/'proxy_set.json').read_bytes()).hexdigest()==before
output['selection_unchanged']=True
output['conclusion']='The fixed 27-scene proxy does not demonstrate reliable absolute baseline score estimation or superiority to same-budget stratified random sampling. Ranking is partially retained. This does not test perturbation-response validity.'
(O/'results.json').write_text(json.dumps(output,indent=2))
lines=['# tinyBenchmarks-style validation of the frozen proxy27','',
'CPU-only recomputation from immutable per-scenario results. The 27 anchors and weights were NOT changed. No GPU or simulator execution.','',
'## Literature mapping','',
'tinyBenchmarks section 5 trains/selects on one group of models and estimates full benchmark scores on other models. It compares estimation errors against stratified random sampling and reports ranking correlation. We apply that validation protocol to the previously selected correctness-vector anchors. This is NOT IRT fitting, IRT++, or a replication of their numeric error guarantees. The paper also uses organization-based splits for HELM; our related model variants stay in the same held-out family.','',
'Source: https://arxiv.org/html/2402.14992v2#S5','',
'## Evaluation','',
'- Population: 270 scenarios in 27 leaves, V-8 excluded.','- Fixed proxy: one anchor per leaf, cluster-size weights.','- Test models: DrivoR, ReCogDrive IL/RL, SimWAM base/RL. None formed the anchor feature vectors.','- Reference: exact mean over all 270 existing outcomes, not another sampled estimate.','- Comparator: 1000 random sets, each selecting one scenario per leaf, same weights.','- Seed1024 is a supplementary repeat-seed audit of the same models, not five additional independent models.','',
'| Seed | Metric | Proxy MAE (pp) | Max error (pp) | Spearman | Random mean MAE (pp) | Random median MAE (pp) | Random sets no worse |','|---|---|---:|---:|---:|---:|---:|---:|']
for seed,rr in output['seeds'].items():
 for metric,v in rr.items():lines.append(f"| {seed} | {metric} | {v['mae_pp']:.2f} | {v['max_abs_error_pp']:.2f} | {v['spearman']:.2f} | {v['random_mean_mae_pp']:.2f} | {v['random_median_mae_pp']:.2f} | {v['fraction_random_no_worse']:.1%} |")
lines+=['','## Interpretation','',output['conclusion'],'',
'Do not label a 0.90 correlation as proof of representative absolute scores. This fixed subset is an exploratory diagnostic sample, not yet a validated replacement for the 270-scene benchmark. The paper does not prescribe a universal pass/fail cutoff for driving.','',
'The same test families have been inspected in earlier iterations, so this is a retrospective evaluation, NOT a newly blinded test. There are only five policies in three families; the 1000 random draws do not increase the number of independent test models. Random-draw percentiles are sampling-comparator distributions, not confidence intervals for generalization to all driving tasks.','',
'Existing source-run/renderer-workaround caveats apply. Verification is conditional on the supplied baseline outcomes. GPU testing would only be needed to evaluate new perturbation outcomes, not to compute the baseline evidence above.']
(O/'REPORT.md').write_text('\n'.join(lines)+'\n')
print(json.dumps(output,indent=2))
