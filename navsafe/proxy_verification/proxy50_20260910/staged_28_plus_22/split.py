from pathlib import Path
import json,csv,math
import sys
P=Path(sys.argv[1]) if len(sys.argv)>1 else Path('/Users/hongwei/Desktop/avl/nautilus/navsafe/proxy_verification');O=P/'proxy50_20260910'/'staged_28_plus_22';O.mkdir(exist_ok=True)
panel=json.loads((P/'proxy50_20260910/proxy_set.json').read_text());info=json.loads((P/'proxy50_20260910/verification.json').read_text());rows=json.loads((P/'proxy28_20260910/snapshot.json').read_text());old=json.loads((P/'proxy28_20260910/proxy_set.json').read_text());R={(r['model'],r['token']):r for r in rows};dev=info['selection_models'];hold=info['heldout_models'];models=sorted(dev+hold)
def family(m):return next((f for f in ('diffusiondrive','mtdrive','recogdrive','simwam') if m.startswith(f)),m)
def feature(t):
 v=[]
 for m in dev:
  r=R[m,t];den=math.sqrt(sum(family(mm)==family(m) for mm in dev));v.extend([r['ds']/100/den,float(r['success'])/den])
 return v
stage1=[];stage2=[]
for leaf in [s['leaf'] for s in old]:
 candidates=[s for s in panel if s['leaf']==leaf];members=sorted(t for s in candidates for t in s['members']);xs=[feature(t) for t in members];mu=[sum(x[j] for x in xs)/len(xs) for j in range(len(xs[0]))]
 best=min(candidates,key=lambda s:(sum((a-b)**2 for a,b in zip(feature(s['token']),mu)),s['token']))
 for s in candidates:
  d=dict(s);d['stage']=1 if s['token']==best['token'] else 2;d['stage1_weight']=len(members)/280 if d['stage']==1 else None;d['full50_weight']=s['weight'];(stage1 if d['stage']==1 else stage2).append(d)
for label,data in [('priority28',stage1),('additional22',stage2),('full50_execution_order',stage1+stage2)]:
 (O/(label+'.json')).write_text(json.dumps(data,indent=2));(O/(label+'_tokens.txt')).write_text(''.join(s['token']+'\n' for s in data))
 with (O/(label+'.csv')).open('w') as f:
  w=csv.DictWriter(f,fieldnames=['stage','leaf','token','stage1_weight','full50_weight','cluster_size','leaf_size']);w.writeheader();w.writerows({k:s[k] for k in w.fieldnames} for s in data)
def metrics(data,ids,mode):
 abswhole=[[],[]];absleaf=[[],[]]
 for m in ids:
  pred=[0.,0.];true=[0.,0.]
  for o in old:
   leaf=o['leaf'];ts=o['members'];gt=[sum(R[m,t]['ds'] for t in ts)/len(ts),100*sum(float(R[m,t]['success']) for t in ts)/len(ts)];ss=[s for s in data if s['leaf']==leaf]
   est=[sum((1 if mode=='single' else s['cluster_size']/s['leaf_size'])*([R[m,s['token']]['ds'],100*float(R[m,s['token']]['success'])][k]) for s in ss) for k in range(2)]
   for k in range(2):pred[k]+=len(ts)/280*est[k];true[k]+=len(ts)/280*gt[k];absleaf[k].append(abs(est[k]-gt[k]))
  for k in range(2):abswhole[k].append(abs(pred[k]-true[k]))
 return {'aggregate_mae_pp':[sum(v)/len(v) for v in abswhole],'within_leaf_mae_pp':[sum(v)/len(v) for v in absleaf]}
result={'metric_order':['DS','SR'],'selection':'nearest full-leaf centroid among existing50 anchors, development models only','fixed_priority28_heldout_retrospective':metrics(stage1,hold,'single'),'fixed_priority28_all_descriptive':metrics(stage1,models,'single'),'fixed_full50_heldout_retrospective':metrics(panel,hold,'cluster'),'original28_overlap':len({s['token'] for s in old}&{s['token'] for s in stage1}),'checks':{'priority28':len(stage1),'additional22':len(stage2),'priority_leaf_count':len({s['leaf'] for s in stage1}),'disjoint':not bool({s['token'] for s in stage1}&{s['token'] for s in stage2}),'union_equals_original50':{s['token'] for s in stage1+stage2}=={s['token'] for s in panel},'stage1_weight_sum':sum(s['stage1_weight'] for s in stage1),'full50_weight_sum':sum(s['full50_weight'] for s in stage1+stage2)}}
assert len(stage1)==28 and len(stage2)==22 and result['checks']['priority_leaf_count']==28 and result['checks']['disjoint'] and result['checks']['union_equals_original50']
for a,b in zip(result['fixed_full50_heldout_retrospective']['aggregate_mae_pp'],info['fixed_heldout_retrospective']['50']['aggregate_mae_pp']):assert abs(a-b)<1e-8
(O/'verification.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
