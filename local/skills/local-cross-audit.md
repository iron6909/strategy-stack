---
name: local-cross-audit
description: 本地 Gemini Pro 跨模型双轴只读审查标准
---

# 本地双轴只读审查标准
由 `run-worker.sh` 在 `Pi` 完成后自动拉起 `agy -p`（Gemini Pro）执行只读审查：
- **Standards 轴**：核查是否遵守项目 `AGENTS.md`、类型安全及 `Laziness Protocol`。
- **Spec & Proof 轴**：核查是否 100% 交付 Ticket 要求的垂直切片行为，且 `.task/evidence/` 下存在真实运行证据。
