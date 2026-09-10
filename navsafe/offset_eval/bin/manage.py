#!/usr/bin/env python3
"""Render, stage, inspect or submit model/scene-partition Jobs. Requires PyYAML."""
import argparse, copy, hashlib, json, shlex, subprocess, sys, tarfile, tempfile
from pathlib import Path
import yaml
ROOT=Path(__file__).resolve().parents[1]
CFG=json.loads((ROOT/'config/campaign.json').read_text())

def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)

def contains_config(actual, expected):
    """Compare authored fields while allowing API defaults and injected fields."""
    if isinstance(expected, dict):
        return isinstance(actual, dict) and all(
            k in actual and contains_config(actual[k], v) for k, v in expected.items())
    if isinstance(expected, list):
        if not isinstance(actual, list):
            return False
        if expected and all(isinstance(v, dict) and 'name' in v for v in expected):
            by_name = {v['name']: v for v in actual if isinstance(v, dict) and 'name' in v}
            return all(v['name'] in by_name and contains_config(by_name[v['name']], v) for v in expected)
        return len(actual) == len(expected) and all(contains_config(a, e) for a, e in zip(actual, expected))
    return actual == expected


def existing_job_matches(path):
    expected = yaml.safe_load(path.read_text())
    name = expected['metadata']['name']
    result = run(['kubectl', 'get', 'job', name, '-n', CFG['namespace'],
                  '--ignore-not-found', '-o', 'json'], capture_output=True, text=True)
    if not result.stdout.strip():
        return False
    actual = json.loads(result.stdout)
    if not contains_config(actual, expected):
        raise ValueError(f'{name} exists with different configuration; leaving it unchanged. Review before continuing.')
    print(f'Skipping existing Job: {name}', flush=True)
    return True


def selected(args):
    names=args.models or ([m for m,v in CFG['models'].items() if v['audit_status']=='not-observed'] if args.missing else [])
    if args.all: names=list(CFG['models'])
    if not names: raise ValueError('Select model names, --missing, or --all explicitly')
    for m in names:
        if m not in CFG['models']: raise ValueError(f'Unknown model: {m}')
    return names

def manifest(model, partition, index):
    entry=CFG['models'][model]; resource=CFG['profiles'][entry['profile']][partition]
    doc=yaml.safe_load((ROOT/'templates/job.yaml').read_text())
    labels={'app':'navsafe-offset','model':model,'partition':partition,'worker':f'w{index:02d}'}
    name=f'ns-offset-{model.replace("_","-")}-{partition}-s{CFG["seed"]}-w{index:02d}'
    doc['metadata']={'name':name,'namespace':CFG['namespace'],'labels':labels}
    doc['spec']['template']['metadata']={'labels':labels}
    spec=doc['spec']['template']['spec']; c=spec['containers'][0]
    c['args']=[CFG['tooling_root']+'/scripts/run_worker.sh']
    env={'WORKER_INDEX':str(index),'WORKERS':str(entry['workers'][partition]),'SEEDS':str(CFG['seed']),
         'OUTROOT':CFG['outroot'],'NEXUSSIM_SHA':CFG['nexussim_sha'],
         'MODELS_TSV':CFG['tooling_root']+f'/config/models/{model}.tsv',
         'SELECTION':CFG['tooling_root']+f'/config/scenarios/{partition}.json',
         'HYDRA_FULL_ERROR':'1','ACCEPT_EULA':'Y','OMNI_KIT_ACCEPT_EULA':'Y',
         'NAVSAFE_VLA_GPU':'2' if resource['gpus']==3 else str(resource['gpus']-1),
         'NEXUSSIM_NO_OVERLAY':'0','CELL_TRIES':'3'}
    c['env'] += [{'name':k,'value':v} for k,v in env.items()]
    for kind,mem in [('requests','memory_request'),('limits','memory_limit')]:
        c['resources'][kind].update({'cpu':'3','memory':resource[mem],'nvidia.com/gpu':str(resource['gpus'])})
    expressions=spec['affinity']['nodeAffinity']['requiredDuringSchedulingIgnoredDuringExecution']['nodeSelectorTerms'][0]['matchExpressions']
    if resource['gpus']>=2:
        expressions[0]['values']=[n for n in expressions[0]['values'] if n!='ry-gpu-08.sdsc.optiputer.net']
    expressions.append({'key':'nvidia.com/gpu.product','operator':'In','values':['NVIDIA-GeForce-RTX-3090']})
    return doc

