import hashlib,json,subprocess,tarfile
from pathlib import Path
import numpy as np
from nexussim.navsafe.editing.recipe import load_recipe,edits_from_recipe_file
from nexussim.traffic.authored_path import AuthoredMotion
ROOT=Path('/avl-west/navsafe_eval/editor_smoke/20260911-c1-c2-drivor-v1')
repo=Path('/hugsim-storage/NexusSim')
rows=[];report=[]
for src in sorted((ROOT/'unpacked').glob('*/*/*/*.yaml')):
 r=load_recipe(src,verify=True)
 token=src.parents[1].name.split('_')[-1];event=src.parent.name;variant=src.stem
 dst=ROOT/'recipes'/token/event/src.name;dst.parent.mkdir(parents=True,exist_ok=True)
 changes=[];horizon=(r.ego.replay_frames+200)*r.frames.dt_s
 for name,a in r.actors.items():
  p=a.policy
  if p.get('kind')!='authored_path':continue
  old_path=np.array(p['path_polyline'],dtype=float);old=AuthoredMotion(p)
  if p['event_kind']!='vru_cross':
   required=max(0,horizon-float(p['onset_s']))*float(p['speed'])+float(p['speed'])*5
   extra=max(0,required-old.arc[-1])
   if extra>1e-6:
    tangent=old_path[-1]-old_path[-2];tangent/=np.linalg.norm(tangent[:2]);new=old_path[-1]+tangent*extra
    p['path_polyline']=[*p['path_polyline'],new.tolist()]
    changes.append({'actor':name,'tail_added_m':float(extra),'old_length_m':float(old.arc[-1]),'new_length_m':float(required)})
   new=AuthoredMotion(p)
   # The entire original path and its motion prefix stay untouched.
   assert np.array_equal(np.array(p['path_polyline'])[:len(old_path)],old_path)
   for t in np.arange(0,horizon+.01,.1):
    s=new.sample(float(t))
    assert not s['exhausted'],(src,t)
    if not old.sample(float(t))['exhausted']:assert np.allclose(s['position'],old.sample(float(t))['position'])
 r.selection={**r.selection,'smoke_eval_frames':200,'preparation':'tail_extension_only','source_zip':src.parents[2].name}
 dst.write_text(r.to_yaml());ready,edits=edits_from_recipe_file(dst)
 assert len(edits)>0
 report.append({'source':str(src),'recipe':str(dst),'source_sha256':hashlib.sha256(src.read_bytes()).hexdigest(),'ready_sha256':hashlib.sha256(dst.read_bytes()).hexdigest(),'changes':changes,'actor_count':len(ready.actors),'edits_count':len(edits),'checksums_verified':True,'horizon_s':horizon})
 if variant=='event':rows.append({'leaf':r.leaf,'token':token,'event':event,'recipe':str(dst),'baseline':str(dst.with_name('baseline.yaml')),'data_root':str(next(base/token/'arrow' for base in [Path('/avl-west/navsafe_eval/dataset'),Path('/avl-west/navsafe_dev/full_test_mirror')] if (base/token/'arrow').is_dir())),'replay_frames':r.ego.replay_frames,'eval_frames':200,'enable_vis':True})
assert len(rows)==6 and len(report)==12
(ROOT/'cells.json').write_text(json.dumps(rows,indent=2));(ROOT/'preparation_report.json').write_text(json.dumps(report,indent=2))
# Snapshot current runtime, including uncommitted authored_path registration.
files=subprocess.check_output(['git','ls-files','-z'],cwd=repo).decode().split('\0')
files += ['nexussim/traffic/authored_path.py','nexussim/traffic/timed_cut_in.py','nexussim/evaluation/perturbation.py','nexussim/navsafe/experiment3/proxy_events.py']
with tarfile.open(ROOT/'runtime.tar.gz','w:gz') as archive:
 for name in sorted(set(files)):
  if name and (repo/name).is_file():archive.add(repo/name,arcname=name,recursive=False)
(ROOT/'runtime_provenance.json').write_text(json.dumps({'base_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip(),'working_tree_status':subprocess.check_output(['git','status','--short'],cwd=repo,text=True),'sha256':hashlib.sha256((ROOT/'runtime.tar.gz').read_bytes()).hexdigest()},indent=2))
print(json.dumps({'recipes_verified':len(report),'event_cells':len(rows),'tail_extensions':[x for x in report if x['changes']]},indent=2))
