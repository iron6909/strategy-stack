# 剧本 PB-02：本地 Pi 算力调度与双绿灯自动合推 (Tailscale Dispatch & Auto-Merge)

> **适用场景**：执行 Linear 工部中处于 `Queued` 状态的具体编码、修 Bug 或构建工单。
> **核心铁律**：开工前必须将以下 Steps 1–4 **一字不差地原样复制**到你的执行 Todo 列表中逐项推进。

## 合推门禁（唯一标准）

仅当 `pi_exit == 0` **且** `audit_verdict == PASS`（本地 `agy` 纯文本审查首行恰为 `VERDICT: PASS`）时，`local/scripts/run-worker.sh` 才自动 `git merge --no-ff` 合入 base branch 并推送。`auto_merged == 1` 只在 merge 成功、push 成功、且脚本已用 `git fetch` + `merge-base --is-ancestor` 核实远端分支确实包含该 merge commit 之后才会出现；任何一步不成立都写证据、`AUTO_MERGED=0`、保留 worktree。代码工程合入的人工审批已取消；下方红线一条不减。

## 标准作业步骤 (Verbatim Todo Steps)

- [ ] **Step 1: 读取 Linear 配置并向本地工作树写入五要素任务书 (`Prepare Task Prompt on Ubuntu`)**
  1. 读取 `~/court/linear_config.json` 与目标 Linear 工单详情（如 `MOZ-12`）。
  2. 通过 Tailscale SSH 连接本地 Ubuntu 迷你主机（`banko` 账户），在 `/tmp/<工单号>-prompt.md` 生成任务书，必须包含：工单目标、必读 `AGENTS.md`/`GLOSSARY.md`、五步真实验证要求（将截图/日志写入 `.task/evidence/`）以及二败强制回滚约束。
  3. 任务书必须写明：Done Check 逐条可判定；实施者须把改动提交到 `feat/<工单号>`，留下未提交改动会让审查门禁直接判 FAIL（`dirty_worktree`）。

- [ ] **Step 2: 后台唤醒本地确定性执行器并立即休眠 (`Trigger run-worker.sh & Sleep`)**
  通过 Tailscale SSH 在本地 Ubuntu 后台拉起 `~/strategy-stack/local/scripts/run-worker.sh`：
  ```bash
  nohup ~/strategy-stack/local/scripts/run-worker.sh \
    --repo "$REPO_PATH" \
    --ticket "$TICKET_ID" \
    --prompt-file "/tmp/$TICKET_ID-prompt.md" \
    --base-branch "main" > "/tmp/$TICKET_ID-worker.log" 2>&1 &
  ```
  脚本既定行为（无需云端介入）：`pi --mode json ... < /dev/null` 实现 → Bash 打包 `.task/review-bundle.txt`（任务书 + `.task/evidence/` 文本证据 + 文件清单 + 绑定已审 commit 的 `git diff`）→ `agy --disable-slash-commands --dangerously-skip-permissions --print-timeout 15m -p ... < /dev/null` 纯文本审查（prompt 首句硬禁 bash/shell/文件工具，首行必须恰为 `VERDICT: PASS` 或 `VERDICT: FAIL`，报告落 `.task/<工单号>-audit.md`）→ 双绿灯后 `--no-ff` 合推并在推送后核实远端。
  将 Linear 工单状态更新为 `states.mozi_eng["In Progress"]` 后，**立即结束当前回合休眠**，静待 Webhook 回调唤醒。

- [ ] **Step 3: 接收 Webhook 回调并按 `auto_merged` 分流 (`Process Callback`)**
  被 Webhook 唤醒后，通过 Tailscale 读取 `.task/<工单号>-audit.md`、`.task/<工单号>-merge.txt`、`.task/webhook-payload.json` 与 `evidence_dir`：
  - **`auto_merged == 1`**：本地已 `--no-ff` 合入 `main` 且推送核实成功（`merge_commit` 已在远端）。在工单评论区贴出交付摘要、`agy` 审查结论、`merge_commit`、`review_bundle` 与 `evidence_dir`，将工单直接推进为 **`Done`**，并在**同一回合**继续 Step 4。
  - **`auto_merged == 0` 且返工未满 2 次**：把 `audit_reason` / `merge_reason`（如 `verdict_fail`、`empty_report`、`verdict_not_exact_first_line`、`dirty_worktree`、`post_audit_worktree_changed`、`base_changed`、`merge_conflict`、`push_rejected`）与审查缺陷追加进提示词，调 `run-worker.sh --resume "$session_file"` 原地返工。
  - **回调 JSON 缺少 `auto_merged` 字段**（旧版脚本）：一律视为未合入，**严禁**擅自标 `Done`，按 `audit_verdict` 转人工核验。
  - **连续 2 次同一假设失败**：确认本地工作区已回滚，将工单挂 **`Blocked`**，以 `Blocked` 状态报给 Sirus。
  - 并发锁（`[LOCK_BLOCKED]`）、基线变化、脏仓库、merge 冲突、推送拒绝：`AUTO_MERGED=0`，worktree 与证据保留；脚本从不 `--force` 删除工作树，证据先归档到 `~/task-archive/<工单号>/`。

- [ ] **Step 4: 同一回合派发父 Spec 下下一个已解锁 Queued 子单 (`Dispatch Next Queued Slice`)**
  仅当上一步拿到 `auto_merged == 1` 时执行：
  1. 查父 Spec（如 `MOZ-10`）下的子工单，把被当前工单 `Blocking` 且前置依赖已清零的 `Blocked` 子单改为 **`Queued`**。
  2. 在同一回合按 Step 1–2 直接派发下一个 `Queued` 子单，不留待人工点头。
  3. 父 Spec 下已无 `Queued`/`Blocked` 子单时，向 Sirus 报一句父 Spec 终验摘要（列各子单 `merge_commit`）。

## 红线（永不自动化）

代码工程合并的人工审批已取消，但以下动作必须保留人工卡口，任何剧本、脚本或 Bot 都不得自行执行：**X 发帖/回复/私信、任何付费与订阅、删除核心数据**、修改凭据/Webhook 密钥/平台安全控制、改动托管 skills 与 Routine。

## 仓库政策

本仓库只放规范与脚本。`~/court/` 整目录与 `/home/box/studio_rules.md` 一律不提交进本仓库（不提交路径下的内容）；需要引用时只写「读取 `~/court/...`」这类运行时指令。
