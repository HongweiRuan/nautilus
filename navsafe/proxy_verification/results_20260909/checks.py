import pathlib,json,numpy as np
p=pathlib.Path('/root/proxy_verification_20260909')
ns={};exec((p/'select.py').read_text().split('curves=[];chosen=None')[0],ns)
rows=ns['rows'];assert all(r['status']=='scored' and isinstance(r['success'],bool) and 0<=r['ds']<=100 for r in rows)
sel=json.load(open(p/'proxy_set.json'));tokens=ns['alltokens']
assert len({r['token'] for r in sel})==len(sel)
assert sorted(t for r in sel for t in r['members'])==tokens
assert abs(sum(r['weight_280'] for r in sel)-1)<1e-12
assert abs(sum(r['weight_270'] for r in sel)-1)<1e-12
assert len({r['leaf'] for r in sel})==28
assert (p/'proxy_tokens.txt').read_bytes()==(p/'proxy_tokens_frozen.txt').read_bytes()
g=ns['select'](ns['dev'],10);pred=ns['predict'](g,ns['models'])
assert np.allclose(pred,ns['truth'],atol=1e-12)
old=ns['select'](ns['dev'],6)
for key,r in ns['R'].items():
 if key[0] in ns['hold']:r['ds']=0;r['success']=False
assert old==ns['select'](ns['dev'],6), 'holdout leakage'
assert ns['passes']({x:{'mae_pp':1,'max_error_pp':2,'spearman':.8999999999999998,'large_gap_inversions':0} for x in ('DS','SR')})
(p/'checks.json').write_text(json.dumps({'status':'passed','checks':['scored_bounded_input','unique_anchors','partition_exactly_covers_280','weights_sum_to_one','all_28_leaves','frozen_tokens_unchanged_after_float_fix','census_reconstructs_full_scores','holdout_score_mutation_does_not_change_anchors','spearman_float_boundary']},indent=2))
print('PASS: 9 input, weighting, leakage, reconstruction and numerical checks')
