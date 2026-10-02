# nuReasoning 失败训练恢复

17个尚未完成的原实验：ry13上4个、ry14上7个、ry06上3个、ry12上3个。同节点实验在几秒到一分钟内同时失败，错误为tiny-cuda-nn cudaMalloc unknown error、CUDA driver unknown error或launch failure719；四个节点之后全部被self-node-remediation NoSchedule隔离。证据支持节点/驱动故障，不能仅凭日志细分硬件与驱动根因；没有普通CUDA out-of-memory的报错证据。

恢复：不改model、loss、dataset总采样步数、trainer和学习率调度。每10k保存checkpoint，主机RAM从64Gi降至32Gi匹配观察到的~7-12Gi RSS。6个完整checkpoint含optimizer/schedulers/loops，续训步数30k、40k×4、120k；另外11个尚无checkpoint，重跑。原8个完成实验SUCCESS.json和USDZ已检查并保留。

17/17原生typed配置预检及17/17server dry-run通过。最终用户要求优先新recipe5M160k，因此只创建这4个恢复Job：2组在ry11实际训练，2组待GPU；其余13组保留配置但暂不提交。未添加remediation toleration；候选节点06/07/11/12/13/14，调度器只使用解除隔离的节点，08继续排除。

原Failed Job状态不会被重跑改写；新的Job名称为navsafe-nur-retry-*。原诊断日志保留在PVC各DEST/diagnostics/<pod>/；恢复继续写原DEST但使用新Pod的独立diagnostics目录。节点根因若复发，需管理员检查节点driver/kernel Xid与硬件状态，不能靠减少Gaussian预算冒充修复。

另：CPU预检第一版因单参数超过Linux128KiB上限失败；r1只压缩了嵌入的配置数据，17份训练Job中的命令/recipe均保持完整可读，r1已通过。
