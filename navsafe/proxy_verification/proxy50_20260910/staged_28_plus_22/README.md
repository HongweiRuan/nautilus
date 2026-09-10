# 分两批运行：优先 28 + 后补 22

**先运行 priority28；有时间再运行 additional22。两批无重复，合并后恰好是已选好的完整 50 场景。** 所有模型使用相同批次。本次仅生成名单与评分权重，未启动 GPU 评测。

## 第一批：每个 leaf 一个，共 28 个

[priority28_tokens.txt](priority28_tokens.txt) 是运行 token 列表；[priority28.csv](priority28.csv) 包含评分权重。

从现有 50 个中，在每个 leaf 的候选代表里，选择最接近整个 leaf 平均特征的一个。只用原 11 个 development models（用于筛选的模型）的表现计算距离，不根据另外 5 个 held-out models（用于验证的模型）的分数挑场景。

**这是新的优先 28 名单，与旧 proxy28 有 17 个场景重合，11 个不同。** 原 50 并不包含旧 28 的全部场景；不能把旧 28 直接接上这里的 additional22。

仅完成第一批时，使用 `stage1_weight`：每个场景权重为 1/28，代表整个 leaf。不要直接使用完整 50 的权重再归一化，否则各 leaf 的权重会改变。

## 第二批：剩余 22 个

[additional22_tokens.txt](additional22_tokens.txt) 是补跑列表；[additional22.csv](additional22.csv) 包含完整集合中的权重。

补齐后复用第一批相同模型、seed 和实验配置的结果，无需重复跑这 28 个。使用 [full50_execution_order.csv](full50_execution_order.csv) 的 `full50_weight` 汇总全部 50 个：权重为各代表 cluster 的场景数 / 280。不要把“第一批平均分”和“第二批平均分”直接平均。baseline 与各 perturbation 条件必须分别使用对应版本的同一权重。

## 现有 baseline 复核

在原 5 个 held-out models 上，新优先 28 的整体 DS/SR MAE 为 1.58/2.43 个百分点，leaf 内 MAE 为 23.93/34.29；完整 50 的整体 MAE 为 2.59/2.36，leaf 内 MAE 为 15.39/21.21。

这是同一历史划分的回顾性复核，不是新盲测，也不是 family-out 结果；没有根据这些数值再次调整名单。优先 28 的整体误差较小不代表逐 leaf 更准确，不能套用旧 28 的验证数字。

检查已通过：第一批覆盖 28 leaf；两批分别 28/22 个且无交集；并集与原 50 相同；两阶段各自完整的评分权重和为 1；完整 50 的估计分数复现原结果。详见 [verification.json](verification.json)。
