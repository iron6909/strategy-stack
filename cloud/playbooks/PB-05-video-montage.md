# PB-05 应用项目内容生产

1. 选择目标应用与该应用的生产入口，明确五要素、生产模式、验收和本次用户已授权的领域门禁。MyMontage 的产线、模型可用性、创作检查点和归档分类由 MyMontage 维护。
2. 创建 Linear 工单并按 PB-02 经 Tailscale 派发版本 1 请求，设置 `kind: production`，将应用参数放进 `options`。接单后再推进 In Progress。默认以 agy 的配置顺序尝试，人工指定优先。应用适配器以 `--dispatch`、`--result`、`--engine`、`--model` 接收本次参数。
3. 应用入口写明本次 `run_id`、`attempt`、`ticket`、`artifact`、`verification`、`archive`。Worker 仅在回执匹配本次请求并通过验证后发出 `produced`。按 PB-02 读回并结案。
4. 应用若返回 `awaiting_approval`，把阻塞交给操作者。批准后继续同一尝试。清理缓存按应用项目自己的规则进行。
