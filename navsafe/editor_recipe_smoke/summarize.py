import json,sys
from pathlib import Path
root=Path(sys.argv[1]);inputs=json.loads((root.parent/'cells.json').read_text());rows=[]
for cell in inputs:
 out=root/cell['leaf']/cell['token']/cell['event']/'drivor'
 log=(out/'eval.log').read_text(errors='replace') if (out/'eval.log').exists() else ''
 code=int((out/'exit_code.txt').read_text()) if (out/'exit_code.txt').exists() else None
 images=sum(1 for p in out.rglob('*.png') if p.stat().st_size>0)
 loaded='scenario edit: recipe editor/'+cell['token']+'/'+cell['event']+'/' in log
 entry={k:cell[k] for k in ['leaf','token','event']}
 entry.update(output=str(out),exit_code=code,done='[eval_py123d] DONE.' in log,recipe_loaded=loaded,vis_images=images,metrics=(out/'navsafe_metrics.json').exists(),plans=(out/'plan_records.json').exists())
 entry['status']='pending' if code is None else ('passed' if code==0 and entry['done'] and loaded and images>0 and entry['metrics'] and entry['plans'] else 'failed')
 rows.append(entry)
Path(sys.argv[2]).write_text(json.dumps(rows,indent=2));print(json.dumps([{k:r[k] for k in ['leaf','event','status','vis_images']} for r in rows]))
