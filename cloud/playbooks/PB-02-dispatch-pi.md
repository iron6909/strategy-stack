# 剧本 PB-02：本地 Pi 算力调度与异构验收呈报 (Tailscale Dispatch & Report)

> **适用场景**：执行 Linear 工部中处于 `Queued` 状态的具体编码、修 Bug 或构建工单。
> **核心铁律**：开工前必须将以下 Steps 1–4 **一字不差地原样复制**到你的执行 Todo 列表中逐项推进。

## 标准作业步骤 (Verbatim Todo Steps)

- [ ] **Step 1: 读取 Linear 配置并向本地工作树写入五要素任务书 (`Prepare Task Prompt on Ubuntu`)**
  1. 读取 `~/court/linear_config.json` 与目标 Linear 工单详情（如 `MOZ-12`）。
  2. 通过 Tailscale SSH 连接本地 Ubuntu 迷你主机（`banko` 账户），在 `/tmp/<工单号>-prompt.md` 生成任务书，必须包含：工单目标、必读 `AGENTS.md`/`GLOSSARY.md`、五步真实验证要求（将截图/日志写入 `.task/evidence/`）以及二败强制回滚约束。

- [ ] **Step 2: 后台唤醒本地确定性执行器并立即休眠 (`Trigger run-worker.sh & Sleep`)**
  通过 Tailscale SSH 在本地 Ubuntu 后台拉起 `~/strategy-stack/local/scripts/run-worker.sh`：
  ```bash
  nohup ~/strategy-stack/local/scripts/run-worker.sh \
    --repo "$REPO_PATH" \
    --ticket "$TICKET_ID" \
    --prompt-file "/tmp/$TICKET_ID-prompt.md" \
    --base-branch "main" > "/tmp/$TICKET_ID-worker.log" 2>&1 &
  ```
  将 Linear 工单状态更新为 `states.mozi_eng["In Progress"]` 后，**立即结束当前回合休眠**，静待 Webhook 回调唤醒。

- [ ] **Step 3: 接收 Webhook 回调并核验本地双轴审查报告 (`Process Callback & Audit Report`)**
  被 Webhook 唤醒后，通过 Tailscale 读取本地审查报告 `.task/<工单号>-audit.md` 与 `.task/evidence/` 证据摘要：
  - **若 `pi_exit == 0` 且 `audit_verdict == PASS`**：在 Linear 工单评论区贴出结构化交付摘要、本地 Gemini Pro 审查结论及证据路径，将工单状态直接推进为 **`Needs Approval`**，以 `Done` 状态报给 Sirus 决定是否合入。
  - **若未通过且返工未满 2 次**：将具体缺陷追加写入提示词，调用 `run-worker.sh` 传入 `--resume "$session_file"` 原地恢复 `pi` 会话返工。
  - **若连续 2 次同一假设失败**：确认本地工作区已回滚，将 Linear 工单状态挂为 **`Blocked`**，以 `Blocked` 状态报给 Sirus。

- [ ] **Step 4: 解锁下游依赖工单 (`Unblock Dependent Tickets`)**
  当Sirus 批准合并当前工单后，检查 Linear 中被当前工单 `Blocking` 的后续子工单，若其所有前置依赖均已清零，将其状态从 `Blocked` 切换为 `Queued`。
