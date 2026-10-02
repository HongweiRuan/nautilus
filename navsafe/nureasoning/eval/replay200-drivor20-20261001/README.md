# 五个已完成场景的评估配置

每场景2×3090：一个原生NuRec renderer，一个IsaacSim/DrivOR。执行全场ego replay200frames，以及ego replay20frames后由DrivOR控制；enable visualization，使用driver匹配的warm Omniverse Kit shader/material cache。控制评估可能因collision/goal提前结束。

这是已跑通的评估流程参考；相机渲染服务器、环境bootstrap和两段eval命令都直接内嵌YAML。五个Job原始SOURCE_RECON/OUTPUT_DIR保留，metadata/selection.json可查输入与结果路径。替换为新训练artifact时要同步更新这些路径。

当前评估代码用raw-GT poses覆盖训练后物体姿态，会额外造成模糊/抖动。修复该问题后再用此流程评价新20组训练的画质。此目录保留执行配置，没有重新提交eval。
