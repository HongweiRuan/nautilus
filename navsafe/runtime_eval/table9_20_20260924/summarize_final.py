#!/usr/bin/env python3
import csv
import json
import re
import statistics
from collections import defaultdict
from pathlib import Path

original = Path('/avl-west/navsafe_runtime/table9_drivor_20_20260924')
repair = Path('/avl-west/navsafe_runtime/table9_drivor_20_20260924_warmrepair')
final = Path('/avl-west/navsafe_runtime/table9_drivor_20_20260924_final')
final.mkdir(parents=True, exist_ok=True)

pairs = [
    ('0027991369e05ab2', '02b68b9cc51f506a'),
    ('0578756b879c55d0', '07930113a85651b0'),
    ('0a51eb8adf8e5391', '0e272e003af65a71'),
    ('13bb7469606159e9', '184c11a8cc875403'),
    ('1dc437ce152e55fa', '2462c21ce2bb5f2d'),
    ('2d24100bcb1e57e2', '39d1f561e06054c5'),
    ('4874da28248a5026', '58d69daf413c5d5a'),
    ('6ad48974e9985e1f', '7b635c8426075d70'),
    ('9135a6d270475c7f', 'a4581d8af5f755a9'),
    ('bfcbb192c11b5736', 'e9567d54464052f7'),
]
selected = {a: repair for a, _ in pairs} | {b: original for _, b in pairs}
assert len(selected) == 20

def percentile(xs, p):
    ys = sorted(xs)
    x = (len(ys) - 1) * p
    lo = int(x)
    hi = min(lo + 1, len(ys) - 1)
    return ys[lo] * (hi - x) + ys[hi] * (x - lo)

def episode_rows(root):
    result = {}
    for path in sorted((root / '_workers').glob('w*/episodes.tsv')):
        worker = path.parent.name
        for line in path.read_text().splitlines():
            token, model, seed, start_ns, wall_s, rc = line.split('\t')
            result[token] = {
                'worker': worker, 'model': model, 'seed': int(seed),
                'start_ns': int(start_ns), 'wall_s': float(wall_s), 'rc': int(rc),
            }
    return result

by_root = {original: episode_rows(original), repair: episode_rows(repair)}
rows = []
profile_re = re.compile(
    r'\[PROFILE\] eval loop stages over (\d+) frames '
    r'\(sum=([0-9.]+)s, ([0-9.]+) ms/frame\)')
done_re = re.compile(r'^\[eval_py123d\] DONE\.', re.M)
elapsed_re = re.compile(r"'elapsed_time': ([0-9.]+)")
for token, root in selected.items():
    row = dict(by_root[root][token])
    log = root / 'drivor' / 'seed1' / f'{token}.log'
    metrics = root / 'drivor' / 'seed1' / token / 'navsafe_metrics.json'
    text = log.read_text(errors='replace')
    prof = profile_re.search(text)
    elapsed = elapsed_re.search(text)
    metric = json.loads(metrics.read_text())
    row.update({
        'scenario': token,
        'source_batch': 'warm_repair' if root == repair else 'original_second',
        'done': bool(done_re.search(text)),
        'metrics_status': metric.get('status'),
        'frames': int(prof.group(1)) if prof else None,
        'profile_sum_s': float(prof.group(2)) if prof else None,
        'steady_ms_per_frame': float(prof.group(3)) if prof else None,
        'eval_loop_elapsed_s': float(elapsed.group(1)) if elapsed else None,
        'termination': metric.get('termination', {}).get('reason'),
    })
    rows.append(row)

bad = [r for r in rows if r['rc'] != 0 or not r['done'] or not r['metrics_status'] or r['frames'] is None]
if bad:
    raise SystemExit('invalid selected episodes: ' + json.dumps(bad, indent=2))

# Renderer startup belongs to the original ten-worker design; it is independent
# of the policy-side Kit-cache miss that motivated the repair batch.
renderer_starts = [
    float(x)
    for path in sorted((original / '_workers').glob('w*/renderer_startup_s.txt'))
    for x in path.read_text().split()
]

def gpu_worker_peaks(root):
    result = {}
    for path in sorted((root / '_workers').glob('w*/gpu_samples.csv')):
        by_stamp = defaultdict(dict)
        for line in path.read_text().splitlines():
            a = [x.strip() for x in line.split(',')]
            if len(a) < 7:
                continue
            by_stamp[a[0]][int(a[1])] = float(a[4])
        dev = defaultdict(float)
        combined = 0.0
        for sample in by_stamp.values():
            for idx, used in sample.items():
                dev[idx] = max(dev[idx], used)
            if 0 in sample and 1 in sample:
                combined = max(combined, sample[0] + sample[1])
        result[path.parent.name] = {
            'renderer_gpu0_peak_mib': dev[0],
            'policy_gpu1_peak_mib': dev[1],
            'combined_peak_mib': combined,
        }
    return result

gpu_peaks = {
    'original': gpu_worker_peaks(original),
    'warm_repair': gpu_worker_peaks(repair),
}
all_combined = [v['combined_peak_mib'] for batch in gpu_peaks.values() for v in batch.values()]
all_g0 = [v['renderer_gpu0_peak_mib'] for batch in gpu_peaks.values() for v in batch.values()]
all_g1 = [v['policy_gpu1_peak_mib'] for batch in gpu_peaks.values() for v in batch.values()]

