---
name: bot-reincarnation
description: 主持常驻 Bot 的“N世”袭爵转世交接，规避长上下文膨胀与 200K 计费悬崖
---

# 百官“N世”袭爵转世规程

1. **触发门禁**：当某在任 Bot 累积上下文逾 120,000 Tokens（提前规避 Grok 4.7 200K 全单翻倍悬崖），且确认其在 Linear 中无 `In Progress` 活跃工单时启动。
2. **修撰交接记录**：命 `<名号> N世` 在 `~/court/succession/<office>-<N>-to-<N+1>.md` 生成交接记录（含：官职书指针、任内新立偏好、挂起工单号、Routine 配置清单、3 条避坑忠告；严禁包含任何明文密钥）。
3. **册封继任者**：调用 `CreateAgent` 创建 `<名号> <N+1>世`，加载 `~/court/offices/<office>.md` 标准描述，并在末尾注入：`上任首务：读取 ~/studio_rules.md 与 ~/court/succession/<office>-<N>-to-<N+1>.md 完成交接。`
4. **验印与致仕封存**：待 `<N+1>世` 确认接管后，将前任改名为 `<名号> <N>世 (致仕)`，暂停前任所有定时 Routine，更新 `~/court/rolls.json` 在任指针，向主公发送一句简报。
