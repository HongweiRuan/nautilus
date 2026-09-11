import hashlib,json,os
from pathlib import Path
from nexussim.navsafe.editing.recipe import edits_from_recipe_file
from nexussim.traffic.authored_path import AuthoredMotion
root=Path(os.environ['INPUT_ROOT'])
provenance=json.loads((root/'runtime_provenance.json').read_text())
assert hashlib.sha256((root/'runtime.tar.gz').read_bytes()).hexdigest()==provenance['sha256']
rows=json.loads((root/'cells.json').read_text());assert len(rows)==6
for row in rows:
 assert Path(row['data_root']).is_dir()
 for variant in ['recipe','baseline']:
  recipe,edits=edits_from_recipe_file(row[variant]);assert edits
  assert recipe.ego.replay_frames==row['replay_frames']
  for actor in recipe.actors.values():
   if actor.policy.get('kind')!='authored_path':continue
   motion=AuthoredMotion(actor.policy)
   for i in range(row['replay_frames']+row['eval_frames']+1):
    state=motion.sample(i*recipe.frames.dt_s)
    assert actor.policy['event_kind']=='vru_cross' or not state['exhausted']
print('PASS: six events and six baselines; hashes, asset resolution, motion horizon, runtime snapshot')
