#!/usr/bin/env python3
import argparse, json, math, zipfile
from pathlib import Path

def rows(z, name):
    return [json.loads(x) for x in z.read(name).splitlines() if x]

def validate(path, *, condition='hazard'):
    path=Path(path); errors=[]
    if not path.is_file() or path.stat().st_size == 0: return ['missing trace ZIP']
    try:
      with zipfile.ZipFile(path) as z:
        bad=z.testzip()
        if bad: errors.append('CRC failure: '+bad)
        names=set(z.namelist())
        required={'manifest.json','completion.json','intervention.jsonl','ego_states.jsonl','actor_states.jsonl','model_queries.jsonl','plans.jsonl','controls.jsonl','safety_events.jsonl'}
        errors += ['missing '+x for x in sorted(required-names)]
        if errors: return errors
        m=json.loads(z.read('manifest.json')); c=json.loads(z.read('completion.json'))
        ego=rows(z,'ego_states.jsonl'); actors=rows(z,'actor_states.jsonl'); queries=rows(z,'model_queries.jsonl'); plans=rows(z,'plans.jsonl'); controls=rows(z,'controls.jsonl'); intervention=rows(z,'intervention.jsonl')
        if m.get('condition') != condition: errors.append(f'condition={m.get("condition")}')
        if m.get('simulation',{}).get('enable_vis') is not False: errors.append('vis enabled')
        if m.get('storage') != {'buffering':'memory_until_finalize','pvc_writes':1,'images_recorded':False}: errors.append('storage contract mismatch')
        if any(any(k in x.lower() for k in ('image','camera','mask','.png','.jpg')) for x in names): errors.append('image payload present')
        if c.get('trace_complete') is not True: errors.append('trace_complete=false')
        total=c.get('metrics_snapshot',{}).get('total_frames')
        if not isinstance(total,int) or len(ego)!=total: errors.append(f'ego frames {len(ego)} != total {total}')
        if len(controls)!=len(ego): errors.append('control/frame count mismatch')
        if not actors: errors.append('no actor states')
        if not queries or len(queries)!=len(plans): errors.append('query/plan count mismatch')
        if [q.get('query_id') for q in queries] != [p.get('query_id') for p in plans]: errors.append('query/plan IDs mismatch')
        defs=[x for x in intervention if x.get('kind')=='definition' and x.get('enabled')]
        event_defs=[x for x in defs if x.get('event_kind') and isinstance(x.get('configured_onset_s'),(int,float))]
        onsets=[x for x in intervention if x.get('kind')=='actual_onset']
        if not defs: errors.append('no enabled intervention definition')
        if not event_defs: errors.append('no timed event definition')
        expected={(x.get('actor_id'),x.get('event_kind'),float(x['configured_onset_s'])) for x in event_defs}
        actual={(x.get('actor_id'),x.get('event_kind'),float(x['configured_onset_s'])) for x in onsets
                if isinstance(x.get('configured_onset_s'),(int,float))}
        # A policy-attributed crash can legitimately end the episode before a
        # late authored event starts.  The trace is complete in that case; it
        # is simply ineligible for a post-onset response curve.  Keep infra
        # failures and unexplained missing onsets fatal.
        last_time=max((x.get('time_s') for x in ego
                       if isinstance(x.get('time_s'),(int,float))),default=-math.inf)
        termination=c.get('termination') or {}
        early_policy_end=termination.get('policy_attributed') is True
        permitted_missing={x for x in expected-actual
                           if early_policy_end and last_time+1e-6 < x[2]}
        missing=(expected-actual)-permitted_missing
        unexpected=actual-expected
        if missing or unexpected:
            errors.append(
                f'onset identities missing={sorted(missing,key=str)} '
                f'unexpected={sorted(unexpected,key=str)}')
        for x in onsets:
            a=x.get('actual_onset_s'); b=x.get('configured_onset_s')
            if not all(isinstance(v,(int,float)) and math.isfinite(v) for v in (a,b)) or abs(a-b)>1e-6: errors.append(f'onset mismatch {a} vs {b}')
    except Exception as e: errors.append(type(e).__name__+': '+str(e))
    return errors

def main():
    p=argparse.ArgumentParser(); p.add_argument('trace'); p.add_argument('--condition',default='hazard'); a=p.parse_args()
    errors=validate(a.trace,condition=a.condition)
    print(json.dumps({'path':a.trace,'ok':not errors,'errors':errors},sort_keys=True))
    raise SystemExit(bool(errors))
if __name__=='__main__': main()
