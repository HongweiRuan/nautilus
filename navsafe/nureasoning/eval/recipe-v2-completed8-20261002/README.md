# Recipe v2 completed8 eval

8 个已经完成的新 recipe 实验，共16次eval。每个Job使用2张3090：NuRec renderer和IsaacSim/DrivOR各1张；连续运行两种模式。

- `ego_replay_200`：全程200帧replay。
- `drivor_replay20_total200`：前20帧replay，其后最多180帧DrivOR控制；正常碰撞或终点可提前结束。

均启用visualization，输出topdown.gif、cam_f0.gif、combined.gif。按GPU driver恢复 `/avl-west/navsafe_dev/kitcache/kitcache-3090-<driver>.tar`；日志明确记录恢复成功、失败或缺失。

NuRec actor editing关闭；客户端尊重服务器配置，保留训练后的物体轨迹，不用raw-GT覆盖。ego仍按replay/DrivOR控制。BEV和碰撞仍使用数据集的symbolic actor tracks；训练校正、以及spawn guard临时扣留actor时，视觉和碰撞状态可能存在差异。此批次用于同一渲染策略下比较新recipe，未修改碰撞标注。

完整command/args都在jobs中的YAML里。两种eval在独立目录保存，临时环境和渲染输出先写本地磁盘，结束复制到PVC；失败也保留输出。

```bash
kubectl apply -k /Users/hongwei/Desktop/avl/nautilus/navsafe/nureasoning/eval/recipe-v2-completed8-20261002
kubectl get jobs,pods -n cogrob -l batch=nureasoning-eval8-20261002
```

结果根目录：`/avl-west/navsafe_nureasoning/eval-v2-completed8-20261002/<experiment_id>/`。

场景、预算、步数、background Fourier dim、训练来源和eval目录见[metadata/selection.json](metadata/selection.json)。Job提交记录和状态以metadata中的时间为准。
