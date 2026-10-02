# 失败实验恢复：2026-10-02

17个恢复Job：6个完整状态续训、11个没有checkpoint的实验重新训练。只处理未完成setting；已有8个成功实验保留。节点候选06/07/11/12/13/14，仍排除08；06/12/13/14当前有remediation NoSchedule，调度器会排除它们，隔离解除后可自动承接排队任务。不添加修复隔离toleration。

所有模型、Gaussian预算、160k/80k/40k总步数及学习率调度保持原样。checkpoint间隔改为10k；validation间隔不变。CPU2、RAM32Gi、GPU1×3090。6个续训保留原始out_dir和optimizer/scheduler/loops，init复制checkpoint到/scratch再加载；11个重跑复用原始输出目录的诊断记录。Job命令和recipe完整内嵌。

原始失败Job保留诊断。每个输出目录只有一个恢复Job，不与成功实验输出混用。metadata/recovery-plan.json记录原Job、resume step和路径、完整模型配置冻结hash。

```bash
kubectl apply -n cogrob -k /Users/hongwei/Desktop/avl/nautilus/navsafe/nureasoning/train/recovery-20261002
```

状态：17/17原生配置预检、17/17server dry-run通过。按用户最新优先级，仅提交新recipe的4个5M/160k：660c2f7a两组在ry11启动，e08a9f05两组等待GPU。其余13个已准备但未提交，避免抢占GPU。metadata/submission.json与startup-status.json记录实际状态。

上述apply -k命令会提交全部17个；当前优先4组已提交，不需要重复apply。
