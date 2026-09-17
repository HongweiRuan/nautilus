"""Validate frame alignment and retain raw inputs for per-scenario MC-return plots."""
import json,sys
from pathlib import Path
import numpy as np
from nexussim.navsafe.trace import from_eval
p=Path(sys.argv[1]); data_root=sys.argv[2]
for name in ('plan_records.json','vehicle_states.npy','driving_score_summary.csv','navsafe_metrics.json'):
 assert (p/name).is_file(),f'missing {name}'
r=json.loads((p/'plan_records.json').read_text());m=json.loads((p/'navsafe_metrics.json').read_text())
assert r['handoff_frame']==0, 'recipe overrode zero replay'
assert abs(r['sim_dt']-.1)<1e-9
sd=from_eval.scenario_from_arrow(data_root)
ego_id=(sd.get('metadata',{}) or {}).get('sdc_id') or sd.get('sdc_id')
st=sd['tracks'][ego_id]['state'];log=np.asarray(st['position'])[:,:2];lh=float(np.asarray(st['heading']).reshape(-1)[0]);lc,ls=np.cos(lh),np.sin(lh);lr=np.array([[lc,-ls],[ls,lc]])
# A valid episode may terminate before its first policy prediction.  It still
# contributes an explicit missing CL point; use the logged frame-0 pose only
# as the coordinate-frame origin because there is no executed state to map.
ref=next((q for q in r['predictions'] if q['frame']==0),None)
if ref is None:
 a=np.array(log[0]);h=lh
else:
 a=np.array(ref['ego_position'][:2]);h=ref['ego_heading']
c,s=np.cos(h),np.sin(h);rot=np.array([[c,-s],[s,c]])
# Each trajectory uses the identical physical frame-0 vehicle pose, allowing
# scenario loader world recentering without mixing coordinate conventions.
result={'seed':int(sys.argv[3]),'model':sys.argv[4],'reference_frame':0,'dt':.1,'gamma':.99,'rollout_limit_s':4,'termination':m.get('termination'),'reference_position':a.tolist(),'reference_heading':h,'states':{}}
for f in (20,40):
 result['states'][str(f)]={'t_s':f*.1,'ol_log_xy':((log[f]-log[0])@lr).tolist(),'cl_xy':None}
 if len(r['executed'])>=f:
  q=r['executed'][f-1];assert q['frame']==f-1
  result['states'][str(f)]['cl_xy']=((np.array(q['position'][:2])-a)@rot).tolist()
result['mc_status']='pending DS-prefix validation; never substitute episode DS for MC return'
from types import SimpleNamespace
from nexussim.navsafe.scoring import route,metrics
try:
    saved=m;warm=0;end=saved['termination']['frame'];reason=saved['termination']['reason'];GAMMA=.99
    if reason in ('hold_satisfied','red_light_run','illegal_turn'):
        raise ValueError('special terminal DS rule requires separate prefix handling')
    route_xy=log
    ego_xy=np.load(p/'vehicle_states.npy')[:,:2]
    drivable=bool(sd.get('map_features'))
    pf=from_eval.read_per_frame_epdms(p)
    rebuilt=[]
    for j,xy in enumerate(ego_xy):
      row=pf.get(j,{})
      contacts=[]
      if j>=warm and row.get('COLL',0)>0:
        if not row.get('COLL_KIND'): raise ValueError('contact kind missing; cannot reconstruct exact penalty')
        contacts=[{'agent_id':row.get('COLL_ID',''),'kind':row['COLL_KIND'],'at_fault':row.get('COLL_AF',0)>0}]
      rebuilt.append({'phase':'scored' if j>=warm else 'warmup','ego_x':float(xy[0]),'ego_y':float(xy[1]),
        'on_drivable':not drivable or row.get('DAC',1)>=1,'contacts':contacts,
        'signal_state':('red' if row['TL']<1 else 'unknown') if 'TL' in row else ''})
    run=SimpleNamespace(route_xy=route_xy,ego_xy=ego_xy,frames=rebuilt,drivable_known=drivable)
    progress=route.route_progress(run.route_xy,run.ego_xy).per_frame_pct
    frames=run.frames[warm:end+1]
    if not frames: raise ValueError('empty scored window')
    pairs={(c['agent_id'],c['kind']) for f in frames for c in f['contacts'] if c['at_fault']}
    saved_contacts={c['channel']:c['count'] for c in saved['driving_score_breakdown']['channels'] if c['channel'].startswith('collisions_') and c['count']}
    # With exactly one observed fault event and one stored collision, the
    # saved channel resolves the participant class (e.g. front impact on a
    # pedestrian) while the CSV still supplies the event's actual timestamp.
    single_contact_channel=(next(iter(saved_contacts)) if len(pairs)==1 and sum(saved_contacts.values())==1 else None)
    # Prefix event counters; do not reclassify prefixes as terminated episodes.
    ds=[float(progress[warm-1]) if warm else 0.0]
    for i in range(len(frames)):
      prefix=frames[:i+1]
      counts=metrics.infractions_from_trace(prefix,at_fault_only=True)
      if single_contact_channel and any(c.get('at_fault') for f in prefix for c in f['contacts']):
        counts={k:v for k,v in counts.items() if not k.startswith('collisions_')}
        counts[single_contact_channel]=1
      red=np.array([f.get('signal_state')=='red' for f in prefix],dtype=bool)
      counts['red_light']=int(np.sum(red & ~np.r_[False,red[:-1]]))
      penalty=1.0
      for channel,coef in metrics.PENALTY_COEFFICIENTS.items(): penalty*=coef**counts.get(channel,0)
      if run.drivable_known:
        xy=[[f['ego_x'],f['ego_y']] for f in prefix]
        penalty*=1-route.outside_route_lanes_pct(xy,[f['on_drivable'] for f in prefix])/100
      completion=progress[warm+i]
      if warm+i==end and reason=='goal_reached': completion=100.0
      ds.append(max(0.0,float(completion*penalty)))
    expected=saved['metrics']['driving_score']
    gap=abs(ds[-1]-expected)
    if gap>.00051: raise ValueError(f'final DS mismatch: reconstructed={ds[-1]}, stored={expected}')
    reward=np.diff(ds); ret=np.zeros(len(reward)+1)
    for i in range(len(reward)-1,-1,-1): ret[i]=reward[i]+GAMMA*ret[i+1]
    assert abs(reward.sum()-(ds[-1]-ds[0]))<1e-8
    undiscounted=np.r_[np.cumsum(reward[::-1])[::-1],0]
    assert np.max(np.abs(undiscounted-(ds[-1]-np.array(ds))))<1e-8
    result['ds']=ds
    result['rewards']=reward.tolist()
    result['mc_returns']=ret.tolist()
    result['final_ds_error']=gap
    result['mc_status']='validated'
    for f in (20,40):
        if result['states'][str(f)]['cl_xy'] is not None and f<len(ret):
            result['states'][str(f)]['mc_return']=float(ret[f])
except Exception as exc:
    result['mc_status']='unvalidated'
    result['mc_error']=str(exc)

(p/'heatmap_episode.json').write_text(json.dumps(result,indent=2))
print('HEATMAP_AUDIT',sys.argv[4],sys.argv[3],len(r['executed']),m.get('termination'))
