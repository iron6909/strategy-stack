# 双环规则

通用工程原则由 [固定版本 pstack 的原则索引](ref/pstack/skills/poteto-mode/SKILL.md) 提供。这里记录双环业务规则及其执行位置。

| 规则 | 执行位置 |
|---|---|
| Grok/Linear 管需求、依赖与状态，工程或生产在本地执行 | PB-01、PB-02、PB-05 与派单 Schema |
| 源码经 PR 出货，代码和业务产物各有完成凭证 | Worker 的 PR 读回、项目生产回执、Linear 转换 |
| 默认独立只读跨厂终审，单 PR/SHA 可人工豁免厂商差异 | Worker 模型路由和 `waive` |
| 同一假设和门禁失败两次进入 Blocked | Worker 的持久尝试结果 |
| 中文草稿保留个人语气和发布审批 | PB-03 与 `cloud/skills/unslop-cn.md` |
| X 外发、付费、核心数据删除及平台安全和托管 Routine 变更由人操作 | 人工操作与部署权限 |
