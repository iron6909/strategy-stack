---
name: local-cross-audit
description: 本地 Gemini Pro 纯文本双轴只读审查与硬判定标准
---

# 本地双轴只读审查标准
由 `run-worker.sh` 在 `Pi` 完成后自动拉起 `agy -p`（Gemini Pro）执行**纯文本**审查：

## 调用与输入
- 调用参数固定：`agy --disable-slash-commands --dangerously-skip-permissions --print-timeout 15m -p "$PROMPT" < /dev/null`。
- 审查材料由 Bash 预打包成 `$WORKTREE_DIR/.task/review-bundle.txt`（脱敏、无 secret）：任务书原文、`.task/evidence/` 文本证据、变更文件清单、以及绑定到「当前已审 commit」的 `git diff`。
- prompt 首句硬性禁止调用任何工具（禁止 bash/shell/终端/文件读写/搜索/编辑/MCP），审查方只能读这条消息里的文本；`--dangerously-skip-permissions` 只解除弹出式授权，不授予工具使用权，也不代表允许改文件。
- 从 SSH 派发时，`agy` 检测到 SSH 会改走文件凭证并表现为未登录：脚本在子进程环境中摘掉 `SSH_CONNECTION`/`SSH_CLIENT`/`SSH_TTY`/`SSH_AUTH_SOCK`，复用本机已登录 keyring。严禁读取、拷贝、打印任何 token/凭据文件，严禁改平台安全控制，严禁创建或切换 named agent 账户。

## 双轴
- **Standards 轴**：核查是否遵守项目 `AGENTS.md`、类型安全及 `Laziness Protocol`。
- **Spec & Proof 轴**：核查是否 100% 交付 Ticket 要求的垂直切片行为，且 `.task/evidence/` 下存在真实运行证据。

## 硬判定（全部满足才算 PASS）
1. 报告写入 `.task/<工单号>-audit.md`，且**首行精确等于** `VERDICT: PASS`（前后无前缀、无 Markdown、无空行）。
2. `agy` 退出码为 0。
3. 报告非空。
4. 审查结束后重新比对：`HEAD` 仍等于已审 commit，且工作区相对审查前基线无新增改动。

任一条不成立即 `AUDIT_VERDICT=FAIL`（`agy_exit_*`、`empty_report`、`verdict_not_exact_first_line`、`post_audit_commit_changed`、`post_audit_worktree_changed`），一律不得合入。审查报告出现 `VERDICT: PASS` 但不是首行，同样判 FAIL。
