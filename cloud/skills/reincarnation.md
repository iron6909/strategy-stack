---
name: bot-reincarnation
description: 主持常驻 Bot 的“N世”交接，避免长上下文膨胀与 200K 计费悬崖
---

# 成员“N世”交接规程

1. **触发条件**：某个 Bot 累积上下文超过 120,000 Tokens（提前避开 200K 全单翻倍的计费悬崖），且确认它在 Linear 中没有 `In Progress` 工单时启动。
2. **写交接说明**：让 `<名字> N世` 在 `~/court/succession/<office>-<N>-to-<N+1>.md` 写交接说明（包含职责书路径、任内新增的偏好、挂起的工单号、Routine 配置清单、3 条避坑提醒；不得包含任何明文密钥）。
3. **准备继任者**：根据 `~/court/offices/<office>.md` 准备继任描述和交接说明。交接中的本地任务附 run/attempt 和持久回执，只读核对 PR、审批与未完成门禁。
4. **确认与卸任**：请 Sirus 通过托管入口确认创建、停用及 Routine 切换。继任者确认接手后再更新 `~/court/rolls.json`，保留已确认的交接记录，避免重复切换。
