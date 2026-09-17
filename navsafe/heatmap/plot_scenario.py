import json,sys
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
root=Path(sys.argv[1]);leaf,token=sys.argv[2:4]
rows={model:[json.loads((root/f'seed{seed}'/leaf/token/'base'/model/'heatmap_episode.json').read_text()) for seed in range(30)] for model in ('drivor','drivor_simscale')}
out=root/'figures';out.mkdir(exist_ok=True)
for frame in (20,40):
 fig,ax=plt.subplots(figsize=(7,5));fig.subplots_adjust(bottom=.28,right=.85)
 vals=[r['states'][str(frame)]['mc_return'] for rr in rows.values() for r in rr if r['states'][str(frame)].get('mc_return') is not None]
 norm=matplotlib.colors.Normalize(min([0]+vals),max([1]+vals))
 ol=rows['drivor'][0]['states'][str(frame)]['ol_log_xy']
 for model,rr in rows.items():
  for r in rr:assert np.allclose(r['states'][str(frame)]['ol_log_xy'],ol)
 counts=[]
 for (model,rr),marker in zip(rows.items(),('o','^')):
  valid=[r['states'][str(frame)] for r in rr if r['states'][str(frame)].get('mc_return') is not None and r['states'][str(frame)]['cl_xy'] is not None]
  counts.append(len(valid))
  if valid:
   xy=np.array([v['cl_xy'] for v in valid]);ax.scatter(*xy.T,c=[v['mc_return'] for v in valid],norm=norm,cmap='viridis',marker=marker,s=36,edgecolors='white',linewidths=.5)
 ax.scatter(*ol,marker='D',s=65,facecolors='none',edgecolors='black',zorder=5)
 ax.set(xlabel='Forward x (m)',ylabel='Leftward y (m)',title=f'{leaf} | {token} | t = {frame/10:g} s')
 ax.grid(alpha=.15);ax.margins(.2)
 fig.colorbar(matplotlib.cm.ScalarMappable(norm=norm,cmap='viridis'),ax=ax,label='Future discounted ΔDS return')
 handles=[Line2D([],[],marker='D',color='black',mfc='none',ls='',label='OL: one logged state'),Line2D([],[],marker='o',color='#31878d',ls='',label=f'DrivoR CL: {counts[0]}/30 valid'),Line2D([],[],marker='^',color='#31878d',ls='',label=f'DrivoR-SimScale CL: {counts[1]}/30 valid')]
 fig.legend(handles=handles,loc='lower center',fontsize=8,title=f'Reference: frame 0; state: frame {frame} (+{frame/10:g} s)\n30 seeds/model; overlapping points retained; γ=0.99; terminal horizon=4 s',title_fontsize=8,frameon=True)
 for ext in ('png','svg'):fig.savefig(out/f'{leaf}_{token}_t{frame//10}.{ext}',dpi=200)
 plt.close(fig)
print('SCENARIO_PLOTS_SAVED',leaf,token)
