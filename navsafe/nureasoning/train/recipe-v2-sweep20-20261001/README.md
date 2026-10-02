# 当前 recipe v2 的20组实验

两个场景e08a9f05、660c2f7a，各运行3M80k、3M40k、5M80k、3M160k、2.5M80k，以及background Fourier dim1/5。总Gaussian预算包含road，各层按72/12/3/1/8/4比例缩放；LiDAR仅初始化，无LiDAR训练监督。seed42、FP32、1×3090、完整20s不切片。

每份Job中的recipe与全部训练命令都内嵌。MCMC、学习率周期随总步数调整；每四分之一进度保存checkpoint、原生验证图像和PSNR/SSIM。节点限制仍为ry06/07/11/12/13/14，排除ry08。

- jobs/660c2f7a/：10组。
- jobs/e08a9f05/：10组。
- metadata/matrix.json：逐实验配置、实际输出路径。
- metadata/validation.json：原生NRE预检。
- metadata/submission.json：原始提交记录；其中旧all20 manifest hash用于追溯原始提交。

输出根：/avl-west/navsafe_nureasoning/sweep20-recipev2-20261001-1812。原生验证保留训练后的物体姿态；当前NavSafe eval的raw-GT pose覆盖问题需要先修复，才能用于这批训练的质量排名。

完整实验方法与recipe工作副本在 /Users/hongwei/Desktop/avl/NavSafe-infty/deploy/nautilus/nureasoning_sweep20_20261001_1812/ 和 Nautilus对应repo目录。这里保留唯一的本地nautilus Job入口。
