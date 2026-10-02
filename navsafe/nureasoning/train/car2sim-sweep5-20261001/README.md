# 旧car2sim recipe的五组对照

场景e08a9f05，组合3M80k、3M40k、5M80k、3M160k、2.5M80k。3M/160k仍在运行，另外四组已完成。保留这五份配置用于不同recipe的对照和追溯已有结果。

这里Gaussian数字指非road MCMC上限，road另计；不能直接视为与新recipe同名setting等总预算。原来的初始化与物体MCMC设置保留，所有执行逻辑内嵌。

输出根：/avl-west/navsafe_nureasoning/sweep5-e08a9f05-20261001。metadata/保存实验选择与历史预检；每个Job在jobs/e08a9f05/，批量入口为kustomization.yaml。
