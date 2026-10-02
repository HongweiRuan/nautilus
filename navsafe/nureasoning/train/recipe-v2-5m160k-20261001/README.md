# Recipe v2: 5M / 160k 补充实验

**状态：原生NRE预检4/4通过；集群server dry-run因账号资源利用率过低拒绝4/4，未创建任何Job。待解除准入限制后提交。** 记录见[metadata/submission.json](metadata/submission.json)。

两个场景（660c2f7a、e08a9f05）各跑 background Fourier dim=1 / 5，共4个 Job。与当前 recipe-v2 的5M/80k配置相比，只延长训练及相关调度；seed=42，FP32，每个Job一张3090，CPU2核、内存64Gi。

预算包含所有层：background 3.6M、dynamic rigid 0.6M、dynamic deformable 0.15M、static deformable 0.05M、static rigid 0.4M、road 0.2M。所有场景用LiDAR初始化，不用LiDAR训练监督；完整20秒，不切片。

160k steps；MCMC增点20k开始、140k结束，扰动到160k；每40k做原生validation并存checkpoint，保留TensorBoard和原生输入/渲染结果。只训练background的MCMC增点，物体和road保持独立预算上限。

允许节点ry06/07/11/12/14。ry08、ry13当前有self-node-remediation NoSchedule，排除。不会修改现有20个实验。

所有执行命令和recipe内嵌在jobs/中。配置、SHA256、输出路径及原生NRE校验见metadata/。

```bash
kubectl apply -k /Users/hongwei/Desktop/avl/nautilus/navsafe/nureasoning/train/recipe-v2-5m160k-20261001
```

输出根目录：`/avl-west/navsafe_nureasoning/recipev2-5m160k-20261001-1932/`。
