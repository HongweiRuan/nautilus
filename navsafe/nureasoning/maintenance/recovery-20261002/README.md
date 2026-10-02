# 恢复诊断

两个有限CPU Job，每个1CPU/2Gi，无GPU：checkpoint-audit读取25个实验的checkpoint元数据；recipe-preflight验证17份恢复配置及模型/损失/学习率与原配置一致。命令完整内嵌，17份预检recipe数据经过gzip编码以避免Linux单参数128KiB限制；实际训练Job仍包含完整可读recipe。

诊断输出：/avl-west/navsafe_nureasoning/recovery-20261002/。初次未压缩的CPU预检因argument list too long失败，r1修复后的配置是本目录保留版本。
