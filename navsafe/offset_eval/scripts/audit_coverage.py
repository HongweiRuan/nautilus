import os,json,collections,datetime,concurrent.futures
root="/avl-west/runs/20260905-handoff-perturb-demo/eval/seed0"
sel=json.load(open("/avl-west/runs/20260905-handoff-perturb-demo/tooling/selection.json"))
arms=[a["id"] for a in sel["grid"]["arms"]]
cells=[(leaf,p["token"],arm) for leaf,b in sel["leaves"].items() for p in b["picked"] for arm in p.get("arms_run",arms)]
def scan(cell):
 leaf,token,arm=cell;p=f"{root}/{leaf}/{token}/{arm}";result={}
 try:
  for e in os.scandir(p):
   if not e.is_dir(): continue
   result[e.name]={"directories":1,"offset_directories":int(arm!="base"),"metrics":int(os.path.isfile(e.path+"/navsafe_metrics.json")),"plans":int(os.path.isfile(e.path+"/plan_records.json"))}
 except FileNotFoundError: pass
 return result
stats=collections.defaultdict(collections.Counter)
with concurrent.futures.ThreadPoolExecutor(max_workers=16) as ex:
 for r in ex.map(scan,cells):
  for m,s in r.items(): stats[m].update(s)
print(json.dumps({"root":root,"utc":datetime.datetime.now(datetime.timezone.utc).isoformat(),"expected_cells_per_model":len(cells),"scope":"All selected scenarios and configured arms; files counted, success not inferred from existence","models":stats},indent=2),flush=True)