wall = [r['wall_s'] for r in rows]
steady = [r['steady_ms_per_frame'] for r in rows]
frames = [r['frames'] for r in rows]
profile_sum = [r['profile_sum_s'] for r in rows]
summary = {
    'selection': {
        'episodes': len(rows), 'unique_scenarios': len({r['scenario'] for r in rows}),
        'policy': 'DrivoR baseline', 'traffic_mode': 'semi_reactive',
        'eval_seed': 1, 'ego_replay_frames': 20, 'max_scored_frames': 600,
        'visualization': False, 'nexussim_commit': '620ab1a27d209e46c76e818b6ea4fe30024d3d9b',
        'gpu': '2 x NVIDIA GeForce RTX 3090 (24 GiB), renderer GPU 0, policy GPU 1',
    },
    'episode_evaluation_s': {
        'median': statistics.median(wall), 'p90': percentile(wall, .9), 'maximum': max(wall),
        'minimum': min(wall), 'n': len(wall),
    },
    'steady_state_frame': {
        'weighted_seconds_per_frame': sum(profile_sum) / sum(frames),
        'median_episode_seconds_per_frame': statistics.median(steady) / 1000,
        'p90_episode_seconds_per_frame': percentile(steady, .9) / 1000,
        'maximum_episode_seconds_per_frame': max(steady) / 1000,
        'total_profiled_frames': sum(frames),
    },
    'renderer_startup_s': {
        'median': statistics.median(renderer_starts), 'p90': percentile(renderer_starts, .9),
        'minimum': min(renderer_starts), 'maximum': max(renderer_starts), 'n': len(renderer_starts),
    },
    'gpu_memory': {
        'combined_peak_gib_median': statistics.median(all_combined) / 1024,
        'combined_peak_gib_p90': percentile(all_combined, .9) / 1024,
        'combined_peak_gib_maximum': max(all_combined) / 1024,
        'renderer_gpu0_peak_gib_median': statistics.median(all_g0) / 1024,
        'policy_gpu1_peak_gib_median': statistics.median(all_g1) / 1024,
        'workers_sampled': len(all_combined),
    },
    'gpu_worker_peaks': gpu_peaks,
    'episodes': sorted(rows, key=lambda r: r['scenario']),
}

(final / 'table9_summary.json').write_text(json.dumps(summary, indent=2) + '\n')
with (final / 'episodes.csv').open('w', newline='') as f:
    writer = csv.DictWriter(f, fieldnames=list(sorted(rows[0])))
    writer.writeheader()
    writer.writerows(sorted(rows, key=lambda r: r['scenario']))

e = summary['episode_evaluation_s']
s = summary['steady_state_frame']
r = summary['renderer_startup_s']
g = summary['gpu_memory']
cell = [x + r['median'] for x in wall]
latex = f'''% Table 9 measured on 20 warm-cache DrivoR episodes, commit 620ab1a.
Episode evaluation & {e['median']:.0f} s & {e['p90']:.0f} s & {e['maximum']:.0f} s & 20 & Up to 60 s per episode \\\\
Steady-state frame & {s['median_episode_seconds_per_frame']:.2f} s & {s['p90_episode_seconds_per_frame']:.2f} s & {s['maximum_episode_seconds_per_frame']:.2f} s & 20 episodes & End-to-end \\\\
Renderer startup & {r['median']:.0f} s & {r['p90']:.0f} s & {r['maximum']:.0f} s & 10 launches & Excluded above \\\\
Operational cell budget & {statistics.median(cell)/60:.1f} min & {percentile(cell,.9)/60:.1f} min & {max(cell)/60:.1f} min & 20 episodes & Startup included \\\\
GPU memory/worker & {g['combined_peak_gib_median']:.1f} GiB & {g['combined_peak_gib_p90']:.1f} GiB & {g['combined_peak_gib_maximum']:.1f} GiB & 15 workers & Two RTX 3090 GPUs \\\\
Scenario-bundle storage & 8.43 GiB & -- & -- & one bundle & 16-file snapshot \\\\
'''
(final / 'table9_rows.tex').write_text(latex)
(final / 'table9_paragraph.tex').write_text(f'''Table~\\ref{{tab:runtime}} reports end-to-end runtime measured on 20 policy-in-loop episodes using semi-reactive traffic and the NuRec renderer. End-to-end time includes rendering, simulation, policy inference, control, and scoring. We use the DrivoR baseline policy on two NVIDIA GeForce RTX~3090 GPUs per worker: GPU~0 serves the renderer and GPU~1 runs simulation and policy inference. Median combined peak memory is {g['combined_peak_gib_median']:.1f}~GiB ({g['renderer_gpu0_peak_gib_median']:.1f}~GiB for rendering and {g['policy_gpu1_peak_gib_median']:.1f}~GiB for the policy-side process). The component-level rendering/inference latency split is reported separately in Table~\\ref{{tab:throughput}}.\n''')
print(json.dumps(summary, indent=2))
