#!/usr/bin/env bash
# 派发本地 Pi 实现工单；纯文本异构审查首行 VERDICT: PASS 且 PI_EXIT=0 时，
# 自动 git merge --no-ff 合入 base branch 并推送（推送后必须核实远端已包含已审 commit）。
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

WORKTREE_ROOT="$(dirname "$REPO_DIR")/worktrees"
WORKTREE_DIR="$WORKTREE_ROOT/$TICKET_ID"
BRANCH_NAME="feat/$TICKET_ID"
TASK_DIR="$WORKTREE_DIR/.task"
EVIDENCE_DIR="$TASK_DIR/evidence"
PROMPT_COPY="$TASK_DIR/$TICKET_ID-prompt.md"
AUDIT_FILE="$TASK_DIR/$TICKET_ID-audit.md"
BUNDLE_FILE="$TASK_DIR/review-bundle.txt"
MERGE_LOG="$TASK_DIR/$TICKET_ID-merge.txt"
PAYLOAD_FILE="$TASK_DIR/webhook-payload.json"
ARCHIVE_DIR="$HOME/task-archive/$TICKET_ID"
LOCK_DIR="$WORKTREE_ROOT/.$TICKET_ID.lock"

# 2. 单票并发锁：同票并行会互相覆盖 worktree、审查报告与合推结论
mkdir -p "$WORKTREE_ROOT"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  LOCK_PID="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [[ -n "$LOCK_PID" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
    echo "[LOCK_BLOCKED] ticket=$TICKET_ID active_pid=$LOCK_PID lock=$LOCK_DIR"
    exit 3
  fi
  rm -rf "$LOCK_DIR"   # 进程已退出的陈旧锁直接接管
  mkdir "$LOCK_DIR"
fi
echo "$$" > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT

