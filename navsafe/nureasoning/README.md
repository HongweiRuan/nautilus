# nuReasoning Job YAMLs

所有 nuReasoning 的本地 Job YAML 统一保存在本目录。每个 Job 只有一份文件，实际 command/args 保留内嵌；每个批次用 kustomization.yaml 引用这些文件，替代重复的 all5/all8/all20.yaml。

| 目录 | Jobs | 用途 |
|---|---:|---|
| [train/recipe-v2-sweep20-20261001](train/recipe-v2-sweep20-20261001/README.md) | 20 | 当前两场景 × 五预算/步数 × background Fourier dim1/5 实验 |
| [train/recipe-v2-5m160k-20261001](train/recipe-v2-5m160k-20261001/README.md) | 4 | 新增两场景 × 5M/160k × background Fourier dim1/5 |
| [train/car2sim-sweep5-20261001](train/car2sim-sweep5-20261001/README.md) | 5 | 旧 car2sim 派生 recipe 的五组合对照；保留运行中的3M/160k配置 |
| [train/car2sim-full8-20261001](train/car2sim-full8-20261001/README.md) | 8 | 成功的最终 full8 版本，保留 convert/aux/reconstruction 完整流程参考 |
| [eval/replay200-drivor20-20261001](eval/replay200-drivor20-20261001/README.md) | 5 | visualization、200帧ego replay、20帧replay后DrivOR控制、warm Kit cache |

共42个不同的 Job。当前recipe-v2实验共24组（原20组加新增4组5M/160k）。按批次、场景、setting查找；当前20组的文件形式是 jobs/<clip hash>/<budget>-<steps>-bg<dim>.yaml。

## 查看和提交

在本目录运行，查看一批完整配置：

```bash
kubectl kustomize train/recipe-v2-sweep20-20261001
```

选择需要提交的一批：

```bash
kubectl apply -k train/recipe-v2-sweep20-20261001
```

单个 Job：

```bash
kubectl apply -f train/recipe-v2-sweep20-20261001/jobs/660c2f7a/3m-80k-bg1.yaml
```

配置中的 Job 名称和输出目录保持原样；重新 apply 现有同名 Job 不会重新执行训练。复跑实验需要新的 Job 名称与输出目录。

## 保留与清理依据

保留当前实验、成功最终版、不同 recipe 的有效对照及已跑通的评估。删除 full8 初版/r1/r2 失败或过时重试、重复批量清单、临时monitor脚本，以及多份 recipes/parsed YAML副本。配置展开、生成器和完整日志的工作副本继续位于 NavSafe repo 的 deploy/nautilus/ 和原来的PVC结果目录。

[文件清单和校验](inventory.json)记录来源、Job 名称及SHA256。原目录整理没有修改38份 Job 的任何字节，也没有操作集群资源或训练结果；随后新增4份5M/160k训练配置，单独保存于补充实验批次。metadata/中的旧状态与validation是历史记录，按各自时间理解；Job内容校验以inventory.json为准。

本轮失败的4份实验配置仍包含在20组中，便于定位和后续修复。它们都运行于ry13，报CUDA分配/launch错误，节点原因尚未确认。失败证据已保存在NavSafe repo的cleanup-old-jobs-20261001.json。

后续新增 nuReasoning Job 也放在本目录对应train/或eval/批次中，更新该批次kustomization.yaml。
