# 成功的full8最终基线

只保留已成功产出八个场景重建的最终r3版本。初版/r1/r2配置和重试清单已清理。Job名称仍保留-r3，便于与PVC日志和结果对应。

这套Job包含数据准备、原生aux和训练bootstrap，作为完整pipeline复现参考。训练为160ksteps、非road Gaussian上限5M，LiDAR初始化、关闭LiDAR训练监督、八相机、20s不切片。它是已观察到画质问题的旧car2sim派生recipe，当前优先实验位于recipe-v2-sweep20-20261001。

结果根：/avl-west/navsafe_nureasoning/full8-lidarinit-20261001/recon。metadata/selection-2026-verified.json保存HF revision、八场景与传感器审计。metadata/validation.json是历史预检，实际最终执行以这八份Job里的内嵌配置为准。
