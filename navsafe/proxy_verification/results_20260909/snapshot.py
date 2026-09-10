import concurrent.futures as cf, pathlib, json, hashlib, collections, time
root=pathlib.Path('/avl-west/navsafe_eval/metrics_all')
out=pathlib.Path('/root/proxy_verification_20260909');out.mkdir(exist_ok=True)
files=sorted(p for p in root.glob('*/*/*.json') if p.parent.name in ('seed0','seed1024'))
def read(p):
 try:
  b=p.read_bytes();d=json.loads(b);s=d.get('scenario',{});m=d.get('metrics',{})
  return dict(model=p.parts[-3],seed=p.parts[-2],token=p.stem,path=str(p),sha256=hashlib.sha256(b).hexdigest(),status=d.get('status'),leaves=s.get('taxonomy_leaves'),types=s.get('scenario_types'),inserted=s.get('has_inserted_actors'),ds=m.get('driving_score'),success=m.get('success'),termination=d.get('termination'),source=d.get('source'),frames=d.get('frames'))
 except Exception as e:return dict(path=str(p),error=repr(e))
rows=[];t=time.time()
with cf.ThreadPoolExecutor(max_workers=32) as pool:
 for r in pool.map(read,files):
  rows.append(r)
  if len(rows)%500==0:print(len(rows),'/',len(files),'seconds',round(time.time()-t),flush=True)
(out/'snapshot.json').write_text(json.dumps(rows))
counts={}
for r in rows:
 key=r.get('model','ERROR')+'/'+r.get('seed','');c=counts.setdefault(key,dict(n=0,status=collections.Counter(),leaves=collections.Counter()))
 c['n']+=1;c['status'][r.get('status')]+=1;c['leaves'].update(r.get('leaves') or [])
(out/'coverage.json').write_text(json.dumps(counts,indent=2))
for key,c in counts.items():print(key,c['n'],dict(c['status']),len(c['leaves']),flush=True)
print('DONE',len(rows),round(time.time()-t),flush=True)
