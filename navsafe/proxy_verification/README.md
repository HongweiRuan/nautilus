# NavSafe proxy verification

## 50 场景候选尝试（2026-09-10）

已生成 [50 场景候选](proxy50_20260910/proxy_set.csv) 与 [28→50 对比报告](proxy50_20260910/REPORT.md)。family-out leaf 内 DS/SR MAE 从 21.21/28.08 降至 11.69/15.00 pp，但固定集合仍有 V-2 等较大偏差；未宣称逐 leaf 代表性已充分验证。CPU-only，候选单独保存，旧 28 场景名单保留。

## 当前版本：28 场景，包含 V-8（2026-09-10）

V-8 已核对：17 个模型（含 PDM）× 3 seeds × 10 场景均有效。沿用原筛选规则，原 27 个场景不变，新增 V-8 `14c0a657ac3e5bb7`。当前以 [28 场景名单](proxy28_20260910/proxy_set.csv) 为准，见 [新报告](proxy28_20260910/REPORT.md)。本轮 CPU-only；仅检查无扰动表现代表性，未提交 GPU Job。下文 27 场景及 GPU 方案均为历史记录。

## 历史版本：27 场景，不含 V-8

按用户最新要求固定为 27 个 leaf 各一个场景，不再为精确复现排行榜而扩容。

- [27 场景名单及权重](proxy27/proxy_set.csv)
- [纯 token 清单](proxy27/proxy_tokens.txt)
- [方法、诊断结果与完整名单](proxy27/README.md)
- [CPU 验证结果](proxy27/verification.json)
- [待审 GPU 配置](proxy27/gpu/README.md)

筛选和 CPU 资源检查已完成。基线误差仍不小，尚未证明这个小集合能代表扰动后的全量表现；不能称其已通过完整代表性验证。

如开展 GPU 验证：proxy 仍是 27 个；另抽 54 个非 proxy 场景作为独立审计，不加入 proxy。两模型、无偏移/+0.5m 横向偏移，合计 324 episodes，最多同时 4 GPU。NuRec gRPC only。YAML 已准备并通过 server dry-run；没有提交。是否运行由用户确认。

此前 results_20260909/ 的 172 场景结果和 1120-episode GPU 提案保留为历史，已被当前 27 场景方案替代，不应提交旧版 Job。

Pod 持久副本：/hugsim-storage/NexusSim/docs/experiments/proxy_verification_20260909/proxy27/

## 2026-09-10：tinyBenchmarks 式固定名单验证

[验证报告](proxy27/tinybenchmarks_validation/REPORT.md)：在未用于构建聚类向量的五个模型上，seed0 DS/SR MAE = 6.03/10.67 pp；同规模分层随机抽样的平均 MAE = 4.96/6.62 pp。排名相关性均为 0.90，但不能据此证明绝对分数代表性。固定名单不变，CPU-only，没有启动 GPU。结论不支持把这 27 场景称为已验证的全量评测替代品。采用原模型划分复核，非全新盲测；未实施 IRT++，未验证扰动响应。

## 2026-09-10：固定 27 场景联合搜索比较

[完整结果](joint27_20260910/REPORT.md)。16 模型、11 家族嵌套留出验证中，centroid 的 DS/SR MAE 为 3.58/5.72 pp，分层随机为 4.70/6.02 pp，联合搜索为 4.59/6.92 pp。联合搜索在原五模型划分上有所改善，但未表现出跨家族的稳定优势，因此不替换当前 27 场景名单。新名单仅作为研究候选保存在 joint27_20260910/。本轮仍未获得通过严格验证的 27 场景全量替代集；不证明这样的集合不可能存在。没有提交 GPU Job。
