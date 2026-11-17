#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=""
TICKET_ID=""
PROMPT_FILE=""
BASE_BRANCH="main"
RESUME_SESSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO_DIR="$2"; shift 2 ;;
    --ticket) TICKET_ID="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --base-branch) BASE_BRANCH="$2"; shift 2 ;;
    --resume) RESUME_SESSION="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$REPO_DIR" || -z "$TICKET_ID" || -z "$PROMPT_FILE" ]]; then
  echo "Usage: $0 --repo <path> --ticket <MOZ-12> --prompt-file <path> [--base-branch main] [--resume <session_jsonl>]"
  exit 1
fi

# 0. 无感拉取云端推送的最新 strategy-stack 规则
git -C "$HOME/strategy-stack" pull --ff-only >/dev/null 2>&1 || true

# 1. 24G 内存与 2 并发硬门禁检查
# 锚定完整命令词，避免 brave/grok/pipewire/acpi/napi 等含 "pi" 的无关进程被计入
ACTIVE_JOBS=$(pgrep -fc '(^|/)(pi|agy|ffmpeg)( |$)' || true)
FREE_MEM=$(free -m | awk '/^Mem:/{print $7}')
if [[ "$ACTIVE_JOBS" -ge 2 ]] || [[ "$FREE_MEM" -lt 6000 ]]; then
  echo "[GATE_BLOCKED] active_jobs=$ACTIVE_JOBS, free_mem=${FREE_MEM}MB (<6000MB)"
  exit 2
fi

# 2. 准备隔离的 Git Worktree
WORKTREE_ROOT="$(dirname "$REPO_DIR")/worktrees"
WORKTREE_DIR="$WORKTREE_ROOT/$TICKET_ID"
BRANCH_NAME="feat/$TICKET_ID"

mkdir -p "$WORKTREE_ROOT"
if [[ ! -d "$WORKTREE_DIR" ]]; then
  git -C "$REPO_DIR" fetch origin "$BASE_BRANCH" >/dev/null 2>&1 || true
  if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
    git -C "$REPO_DIR" worktree add "$WORKTREE_DIR" "$BRANCH_NAME"
  else
    git -C "$REPO_DIR" worktree add "$WORKTREE_DIR" -b "$BRANCH_NAME" "$BASE_BRANCH"
  fi
fi

mkdir -p "$WORKTREE_DIR/.task/sessions" "$WORKTREE_DIR/.task/evidence"
cp "$PROMPT_FILE" "$WORKTREE_DIR/.task/$TICKET_ID-prompt.md"

# 3. 无头运行 Pi Coding Agent（挂载 OpenCode Go 高配额模型）
cd "$WORKTREE_DIR"
set +e
if [[ -n "$RESUME_SESSION" && -f "$RESUME_SESSION" ]]; then
  pi --session-dir "$WORKTREE_DIR/.task/sessions" --session "$RESUME_SESSION" --mode json \
     -p "$(cat "$WORKTREE_DIR/.task/$TICKET_ID-prompt.md")" > "$WORKTREE_DIR/.task/$TICKET_ID.jsonl" 2>&1
else
  pi --session-dir "$WORKTREE_DIR/.task/sessions" --mode json \
     -p "$(cat "$WORKTREE_DIR/.task/$TICKET_ID-prompt.md")" > "$WORKTREE_DIR/.task/$TICKET_ID.jsonl" 2>&1
fi
PI_EXIT=$?
set -e

SES_FILE=$(ls -t "$WORKTREE_DIR/.task/sessions/"*.jsonl 2>/dev/null | head -n 1 || echo "")
AUDIT_FILE="$WORKTREE_DIR/.task/$TICKET_ID-audit.md"
AUDIT_VERDICT="SKIPPED"

# 4. 本地跨模型异构审查（调用 Gemini Pro agy -p 只读验收）
if [[ "$PI_EXIT" -eq 0 ]] && command -v agy >/dev/null 2>&1; then
  DIFF_SNIPPET=$(git -C "$WORKTREE_DIR" diff "$BASE_BRANCH"...HEAD | head -c 35000 || true)
  EVIDENCE_LIST=$(ls -la "$WORKTREE_DIR/.task/evidence/" 2>/dev/null || echo "None")
  set +e
  agy -p "你是独立只读代码审查官。请对照任务要求与项目 AGENTS.md，从【Standards 规范轴】与【Spec & Proof 实绩轴】审查以下变更与证据。首行必须输出 VERDICT: PASS 或 VERDICT: FAIL，随后按 [Act On]、[Consider]、[Dismissed] 三级分流输出精简中文报告：
=== 任务要求 ===
$(cat "$WORKTREE_DIR/.task/$TICKET_ID-prompt.md")
=== 证据文件列表 ===
$EVIDENCE_LIST
=== Git Diff ===
$DIFF_SNIPPET" > "$AUDIT_FILE" 2>&1
  set -e

  if grep -q "VERDICT: PASS" "$AUDIT_FILE"; then
    AUDIT_VERDICT="PASS"
  else
    AUDIT_VERDICT="FAIL"
  fi
fi

# 5. 触发 Webhook 回调叫醒云端【墨翟】
if [[ -f "$HOME/.harness/webhooks/mozi.env" ]]; then
  set -a; . "$HOME/.harness/webhooks/mozi.env"; set +a
  curl -s -X POST "$WEBHOOK_URL" \
    -H "Authorization: Bearer $WEBHOOK_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"ticket\": \"$TICKET_ID\", \"pi_exit\": $PI_EXIT, \"audit_verdict\": \"$AUDIT_VERDICT\", \"worktree\": \"$WORKTREE_DIR\", \"session_file\": \"$SES_FILE\", \"audit_file\": \"$AUDIT_FILE\"}" >/dev/null 2>&1 || true
fi

echo "[DONE] ticket=$TICKET_ID pi_exit=$PI_EXIT audit=$AUDIT_VERDICT session=$SES_FILE"
