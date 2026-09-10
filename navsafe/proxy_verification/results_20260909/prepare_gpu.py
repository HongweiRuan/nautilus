import pathlib,json,concurrent.futures as cf, importlib.util,sys,pyarrow.ipc as ipc,yaml
P=pathlib.Path('/root/proxy_verification_20260909');out=P/'gpu';out.mkdir(exist_ok=True)
spec=importlib.util.spec_from_file_location('proxy_autoselect','/hugsim-storage/NexusSim/nexussim/navsafe/editing/autoselect.py');mod=importlib.util.module_from_spec(spec);sys.modules[spec.name]=mod;spec.loader.exec_module(mod)
sel=json.load(open(P/'proxy_set.json'));meta={t:r['leaf'] for r in sel for t in r['members']}
def read(t):
 try:
  roots=[pathlib.Path('/avl-west/navsafe_eval/dataset')/t,pathlib.Path('/avl-west/navsafe_dev/full_test_mirror')/t]
  b=next((p for p in roots if (p/'manifest.json').is_file() and len(list((p/'arrow/logs').glob('**/ego_state_se3.arrow')))==1 and len(list(p.glob('*.usdz')))>=4),None)
  if b is None:raise ValueError('bundle/arrow/4 usdz missing')
  logs=list((b/'arrow/logs').glob('**/ego_state_se3.arrow'))
  if len(logs)!=1:raise ValueError('expected exactly one ego log')
  with logs[0].open('rb') as f:
   reader=ipc.open_file(f);n=sum(reader.get_batch(i).num_rows for i in range(reader.num_record_batches))
  choice=mod.resolve_recipe(b/'arrow');h=20
  if choice.path:
   d=yaml.safe_load(choice.path.read_text());h=int(d.get('replay_frames',d.get('ego',{}).get('replay_frames',8)))
  return {'token':t,'leaf':meta[t],'handoff':h,'data_root':str(b/'arrow'),'recipe':str(choice.path) if choice.path else None,'nurec_work_dir':None,'ego_frames':n,'bundle':str(b),'arms_run':['base','latp0.5']}
 except Exception as e:return {'token':t,'error':str(e)}
with cf.ThreadPoolExecutor(max_workers=16) as pool:rows=list(pool.map(read,sorted(meta)))
fail=[r for r in rows if 'error' in r];(out/'preflight.json').write_text(json.dumps({'checked':len(rows),'failures':fail},indent=2))
leaves={}
for r in rows:
 if 'error' not in r:leaves.setdefault(r.pop('leaf'),{'picked':[]})['picked'].append(r)
(out/'selection.json').write_text(json.dumps({'grid':{'arms':[{'id':'base','lat':0,'lon':0,'yaw':0},{'id':'latp0.5','lat':.5,'lon':0,'yaw':0}]},'leaves':leaves},indent=2))
print('GPU input preflight',len(rows),'failures',len(fail));print(json.dumps(fail[:15]))