# 2.5 git common dir 工具（worktree 建好之前就要用，故定义在工具函数区之前）
# 所有 worktree 共用主仓同一个 .git/info/exclude：--repo 本身可能是 worktree，
# 必须解析成绝对路径，否则规则会被写进 worktree 里根本不存在的 .git/ 目录。
resolve_git_common_dir() {
  local repo="$1" abs_repo common
  abs_repo="$(cd "$repo" 2>/dev/null && pwd -P)" || return 1
  if common="$(git -C "$abs_repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
     && [[ "$common" == /* ]]; then
    printf '%s\n' "$common"
    return 0
  fi
  common="$(git -C "$abs_repo" rev-parse --git-common-dir)" || return 1
  [[ -n "$common" ]] || return 1
  # 旧 git / 相对输出：相对的是 repo 的实际路径（worktree 的 common dir 落在主仓 .git）
  [[ "$common" == /* ]] || common="$abs_repo/$common"
  printf '%s\n' "$common"
}

# .task/ out/ projects/ .pi/ 是脚本/运行时自产目录：写进主仓 info/exclude，重复调用不得产生重复行。
# exclude 只挡未跟踪文件，已 tracked 的 .task 只能靠 tree 检查，不能拿 ignore 当清除手段。
ensure_common_excludes() {
  local common="${1:-}" exclude entry
  [[ -n "$common" ]] || return 1
  exclude="$common/info/exclude"
  mkdir -p "$common/info" || return 1
  if [[ -s "$exclude" && -n "$(tail -c 1 "$exclude")" ]]; then
    printf '\n' >> "$exclude" || return 1   # 原文件末尾无换行时先补齐，避免粘连出错误规则
  fi
  for entry in '.task/' 'out/' 'projects/' '.pi/'; do
    if grep -qxF -- "$entry" "$exclude" 2>/dev/null; then
      continue
    fi
    printf '%s\n' "$entry" >> "$exclude" || return 1
  done
}

# 3. 准备隔离的 Git Worktree
mkdir -p "$WORKTREE_ROOT"
if [[ ! -d "$WORKTREE_DIR" ]]; then
  git -C "$REPO_DIR" fetch origin "$BASE_BRANCH" >/dev/null 2>&1 || true
  if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
    git -C "$REPO_DIR" worktree add "$WORKTREE_DIR" "$BRANCH_NAME"
  else
    git -C "$REPO_DIR" worktree add "$WORKTREE_DIR" -b "$BRANCH_NAME" "$BASE_BRANCH"
  fi
fi

# worktree 建好（或复用既有 worktree）立即写 exclude：解析或写入失败一律失败退出
COMMON_DIR="$(resolve_git_common_dir "$WORKTREE_DIR")" || {
  echo "[FAIL] 无法解析 git common dir: worktree=$WORKTREE_DIR"
  exit 4
}
ensure_common_excludes "$COMMON_DIR" || {
  echo "[FAIL] 无法写入 $COMMON_DIR/info/exclude"
  exit 4
}

mkdir -p "$TASK_DIR/sessions" "$EVIDENCE_DIR"
cp "$PROMPT_FILE" "$PROMPT_COPY"
: > "$MERGE_LOG"

# 4. 无头运行 Pi Coding Agent（挂载 OpenCode Go 高配额模型，stdin 必须闭合）
cd "$WORKTREE_DIR"
set +e
if [[ -n "$RESUME_SESSION" && -f "$RESUME_SESSION" ]]; then
  pi --session-dir "$TASK_DIR/sessions" --session "$RESUME_SESSION" --mode json \
     -p "$(cat "$PROMPT_COPY")" > "$TASK_DIR/$TICKET_ID.jsonl" 2>&1 < /dev/null
else
  pi --session-dir "$TASK_DIR/sessions" --mode json \
     -p "$(cat "$PROMPT_COPY")" > "$TASK_DIR/$TICKET_ID.jsonl" 2>&1 < /dev/null
fi
PI_EXIT=$?
set -e

SES_FILE=$(ls -t "$TASK_DIR/sessions/"*.jsonl 2>/dev/null | head -n 1 || echo "")
AUDIT_VERDICT="SKIPPED"
AUDIT_REASON="pi_failed"
AGY_EXIT=""
AUDITED_COMMIT=""
AUDITED_BASE=""
AUTO_MERGED=0
MERGE_COMMIT=""
MERGE_REASON="not_attempted"

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------

# 工作区指纹：HEAD + 受版本控制的改动 + 未跟踪文件清单
# .task/ 与 .pi/ 为脚本/运行时自产，排除；这里不依赖 info/exclude，规则缺失时也能自兜
# shortcut: 未跟踪文件只比对文件名不比对内容，出现「审查后改写未跟踪文件」时升级
worktree_state() {
  {
    git -C "$WORKTREE_DIR" rev-parse HEAD
    git -C "$WORKTREE_DIR" status --porcelain -uall | grep -vE '^\?\? \.(task|pi)/' || true
    git -C "$WORKTREE_DIR" diff HEAD
  } | sha256sum | cut -d' ' -f1
}

worktree_dirty() {
  [[ -n "$(git -C "$WORKTREE_DIR" status --porcelain -uall | grep -vE '^\?\? \.(task|pi)/' || true)" ]]
}

# 审查前失败出口：写明确 reason（无空格，直接进 webhook JSON），由调用方决定不进审查
audit_fail() { AUDIT_VERDICT="FAIL"; AUDIT_REASON="$1"; }

# 让即将送审的 tip 树不含 .task/，且清理动作本身必须成为待审提交的一部分：
# 1) 已 tracked 的 .task -> git rm -r --cached + 提交（否则审查后改 index 就是审非所合）
# 2) --no-ff 会把中间提交的 .task blob 带进 main 历史 -> 仅对未合入的 feat 分支做
#    reset --soft（禁止 --hard / force-push）后再提交一棵同树的干净 tip
# 3) 最后以 tree 为准复核（git add -f 能绕过 exclude，只有 tree 说了算）
# 任何一步失败都返回非零，不吞错；原本就没有 tracked .task 是成功的 no-op。
sanitize_audited_tip() {
  local tracked orig_subject range commit task_paths
  if ! tracked="$(git -C "$WORKTREE_DIR" ls-files -- .task)"; then
    audit_fail task_ls_files_failed; return 1
  fi
  orig_subject="$(git -C "$WORKTREE_DIR" log -1 --format=%s)" || orig_subject=""
  if [[ -n "$tracked" ]]; then
    if ! git -C "$WORKTREE_DIR" rm -r --cached --quiet -- .task; then
      audit_fail task_untrack_failed; return 1
    fi
    if ! git -C "$WORKTREE_DIR" commit -q -m "chore: untrack .task evidence from version control"; then
      audit_fail task_untrack_commit_failed; return 1
    fi
  fi
  if ! range="$(git -C "$WORKTREE_DIR" rev-list "$AUDITED_BASE..HEAD")"; then
    audit_fail task_history_check_failed; return 1
  fi
  for commit in $range; do
    if ! task_paths="$(git -C "$WORKTREE_DIR" ls-tree -r --name-only "$commit" -- .task)"; then
      audit_fail task_history_check_failed; return 1
    fi
    if [[ -n "$task_paths" ]]; then
      [[ -n "$orig_subject" ]] || orig_subject="feat: $TICKET_ID"
      if ! git -C "$WORKTREE_DIR" reset --soft "$AUDITED_BASE"; then
        audit_fail task_history_squash_failed; return 1
      fi
      if ! git -C "$WORKTREE_DIR" commit -q -m "$orig_subject"; then
        audit_fail task_history_squash_failed; return 1
      fi
      break
    fi
  done
  if ! task_paths="$(git -C "$WORKTREE_DIR" ls-tree -r --name-only HEAD -- .task)"; then
    audit_fail task_tree_check_failed; return 1
  fi
  if [[ -n "$task_paths" ]]; then
    audit_fail task_dir_in_audited_tree; return 1
  fi
  return 0
}

# shortcut: 只脱敏已知前缀与已知变量名，出现新密钥格式时升级
redact() {
  sed -E \
    -e 's/(sk-|ghp_|gho_|github_pat_|xoxb-)[A-Za-z0-9_-]{8,}/\1[REDACTED]/g' \
    -e 's/([Bb]earer[[:space:]]+)[A-Za-z0-9._-]{8,}/\1[REDACTED]/g' \
    -e 's/((WEBHOOK_URL|WEBHOOK_KEY|_TOKEN|_SECRET|_KEY|_PASSWORD)[[:space:]]*[=:][[:space:]]*)[^[:space:]"]+/\1[REDACTED]/g'
}

# 审查材料一律由 Bash 预打包成纯文本，审查方无任何工具可调用
build_review_bundle() {
  local f
  {
    echo "# REVIEW BUNDLE ticket=$TICKET_ID"
    echo "audited_base=$AUDITED_BASE"
    echo "audited_commit=$AUDITED_COMMIT"
    echo "branch=$BRANCH_NAME base_branch=$BASE_BRANCH"
    echo
    echo "## 1. 任务书（原文）"
    cat "$PROMPT_COPY"
    echo
    echo "## 2. 变更文件清单"
    git -C "$WORKTREE_DIR" diff --name-status "$AUDITED_BASE...$AUDITED_COMMIT"
    echo
    echo "## 3. 绑定已审 commit 的 diff（$AUDITED_BASE...$AUDITED_COMMIT）"
    git -C "$WORKTREE_DIR" diff "$AUDITED_BASE...$AUDITED_COMMIT" > "$TASK_DIR/.diff.tmp" || true
    head -c 60000 "$TASK_DIR/.diff.tmp"
    rm -f "$TASK_DIR/.diff.tmp"
    echo
    echo "## 4. .task/evidence/ 文本证据"
    while read -r f; do
      grep -Iq . "$f" 2>/dev/null || continue   # 跳过二进制与空文件
      echo "--- ${f#"$WORKTREE_DIR"/} ---"
      head -c 8000 "$f"
      echo
    done < <(find "$EVIDENCE_DIR" -type f -size -256k 2>/dev/null | sort)
  } 2>&1 | redact > "$BUNDLE_FILE"
}

# 双绿灯合推：任何一步不成立都只写证据并 AUTO_MERGED=0，绝不 --force
merge_and_push() {
  local remote_base new_head parent_count audited_task_paths

  echo "== merge attempt $(date -Is) ticket=$TICKET_ID" >> "$MERGE_LOG"
  echo "audited_base=$AUDITED_BASE audited_commit=$AUDITED_COMMIT base_branch=$BASE_BRANCH repo=$REPO_DIR" >> "$MERGE_LOG"

  # 合入前闭锁：只认已审 SHA 的 tree，index/ignore 规则都不作数。
  # 此阶段禁止 git rm / 新提交 / 改 SHA——发现问题只能拒合，留下 worktree 与证据。
  if [[ "$(git -C "$WORKTREE_DIR" rev-parse HEAD)" != "$AUDITED_COMMIT" ]]; then
    MERGE_REASON="post_audit_commit_changed"; return 1
  fi
  if ! audited_task_paths="$(git -C "$WORKTREE_DIR" ls-tree -r --name-only "$AUDITED_COMMIT" -- .task)"; then
    MERGE_REASON="audited_tree_unreadable"; return 1
  fi
  if [[ -n "$audited_task_paths" ]]; then
    MERGE_REASON="task_dir_in_audited_tree"
    echo "audited tree still tracks .task:" >> "$MERGE_LOG"
    echo "$audited_task_paths" >> "$MERGE_LOG"
    return 1
  fi

  if ! git -C "$REPO_DIR" fetch origin "$BASE_BRANCH" >> "$MERGE_LOG" 2>&1; then
    MERGE_REASON="fetch_failed"; return 1
  fi
  remote_base="$(git -C "$REPO_DIR" rev-parse "refs/remotes/origin/$BASE_BRANCH")"
  echo "remote_base=$remote_base" >> "$MERGE_LOG"

  # 已审基线 = 审查时的远端 base tip；被别人推进过就必须重审，不得合入未审组合
  if [[ "$remote_base" != "$AUDITED_BASE" ]]; then
    MERGE_REASON="base_changed"; return 1
  fi

  if [[ "$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)" != "$BASE_BRANCH" ]]; then
    if ! git -C "$REPO_DIR" checkout "$BASE_BRANCH" >> "$MERGE_LOG" 2>&1; then
      MERGE_REASON="repo_not_on_base"; return 1
    fi
  fi
  if [[ -n "$(git -C "$REPO_DIR" status --porcelain -uno || true)" ]]; then
    MERGE_REASON="repo_dirty"; return 1
  fi
  if ! git -C "$REPO_DIR" merge --ff-only "$remote_base" >> "$MERGE_LOG" 2>&1; then
    MERGE_REASON="base_diverged"; return 1
  fi

  # 幂等：远端 base 已含本次已审 commit（上一轮已合推成功）
  if git -C "$REPO_DIR" merge-base --is-ancestor "$AUDITED_COMMIT" "$remote_base"; then
    AUTO_MERGED=1
    MERGE_COMMIT="$remote_base"
    MERGE_REASON="already_merged"
    echo "already merged: origin/$BASE_BRANCH=$remote_base" >> "$MERGE_LOG"
    return 0
  fi

  if ! git -C "$REPO_DIR" merge --no-ff --no-edit "$AUDITED_COMMIT" >> "$MERGE_LOG" 2>&1; then
    git -C "$REPO_DIR" merge --abort >> "$MERGE_LOG" 2>&1 || true
    MERGE_REASON="merge_conflict"; return 1
  fi

  new_head="$(git -C "$REPO_DIR" rev-parse HEAD)"
  MERGE_COMMIT="$new_head"
  parent_count="$(git -C "$REPO_DIR" rev-list --parents -n 1 "$new_head" | awk '{print NF}')"
  if [[ "$new_head" == "$remote_base" || "$parent_count" -ne 3 ]]; then
    MERGE_REASON="merge_not_no_ff_commit"; return 1
  fi
  if ! git -C "$REPO_DIR" merge-base --is-ancestor "$AUDITED_COMMIT" "$new_head"; then
    MERGE_REASON="merge_missing_audited_commit"; return 1
  fi

  if ! git -C "$REPO_DIR" push origin "$BASE_BRANCH" >> "$MERGE_LOG" 2>&1; then
    MERGE_REASON="push_rejected"; return 1
  fi
  # 不信 push 的退出码：fetch 后核实远端分支确实包含本次 merge commit
  if ! git -C "$REPO_DIR" fetch origin "$BASE_BRANCH" >> "$MERGE_LOG" 2>&1; then
    MERGE_REASON="post_push_fetch_failed"; return 1
  fi
  if ! git -C "$REPO_DIR" merge-base --is-ancestor "$MERGE_COMMIT" "refs/remotes/origin/$BASE_BRANCH"; then
    MERGE_REASON="remote_missing_merge_commit"; return 1
  fi

  AUTO_MERGED=1
  MERGE_REASON="merged_and_pushed"
  echo "pushed merge_commit=$MERGE_COMMIT" >> "$MERGE_LOG"
  return 0
}

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# 审查与测试证据先脱出 worktree（worktree 永不由本脚本 --force 删除）
archive_evidence() {
  mkdir -p "$ARCHIVE_DIR"
  cp -a "$EVIDENCE_DIR" "$ARCHIVE_DIR/" 2>/dev/null || true
  cp -a "$AUDIT_FILE" "$BUNDLE_FILE" "$MERGE_LOG" "$TASK_DIR/$TICKET_ID.jsonl" "$ARCHIVE_DIR/" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 5. 纯文本异构审查（Gemini Pro agy -p，只读、无工具、首行硬判定）
# ---------------------------------------------------------------------------
if [[ "$PI_EXIT" -eq 0 ]]; then
  git -C "$WORKTREE_DIR" fetch origin "$BASE_BRANCH" >/dev/null 2>&1 || true
  AUDITED_BASE="$(git -C "$WORKTREE_DIR" rev-parse "refs/remotes/origin/$BASE_BRANCH" 2>/dev/null \
    || git -C "$WORKTREE_DIR" rev-parse "$BASE_BRANCH")"

  # 审查前清理：先摘掉已 tracked 的 .task/ 再绑已审 SHA，审查指纹才对得上干净树
  TIP_CLEAN=1
  sanitize_audited_tip || TIP_CLEAN=0

  AUDITED_COMMIT="$(git -C "$WORKTREE_DIR" rev-parse HEAD)"
  COMMITS_AHEAD="$(git -C "$WORKTREE_DIR" rev-list --count "$AUDITED_BASE..$AUDITED_COMMIT" 2>/dev/null || echo 0)"
  STATE_AT_AUDIT="$(worktree_state)"

  if [[ "$TIP_CLEAN" -ne 1 ]]; then
    echo "tip not clean: $AUDIT_REASON" >> "$MERGE_LOG"   # sanitize_audited_tip 已写入精确 reason
  elif worktree_dirty; then
    AUDIT_VERDICT="FAIL"; AUDIT_REASON="dirty_worktree"
  elif [[ "$COMMITS_AHEAD" -lt 1 ]] && ! git -C "$WORKTREE_DIR" merge-base --is-ancestor "$AUDITED_COMMIT" "$AUDITED_BASE"; then
    # 例外：本分支已合入 base（重复执行），此时 commits_ahead=0 属正常幂等
    AUDIT_VERDICT="FAIL"; AUDIT_REASON="no_commits_ahead_of_base"
  elif ! command -v agy >/dev/null 2>&1; then
    AUDIT_VERDICT="FAIL"; AUDIT_REASON="agy_missing"
  else
    build_review_bundle
    AUDIT_PROMPT="你是独立只读代码审查官，本轮只做纯文本审查。
【硬性禁令】禁止调用任何工具：不得使用 bash/shell/终端/文件读写/搜索/编辑/MCP 等任何工具或扩展命令，你只能阅读本条消息里的文本。违反本禁令即判 FAIL。
【输出格式】第一行必须且只能是下面两者之一，前后不得有任何字符、反引号、标题或空行：
VERDICT: PASS
VERDICT: FAIL
第二行起按 [Act On]、[Consider]、[Dismissed] 三级分流输出精简中文报告，覆盖 Standards 规范轴（AGENTS.md 约定、类型安全、Laziness Protocol）与 Spec & Proof 实绩轴（任务书 Done Check 是否 100% 交付、证据是否真实可复核）。
【审查材料】
$(cat "$BUNDLE_FILE")"

    set +e
    # SSH 会话下 agy 会改走文件凭证并表现为未登录：子进程摘掉 SSH_* 复用本机已登录 keyring。
    # 只摘环境变量，不读取/拷贝/打印任何 token 或凭据文件，不改平台安全控制。
    env -u SSH_CONNECTION -u SSH_CLIENT -u SSH_TTY -u SSH_AUTH_SOCK \
      agy --disable-slash-commands --dangerously-skip-permissions --print-timeout 15m \
      -p "$AUDIT_PROMPT" < /dev/null > "$AUDIT_FILE" 2>&1
    AGY_EXIT=$?
    set -e

    AUDIT_FIRST="$(sed -n '1p' "$AUDIT_FILE" 2>/dev/null | tr -d '\r' | sed -e 's/[[:space:]]*$//')"
    if [[ "$AGY_EXIT" -ne 0 ]]; then
      AUDIT_VERDICT="FAIL"; AUDIT_REASON="agy_exit_$AGY_EXIT"
    elif [[ ! -s "$AUDIT_FILE" ]]; then
      AUDIT_VERDICT="FAIL"; AUDIT_REASON="empty_report"
    elif [[ "$AUDIT_FIRST" == "VERDICT: PASS" ]]; then
      AUDIT_VERDICT="PASS"; AUDIT_REASON="ok"
    elif [[ "$AUDIT_FIRST" == "VERDICT: FAIL" ]]; then
      AUDIT_VERDICT="FAIL"; AUDIT_REASON="verdict_fail"
    else
      AUDIT_VERDICT="FAIL"; AUDIT_REASON="verdict_not_exact_first_line"
    fi

    # 审查结束后已审 commit 或工作区被改动 = 审的不是要合的东西
    if [[ "$AUDIT_VERDICT" == "PASS" ]]; then
      if [[ "$(git -C "$WORKTREE_DIR" rev-parse HEAD)" != "$AUDITED_COMMIT" ]]; then
        AUDIT_VERDICT="FAIL"; AUDIT_REASON="post_audit_commit_changed"
      elif [[ "$(worktree_state)" != "$STATE_AT_AUDIT" ]]; then
        AUDIT_VERDICT="FAIL"; AUDIT_REASON="post_audit_worktree_changed"
      fi
    fi
  fi
fi

# 6. 仅双绿灯合推
if [[ "$PI_EXIT" -eq 0 && "$AUDIT_VERDICT" == "PASS" ]]; then
  echo "[MERGE] audited_commit=$AUDITED_COMMIT base=$AUDITED_BASE" >> "$MERGE_LOG"
  if ! merge_and_push; then
    AUTO_MERGED=0
    echo "abort: $MERGE_REASON" >> "$MERGE_LOG"
  fi
fi

# 7. 写出 Webhook JSON（向后兼容：老字段名与类型不变，新增合推与持久证据字段）
mkdir -p "$ARCHIVE_DIR"
cat > "$PAYLOAD_FILE" <<JSON
{
  "ticket": "$(json_escape "$TICKET_ID")",
  "pi_exit": $PI_EXIT,
  "audit_verdict": "$(json_escape "$AUDIT_VERDICT")",
  "audit_reason": "$(json_escape "$AUDIT_REASON")",
  "auto_merged": $AUTO_MERGED,
  "merge_commit": "$(json_escape "${MERGE_COMMIT:-}")",
  "merge_reason": "$(json_escape "$MERGE_REASON")",
  "audited_commit": "$(json_escape "${AUDITED_COMMIT:-}")",
  "audited_base": "$(json_escape "${AUDITED_BASE:-}")",
  "base_branch": "$(json_escape "$BASE_BRANCH")",
  "worktree": "$(json_escape "$WORKTREE_DIR")",
  "session_file": "$(json_escape "$SES_FILE")",
  "audit_file": "$(json_escape "$AUDIT_FILE")",
  "review_bundle": "$(json_escape "$BUNDLE_FILE")",
  "merge_log": "$(json_escape "$MERGE_LOG")",
  "evidence_dir": "$(json_escape "$ARCHIVE_DIR")"
}
JSON

archive_evidence

if [[ -f "$HOME/.harness/webhooks/mozi.env" ]]; then
  set -a; . "$HOME/.harness/webhooks/mozi.env"; set +a
  curl -s -X POST "$WEBHOOK_URL" \
    -H "Authorization: Bearer $WEBHOOK_KEY" \
    -H "Content-Type: application/json" \
    -d @"$PAYLOAD_FILE" >/dev/null 2>&1 || true
fi

# worktree 永不自动删除：失败保留现场，清理由 PB-04 人工执行且禁止 --force
echo "[DONE] ticket=$TICKET_ID pi_exit=$PI_EXIT audit=$AUDIT_VERDICT audit_reason=$AUDIT_REASON auto_merged=$AUTO_MERGED merge_commit=${MERGE_COMMIT:-NONE} merge_reason=$MERGE_REASON session=$SES_FILE"
