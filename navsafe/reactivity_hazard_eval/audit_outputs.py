#!/usr/bin/env python3
import argparse,csv,json,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parent))
from audit_trace import validate

def rows(path): return [x for x in csv.reader(open(path),delimiter='\t') if x and not x[0].startswith('#')]
def main():
 p=argparse.ArgumentParser(); p.add_argument('--root',default='/avl-west/navsafe_eval/reactivity_hazard_outputs/20260913-v1'); p.add_argument('--campaign-root',default='/avl-west/navsafe_eval/reactivity_hazard_eval/20260913-v1'); a=p.parse_args()
 models=rows(Path(a.campaign_root)/'models.tsv'); cells=json.load(open(Path(a.campaign_root)/'cells.json'))
 missing=[]; bad=[]; ok=0
 for model in models:
  slug=model[0]
  for c in cells:
   out=Path(a.root)/slug/c['leaf']/c['token']/c['event']; trace=out/'reactivity_trace.zip'; metrics=out/'navsafe_metrics.json'; log=out/'eval.log'
   if not trace.exists() or not metrics.exists() or not log.exists(): missing.append(str(out)); continue
   errors=validate(trace)
   try:
    d=json.load(open(metrics)); score=d.get('metrics',{}).get('driving_score')
    if d.get('status')!='scored' or type(score) not in (int,float): errors.append(f'navsafe status={d.get("status")} score={score}')
   except Exception as e: errors.append('metrics '+repr(e))
   if '[eval_py123d] DONE.' not in log.read_text(errors='replace'): errors.append('DONE marker missing')
   if errors: bad.append({'path':str(out),'errors':errors})
   else: ok+=1
 result={'expected':len(models)*len(cells),'ok':ok,'missing':len(missing),'bad':len(bad),'complete':not missing and not bad,'missing_examples':missing[:20],'bad_examples':bad[:20]}
 print(json.dumps(result,indent=2,sort_keys=True)); raise SystemExit(0 if result['complete'] else 1)
if __name__=='__main__': main()