def render(models, partition):
    result=[]
    for m in models:
        for part in (['plain','edit'] if partition=='all' else [partition]):
            for i in range(CFG['models'][m]['workers'][part]):
                path=ROOT/'jobs'/m/part/f'w{i:02d}.yaml';path.parent.mkdir(parents=True,exist_ok=True)
                path.write_text(yaml.safe_dump(manifest(m,part,i),sort_keys=False,default_style='"'));result.append(path)
    return result

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action',choices=['render','submit','stage','status'])
    ap.add_argument('models',nargs='*');ap.add_argument('--missing',action='store_true');ap.add_argument('--all',action='store_true')
    ap.add_argument('--partition',choices=['plain','edit','all'],default='all')
    ap.add_argument('--apply',action='store_true',help='Actually create Jobs; without it submit uses server dry-run')
    ap.add_argument('--pod');ap.add_argument('--container')
    args=ap.parse_args()
    if args.action=='stage':
        if not args.pod or not args.container: ap.error('stage requires --pod and --container (must mount /avl-west)')
        # Authenticate with the terminal still attached, before stdin becomes a tar stream.
        print('Checking Kubernetes authentication and target pod before uploading...', flush=True)
        run(['kubectl','get','pod',args.pod,'-n',CFG['namespace'],'-o','name'])
        dest=CFG['tooling_root']
        # Versioned staging: refuse overwrites; use a new revision to publish updates.
        files=[p for d in ['scripts','config'] for p in (ROOT/d).rglob('*') if p.is_file()]
        sums={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
        with tempfile.TemporaryDirectory() as td:
            archive=Path(td)/'tooling.tar'
            with tarfile.open(archive,'w') as tar:
                for p in files: tar.add(p,arcname=str(p.relative_to(ROOT)))
            command=f'test ! -e {shlex.quote(dest)} && mkdir -p {shlex.quote(dest)} && tar -xf - -C {shlex.quote(dest)}'
            with archive.open('rb') as stream:
                run(['kubectl','exec','-i','-n',CFG['namespace'],args.pod,'-c',args.container,'--','bash','-lc',command],stdin=stream)
            verify='cd '+shlex.quote(dest)+' && sha256sum '+ ' '.join(shlex.quote(x) for x in sums)
            r=run(['kubectl','exec','-n',CFG['namespace'],args.pod,'-c',args.container,'--','bash','-lc',verify],capture_output=True,text=True)
            actual={line.split(maxsplit=1)[1].strip():line.split()[0] for line in r.stdout.splitlines()}
            if actual!=sums: raise ValueError('Staged checksum mismatch; do not submit')
        print(f'Staged and verified {len(files)} files: {dest}');return
    if args.action=='status':
        run(['kubectl','get','jobs,pods','-n',CFG['namespace'],'-l','app=navsafe-offset']);return
    files=render(selected(args),args.partition)
    print(f'Rendered {len(files)} Jobs')
    if args.action=='submit':
        print('Outputs resume from existing cells. Do not overlap legacy workers for the same model/partition.')
        for path in files:
            if existing_job_matches(path):
                continue
            print(f'Submitting {path.relative_to(ROOT)}' if args.apply else f'Dry-run {path.relative_to(ROOT)}', flush=True)
            cmd=['kubectl','create','-f',str(path)]
            if not args.apply: cmd += ['--dry-run=server','-o','name']
            run(cmd)
if __name__=='__main__':
    try:main()
    except KeyboardInterrupt:
        if len(sys.argv) > 1 and sys.argv[1] == 'submit':
            print('\nSubmission canceled. Created Jobs remain. Rerun the same command to skip matching Jobs and submit the rest.', file=sys.stderr)
        elif len(sys.argv) > 1 and sys.argv[1] == 'stage':
            print('\nStaging canceled. Verify the destination before retrying; no rollback was performed.', file=sys.stderr)
        else:
            print('\nCanceled.', file=sys.stderr)
        sys.exit(130)
    except (ValueError,subprocess.CalledProcessError) as e:
        print(e,file=sys.stderr);sys.exit(1)
