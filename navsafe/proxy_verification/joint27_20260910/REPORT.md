# 27 场景 proxy set：筛选与验证

## 目的与数据

我们希望从完整评测集（benchmark）中选出一个小型代表场景集（proxy set），减少后续扰动实验的成本。排除 V-8 后，候选池包含 270 个场景（scenario）、27 个最细场景类别（leaf），目标是每个 leaf 选一个，共 27 个。

已有全部模型的闭环评测结果：驾驶得分 **DS** 和单次场景是否成功 **success（0/1）**；对 success 汇总得到成功率 **SR**。本次直接利用这些结果筛选和验证，无需重新运行模型，也未提交 GPU Job。

## 先分清：哪些模型选场景，哪些模型做验证

参考 [tinyBenchmarks（ICML 2024）§5 Evaluation pipeline](https://arxiv.org/html/2402.14992v2#S5) 的 train/test model 划分，用一组模型选样本、另一组模型检验估计误差。我们据此将 16 个学习模型分成两组，避免“用同一批模型选场景，再只用它们证明选得好”；具体 11/5 划分是本任务的设置。这是模型层面的留出验证（model-level holdout），不涉及训练模型权重，也不是把候选场景分成训练集和测试集。

- **用于选场景的 11 个模型，称为 development models**：使用它们的结果决定选哪 27 个场景。具体为 AutoVLA、DiffusionDrive、DiffusionDrive (BeyondDrive)、DiffusionDrive (SimScale)、DriveLaw、DriveVLA-W0、LTF、MTDrive-mtGRPO、MTDrive-SFT、RAP、SparseDriveV2。
- **留作验证的 5 个模型，称为 held-out models**：DrivoR、ReCogDrive IL/RL、SimWAM base/RL。筛选时不使用它们的结果；选完后，比较它们在 proxy set 上估计的 DS/SR 与完整 270 场景的分数，检查场景集对未参与筛选的模型是否仍有代表性。

同一基础方法的不同变体归为一个模型家族（model family），例如三个 DiffusionDrive 变体。16 个模型共分为 11 个 families；拥有特权信息的 PDM 不参与筛选。

## k-means 如何选出 27 个场景

参考 [tinyBenchmarks（ICML 2024）§3.2 Clustering](https://arxiv.org/html/2402.14992v2#S3.SS2)：根据模型表现构造样本特征，聚类后选离中心最近的真实样本，并按簇大小加权。我们将其适配为以下流程；**每个 leaf 固定一个、DS/success 双指标和 family 加权是我们的设置，不是论文原配置**。

1. **描述场景**：用 development models 在固定随机种子 seed0 下的结果，将各模型的 `DS/100` 和 `success` 拼成 22 维特征向量。同一 family 有 n 个模型时，其坐标各除以 √n，避免变体多的 family 主导距离。
2. **选代表场景**：在每个 leaf 内计算所有场景的平均特征，即中心（centroid），再选与中心的欧氏距离（Euclidean distance）最近的真实场景。这相当于每个 leaf 内做 **k-means，k=1**；27 个 leaf 各选一个，而不是全局 K=27。
3. **估计整体分数**：按 `该 leaf 场景数 / 270` 加权选中场景的 DS 和 success，得到 proxy DS / SR。


## 怎样检查选得好不好

除上述 k-means 方法外，我们比较两种方法：

- **Stratified random sampling**：参考 [tinyBenchmarks §3.1](https://arxiv.org/html/2402.14992v2#S3.SS1) 的按类别分层随机采样。这里以 leaf 为层，每层随机选一个，重复 1,000 组；分层粒度和重复次数由我们设定。
- **Joint search**：借鉴 [FlashEval（CVPR 2024）§4.2](https://arxiv.org/html/2403.16379v1#S4.SS2) 对整套样本联合搜索的思路。我们的实现是在 leaf 内替换场景，优化 DS/SR 分数误差并考虑 leaf 内代表性；**没有复现 FlashEval 基于排名一致性的原搜索算法**。

为了不让结论只依赖前面的 11/5 划分，我们轮流把一个完整 family 留作验证，其余 families 负责选场景；joint search 的超参数也只在负责筛选的 families 内进一步划分验证。这称为 **nested leave-one-family-out validation**，是我们在 tinyBenchmarks 的 model holdout 原则上增加的 family 分组与嵌套验证，并非该论文的原始实验配置。每一轮都会重新选场景，因此检验的是筛选方法，而不是同一个固定 proxy set。

参考 [tinyBenchmarks §5](https://arxiv.org/html/2402.14992v2#S5) 的估计误差评估，用 proxy 分数与完整集分数的平均绝对误差（**MAE**）衡量准确性，越低越好：

| 方法 | DS MAE（百分点） | SR MAE（百分点） |
|---|---:|---:|
| k-means / Centroid | **3.58** | **5.72** |
| Stratified random（1,000 组均值） | 4.70 | 6.02 |
| Joint search | 4.59 | 6.92 |

Joint search 的平均误差更高；我们额外按 family 重采样计算的误差差值区间（bootstrap interval）也包含 0，没有证据说明它优于 k-means。

回到原始 11 development / 5 held-out models 的固定划分，旧 k-means 集的 DS/SR MAE 为 **6.03 / 10.67** 个百分点，joint search 候选为 **3.97 / 6.81**。后者虽有改善，仍未通过事先设定的标准：平均误差 ≤ 3 个百分点、最大误差 ≤ 5 个百分点、模型排名相关性（Spearman ρ）≥ 0.90。**这些通过阈值是本任务设定的精度目标，不是文献给出的通用标准。**

## 结论与边界

**保留原始 k-means 27 场景集用于小规模探索；目前不能认为它可以准确替代完整 benchmark，也没有充分依据改用 joint search 候选。**

这些验证使用了此前已经查看过的结果，属于回顾性验证（retrospective validation）。每个 leaf 一个场景不能估计类别内部差异；无扰动分数的验证，也不能证明扰动后的表现变化曲线（perturbation-response curves）有代表性。本次结果不意味着不存在更好的 27 场景组合。

## 文件与参考

- 原始 **k-means 27 场景**：[proxy27/proxy_set.csv](../proxy27/proxy_set.csv)。当前目录的 `proxy_set.csv` 是 joint search 候选，未替换原集合。
- 完整数值见 [results.json](results.json)，复现程序见 [run.py](run.py)，实验配置见 [PROTOCOL.json](PROTOCOL.json)。
- [tinyBenchmarks（ICML 2024）](https://arxiv.org/html/2402.14992v2)：表现聚类与 held-out model 验证；[FlashEval（CVPR 2024）](https://arxiv.org/html/2403.16379v1)：整套样本的联合搜索思路；[Micro-Benchmark Reliability（ICLR 2026）](https://proceedings.iclr.cc/paper_files/paper/2026/hash/2e2960f2fe9e981f33f51c78656e3ca2-Abstract-Conference.html)：按分数差分析排名可靠性。
