---
name: bot-reincarnation
description: 主持常驻 Bot 的“N世”交接，避免长上下文膨胀与 200K 计费悬崖
---

# 成员“N世”交接规程

1. **触发条件**：某个 Bot 累积上下文超过 120,000 Tokens（提前避开 200K 全单翻倍的计费悬崖），且确认它在 Linear 中没有 `In Progress` 工单时启动。
2. **写交接说明**：让 `<名字> N世` 在 `~/court/succession/<office>-<N>-to-<N+1>.md` 写交接说明（包含职责书路径、任内新增的偏好、挂起的工单号、Routine 配置清单、3 条避坑提醒；不得包含任何明文密钥）。
3. **创建继任者**：调用 `CreateAgent` 创建 `<名字> <N+1>世`，使用 `~/court/offices/<office>.md` 的标准描述，并在末尾加上：`上任第一件事：读取 ~/studio_rules.md 与 ~/court/succession/<office>-<N>-to-<N+1>.md 完成交接。`
4. **确认与卸任**：`<N+1>世` 确认接手后，把前任改名为 `<名字> <N>世 (卸任)`，暂停前任所有定时 Routine，更新 `~/court/rolls.json` 里的成员指针，向 Sirus 发一句简报。
