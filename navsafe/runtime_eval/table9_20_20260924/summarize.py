#!/usr/bin/env python3
import csv, json, re, statistics
from pathlib import Path

root = Path('/avl-west/navsafe_runtime/table9_drivor_20_20260924')
rows=[]
for f in sorted((root/'_workers').glob('w*/episodes.tsv')):
    worker=f.parent.name
    for line in f.read_text().splitlines():
        token, model, seed, start_ns, wall_s, rc = line.split('\t')
        log=root/model/f'seed{seed}'/(token+'.log')
        txt=log.read_text(errors='replace') if log.exists() else ''
        m=re.search(r'\[PROFILE\] eval loop stages over (\d+) frames \(sum=([0-9.]+)s, ([0-9.]+) ms/frame\)', txt)
        done='[eval_py123d] DONE.' in txt
        rows.append(dict(worker=worker,scenario=token,wall_s=float(wall_s),rc=int(rc),done=done,
                         frames=int(m.group(1)) if m else None,
                         steady_ms=float(m.group(3)) if m else None))

def pct(xs,p):
    ys=sorted(xs); x=(len(ys)-1)*p; lo=int(x); hi=min(lo+1,len(ys)-1); a=x-lo
    return ys[lo]*(1-a)+ys[hi]*a

ok=[r for r in rows if r['rc']==0 and r['done']]
wall=[r['wall_s'] for r in ok]
steady=[r['steady_ms'] for r in ok if r['steady_ms'] is not None]
starts=[float(x) for f in (root/'_workers').glob('w*/renderer_startup_s.txt') for x in f.read_text().split()]
gpu=[]
for f in (root/'_workers').glob('w*/gpu_samples.csv'):
    for line in f.read_text().splitlines():
        a=[x.strip() for x in line.split(',')]
        if len(a)>=7:
            gpu.append((f.parent.name,int(a[1]),float(a[4])))
peaks={}
for w,i,m in gpu: peaks[(w,i)]=max(m,peaks.get((w,i),0))
out={
  'episodes_found':len(rows),'episodes_valid':len(ok),'episodes_expected':20,
  'episode_wall_s': {'median':statistics.median(wall) if wall else None,'p90':pct(wall,.9) if wall else None,'maximum':max(wall) if wall else None},
  'steady_state_ms_per_frame': {'median':statistics.median(steady) if steady else None,'p90':pct(steady,.9) if steady else None},
  'renderer_startup_s': {'n':len(starts),'median':statistics.median(starts) if starts else None,'minimum':min(starts) if starts else None,'maximum':max(starts) if starts else None},
  'peak_gpu_mib_by_worker_device': {f'{w}:gpu{i}':v for (w,i),v in sorted(peaks.items())},
  'episodes':rows,
}
(root/'table9_summary.json').write_text(json.dumps(out,indent=2)+'\n')
print(json.dumps(out,indent=2))
