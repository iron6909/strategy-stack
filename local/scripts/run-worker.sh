#!/usr/bin/env bash
# 派发本地 Pi 实现工单；纯文本异构审查首行 VERDICT: PASS 且 PI_EXIT=0 时，
# 自动 git merge --no-ff 合入 base branch 并推送（推送后必须核实远端已包含已审 commit）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/providers-env.sh
. "$SCRIPT_DIR/lib/providers-env.sh"
. "$SCRIPT_DIR/lib/desktop-env.sh"
# shellcheck source=lib/review-cli.sh
. "$SCRIPT_DIR/lib/review-cli.sh"

# 回环绕行兜底（MOZ-36 baseline, integrated here so this branch does not
# merge the unreviewed feat/MOZ-36 commit). Existing hosts kept; both spellings set.
merge_no_proxy_loopback() {
  local merged="" raw entry
  local -a parts=()
  local -A seen=()
  for raw in "${NO_PROXY-}" "${no_proxy-}" '127.0.0.1,localhost,::1'; do
    [[ -n "$raw" ]] || continue
    IFS=',' read -r -a parts <<< "$raw"
    for entry in "${parts[@]}"; do
      entry="${entry//[[:space:]]/}"
      [[ -n "$entry" && -z "${seen[$entry]-}" ]] || continue
      seen[$entry]=1
      merged="${merged:+$merged,}$entry"
    done
  done
  export NO_PROXY="$merged" no_proxy="$merged"
}


REPO_DIR=""
TICKET_ID=""
PROMPT_FILE=""
BASE_BRANCH="main"
RESUME_SESSION=""
AUDIT_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO_DIR="$2"; shift 2 ;;
    --ticket) TICKET_ID="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --base-branch) BASE_BRANCH="$2"; shift 2 ;;
    --resume) RESUME_SESSION="$2"; shift 2 ;;
    --audit-only) AUDIT_ONLY=1; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$REPO_DIR" || -z "$TICKET_ID" || -z "$PROMPT_FILE" ]]; then
  echo "Usage: $0 --repo <path> --ticket <MOZ-12> --prompt-file <path> [--base-branch main] [--resume <session_jsonl>] [--audit-only]"
  exit 1
fi

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
AUDIT_PROMPT_FILE="$TASK_DIR/audit-prompt.txt"
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
if [[ ! -d "$WORKTREE_DIR" && "$AUDIT_ONLY" -eq 1 ]]; then
  # --audit-only 只重审既有 tip：没有 worktree 就复用既有分支，绝不新建空分支
  if ! git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
    echo "[FAIL] --audit-only 需要既有 worktree 或分支 $BRANCH_NAME"
    exit 4
  fi
  git -C "$REPO_DIR" worktree add "$WORKTREE_DIR" "$BRANCH_NAME"
elif [[ ! -d "$WORKTREE_DIR" ]]; then
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

# ---------------------------------------------------------------------------
# 3.5 免侵入宪章注入：pi 真正读取的就是 $PROMPT_COPY（`.task/<ticket>-prompt.md`）
# 宪章存在时，提示文件首部必须是宪章全文 + 分隔行 + 原 prompt；不存在时保持原样复制。
# 只写 $PROMPT_COPY，绝不改写调用方给的 $PROMPT_FILE（写错路径会把提示截空）。
# ---------------------------------------------------------------------------
CHARTER_REL="custom/AGENTS.md"
CHARTER_SEP="=== 本次具体工单任务 ==="
CHARTER_SEEN_ORIGINAL=0

# 宪章存在判定：工作树里是普通文件或符号链接，或 $@ 给出的 rev 树里存在该路径。
# 不跟随链接目标判定：链到仓外/空目标也算「有宪章」，不能靠符号链接假装没有。
charter_present() {
  local rev
  [[ -e "$WORKTREE_DIR/$CHARTER_REL" || -L "$WORKTREE_DIR/$CHARTER_REL" ]] && return 0
  for rev in "$@"; do
    [[ -n "$rev" ]] || continue
    if git -C "$WORKTREE_DIR" cat-file -e "$rev:$CHARTER_REL" 2>/dev/null; then return 0; fi
  done
  return 1
}

# 宪章正文：工作树普通文件优先，其次 HEAD / 远端 base 树里的普通 blob。
# 符号链接的 blob 内容是链接目标文本，不能当宪章正文注入。
charter_text() {
  local rev mode
  if [[ -f "$WORKTREE_DIR/$CHARTER_REL" && ! -L "$WORKTREE_DIR/$CHARTER_REL" ]]; then
    cat "$WORKTREE_DIR/$CHARTER_REL"
    return 0
  fi
  for rev in HEAD "refs/remotes/origin/$BASE_BRANCH" "$BASE_BRANCH"; do
    mode="$(git -C "$WORKTREE_DIR" ls-tree "$rev" -- "$CHARTER_REL" 2>/dev/null | cut -d' ' -f1)"
    case "$mode" in
      100644|100755)
        git -C "$WORKTREE_DIR" show "$rev:$CHARTER_REL"
        return 0 ;;
    esac
  done
  return 1
}

# 生成有效任务提示文件。resume 幂等：源文件已经以同一注入头开头时先按字节剥掉再注入，
# 因此无论重复派发多少次，宪章与分隔行都只有一层。
prepare_prompt_copy() {
  local head="$TASK_DIR/.prompt-head.tmp" body="$TASK_DIR/.prompt-body.tmp"
  local merged="$TASK_DIR/.prompt-copy.tmp" charter bytes
  rm -f "$head" "$body" "$merged"
  if ! charter="$(charter_text)" || [[ -z "$charter" ]]; then
    cp "$PROMPT_FILE" "$PROMPT_COPY"
    return $?
  fi
  printf '%s\n\n%s\n\n' "$charter" "$CHARTER_SEP" > "$head" || return 1
  bytes="$(wc -c < "$head")"
  if cmp -s -n "$bytes" -i 0 "$head" "$PROMPT_FILE"; then
    tail -c "+$((bytes + 1))" "$PROMPT_FILE" > "$body" || return 1
  else
    cp "$PROMPT_FILE" "$body" || return 1
  fi
  cat "$head" "$body" > "$merged" || return 1
  mv "$merged" "$PROMPT_COPY" || return 1
  rm -f "$head" "$body"
}

if charter_present HEAD; then CHARTER_SEEN_ORIGINAL=1; fi
prepare_prompt_copy || { echo "[FAIL] 无法生成有效任务提示文件: $PROMPT_COPY"; exit 4; }
: > "$MERGE_LOG"

# 3.9 受信本地凭据注入：只在 $HOME/.harness/providers.env 存在时 source，缺失即跳过。
# 必须在 pi/agy 启动之前完成（子进程靠继承拿到变量）；source 失败一律硬失败，绝不 || true。
inject_providers_env "$EVIDENCE_DIR/providers-env.txt" || {
  echo "[FAIL] 注入 $HOME/.harness/providers.env 失败（source 返回 $?）"
  exit 5
}
merge_no_proxy_loopback
load_desktop_session_env

# 4. 无头运行实施引擎（WORKER_CLI=codex 默认）。Codex 从文件 stdin 读到 EOF，禁止再叠 < /dev/null。
cd "$WORKTREE_DIR"
ensure_codex_on_path || true
WORKER_ENGINE="$(worker_cli_name)"
SES_FILE=""
if [[ "$AUDIT_ONLY" -eq 1 ]]; then
  # 不跑实施引擎、不 --resume、不改实现：只复用当前 feat/<ticket> tip 重做异构审查
  PI_EXIT=0
else
  set +e
  if [[ "$WORKER_ENGINE" == "codex" ]]; then
    run_codex_exec "$PROMPT_COPY" "$WORKTREE_DIR" "$TASK_DIR/$TICKET_ID.jsonl" "$TASK_DIR/$TICKET_ID.jsonl.err"
    PI_EXIT=$?
  elif [[ -n "$RESUME_SESSION" && -f "$RESUME_SESSION" ]]; then
    pi --session-dir "$TASK_DIR/sessions" --session "$RESUME_SESSION" --mode json \
       -p "$(cat "$PROMPT_COPY")" > "$TASK_DIR/$TICKET_ID.jsonl" 2>&1 < /dev/null
    PI_EXIT=$?
  else
    pi --session-dir "$TASK_DIR/sessions" --mode json \
       -p "$(cat "$PROMPT_COPY")" > "$TASK_DIR/$TICKET_ID.jsonl" 2>&1 < /dev/null
    PI_EXIT=$?
  fi
  set -e
  SES_FILE=$(ls -t "$TASK_DIR/sessions/"*.jsonl 2>/dev/null | head -n 1 || echo "")
fi
AUDIT_VERDICT="SKIPPED"
AUDIT_REASON="pi_failed"
AGY_EXIT=""
REVIEW_EXIT=""
REVIEW_ENGINE=""
AUDITED_COMMIT=""
AUDITED_BASE=""
CUSTOM_GATE_ENABLED=0
CUSTOM_GATE_REASON=""
CUSTOM_GATE_VIOLATIONS=()
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

# ---------------------------------------------------------------------------
# 免侵入物理门禁（只在宪章存在时启用）
# 宪章一旦出现在捕获 base / 待合树 / 工作树任一处就启用，pi 删掉文件也逃不掉；
# 违规只 FAIL 并列出路径，绝不 checkout / 回滚上游文件（不是静默修复工具）。
# 所有判定都读提交树，不认 git status / index / skip-worktree。
# ---------------------------------------------------------------------------

# OpenMontage 公开源：remote.<name>.url 必须是这两种形态之一。
# 用 `git config --get`（不套 url.*.insteadOf 重写）读原始值，测试可把抓取重写到本地 bare。
UPSTREAM_URL_RE='^(https://github\.com/calesthio/OpenMontage(\.git)?|git@github\.com:calesthio/OpenMontage(\.git)?)/?$'

# 解析「已核实」的 upstream tip：remote URL 必须指向 OpenMontage 公开源，且已 fetch 出 main。
# 没有叫 upstream 的 remote、URL 不对、ref 缺失都返回非零 —— 调用方一律 fail-closed。
resolve_upstream_tip() {
  local name url tip
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    url="$(git -C "$WORKTREE_DIR" config --get "remote.$name.url" 2>/dev/null)" || continue
    [[ "$url" =~ $UPSTREAM_URL_RE ]] || continue
    if tip="$(git -C "$WORKTREE_DIR" rev-parse -q --verify "refs/remotes/$name/main^{commit}" 2>/dev/null)"; then
      printf '%s\n' "$tip"
      return 0
    fi
  done < <(git -C "$WORKTREE_DIR" remote 2>/dev/null)
  return 1
}

# 两点完整树比对：custom/ 以外任何路径出现即违规。
# --no-renames 让 rename 拆成 A+D，源侧与目标侧都会被检查；-z 保证空格/换行路径不串行。
gate_diff_tree() {
  local a="$1" b="$2" label="$3" out p
  out="$TASK_DIR/.gate-diff.tmp"
  if ! git -C "$WORKTREE_DIR" diff -z --name-only --no-renames "$a" "$b" > "$out" 2>/dev/null; then
    rm -f "$out"
    CUSTOM_GATE_REASON="${label}_diff_failed"
    return 1
  fi
  while IFS= read -r -d '' p; do
    [[ "$p" == custom/* ]] && continue
    CUSTOM_GATE_VIOLATIONS+=("$label:$p")
  done < "$out"
  rm -f "$out"
}

# 门禁主流程：$1=待合 commit，$2=本次捕获的 base tip。失败时设置 CUSTOM_GATE_REASON 与违规清单。
run_custom_gate() {
  local commit="$1" base="$2" entry mode upstream out p
  CUSTOM_GATE_REASON=""
  CUSTOM_GATE_VIOLATIONS=()

  # 1) 宪章必须仍以普通文件存在于待合树：删除或换成符号链接都是逃逸
  if ! entry="$(git -C "$WORKTREE_DIR" ls-tree -z "$commit" -- "$CHARTER_REL")"; then
    CUSTOM_GATE_REASON="tree_unreadable"; return 1
  fi
  mode="${entry%% *}"
  if [[ -z "$entry" ]]; then
    CUSTOM_GATE_VIOLATIONS+=("charter_missing:$CHARTER_REL")
  elif [[ "$mode" != "100644" && "$mode" != "100755" ]]; then
    CUSTOM_GATE_VIOLATIONS+=("charter_not_regular:$CHARTER_REL")
  fi
  if [[ -L "$WORKTREE_DIR/$CHARTER_REL" ]]; then
    CUSTOM_GATE_VIOLATIONS+=("charter_worktree_symlink:$CHARTER_REL")
  fi

  # 2) 运行目录不得出现在待合树（.task/out/projects/.pi 只允许本地存在）
  out="$TASK_DIR/.gate-tree.tmp"
  if ! git -C "$WORKTREE_DIR" ls-tree -r -z --name-only "$commit" -- .task out projects .pi > "$out" 2>/dev/null; then
    rm -f "$out"
    CUSTOM_GATE_REASON="tree_unreadable"; return 1
  fi
  while IFS= read -r -d '' p; do
    CUSTOM_GATE_VIOLATIONS+=("runtime_dir:$p")
  done < "$out"
  rm -f "$out"

  # 3) 待合 commit 相对本次捕获的 base：只允许 custom/ 内变化
  if [[ -z "$base" ]]; then CUSTOM_GATE_REASON="base_missing"; return 1; fi
  gate_diff_tree "$base" "$commit" base || return 1

  # 4) 待合 commit 相对已核实的 OpenMontage upstream/main：同样只允许 custom/ 内变化
  if ! upstream="$(resolve_upstream_tip)"; then
    CUSTOM_GATE_REASON="upstream_ref_missing"; return 1
  fi
  if ! git -C "$WORKTREE_DIR" merge-base "$upstream" "$base" >/dev/null 2>&1; then
    CUSTOM_GATE_REASON="upstream_unrelated"; return 1
  fi
  gate_diff_tree "$upstream" "$commit" upstream || return 1

  if [[ "${#CUSTOM_GATE_VIOLATIONS[@]}" -gt 0 ]]; then
    CUSTOM_GATE_REASON="violation"
    return 1
  fi
  return 0
}

# 门禁 FAIL 证据：首行恰为 VERDICT: FAIL，其后 [Act On] 逐条列出越界路径
write_custom_gate_fail() {
  local v
  {
    printf 'VERDICT: FAIL\n'
    if [[ "${#CUSTOM_GATE_VIOLATIONS[@]}" -gt 0 ]]; then
      printf '[Act On] 非侵入门禁拦截（%s）：以下路径只允许出现在 custom/ 下\n' "$CUSTOM_GATE_REASON"
      for v in "${CUSTOM_GATE_VIOLATIONS[@]}"; do printf '[Act On] %s\n' "$v"; done
    else
      printf '[Act On] 非侵入门禁无法判定（%s），按失败处理\n' "$CUSTOM_GATE_REASON"
    fi
  } > "$AUDIT_FILE"
  AUDIT_VERDICT="FAIL"
  AUDIT_REASON="custom_gate_${CUSTOM_GATE_REASON}"
}

# 让即将送审的 tip 树不含 .task/，且清理动作本身必须成为待审提交的一部分：
# 1) 已 tracked 的 .task -> git rm -r --cached + 提交（否则审查后改 index 就是审非所合）
# 2) --no-ff 会把中间提交的 .task blob 带进 main 历史 -> 仅对未合入的 feat 分支做
#    reset --soft（禁止 --hard / force-push）后再提交一棵同树的干净 tip
# 3) 最后以 tree 为准复核（git add -f 能绕过 exclude，只有 tree 说了算）
# 任何一步失败都返回非零，不吞错；原本就没有 tracked .task 是成功的 no-op。
sanitize_audited_tip() {
  local tracked orig_subject range commit task_paths dir
  tracked=""
  for dir in .task out projects .pi; do
    if ! task_paths="$(git -C "$WORKTREE_DIR" ls-files -- "$dir")"; then
      audit_fail task_ls_files_failed; return 1
    fi
    [[ -n "$task_paths" ]] && tracked=1
  done
  orig_subject="$(git -C "$WORKTREE_DIR" log -1 --format=%s)" || orig_subject=""
  if [[ -n "$tracked" ]]; then
    for dir in .task out projects .pi; do
      if [[ -n "$(git -C "$WORKTREE_DIR" ls-files -- "$dir")" ]]; then
        if ! git -C "$WORKTREE_DIR" rm -r --cached --quiet -- "$dir"; then
          audit_fail task_untrack_failed; return 1
        fi
      fi
    done
    if ! git -C "$WORKTREE_DIR" commit -q -m "chore: untrack runtime dirs from version control"; then
      audit_fail task_untrack_commit_failed; return 1
    fi
  fi
  if ! range="$(git -C "$WORKTREE_DIR" rev-list "$AUDITED_BASE..HEAD")"; then
    audit_fail task_history_check_failed; return 1
  fi
  for commit in $range; do
    if ! task_paths="$(git -C "$WORKTREE_DIR" ls-tree -r --name-only "$commit" -- .task out projects .pi)"; then
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
  if ! task_paths="$(git -C "$WORKTREE_DIR" ls-tree -r --name-only HEAD -- .task out projects .pi)"; then
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
  local remote_base new_head parent_count audited_task_paths v

  echo "== merge attempt $(date -Is) ticket=$TICKET_ID" >> "$MERGE_LOG"
  echo "audited_base=$AUDITED_BASE audited_commit=$AUDITED_COMMIT base_branch=$BASE_BRANCH repo=$REPO_DIR" >> "$MERGE_LOG"

  # 合入前闭锁：只认已审 SHA 的 tree，index/ignore 规则都不作数。
  # 此阶段禁止 git rm / 新提交 / 改 SHA——发现问题只能拒合，留下 worktree 与证据。
  if [[ "$(git -C "$WORKTREE_DIR" rev-parse HEAD)" != "$AUDITED_COMMIT" ]]; then
    MERGE_REASON="post_audit_commit_changed"; return 1
  fi
  if ! audited_task_paths="$(git -C "$WORKTREE_DIR" ls-tree -r --name-only "$AUDITED_COMMIT" -- .task out projects .pi)"; then
    MERGE_REASON="audited_tree_unreadable"; return 1
  fi
  if [[ -n "$audited_task_paths" ]]; then
    MERGE_REASON="task_dir_in_audited_tree"
    echo "audited tree still tracks runtime dirs:" >> "$MERGE_LOG"
    echo "$audited_task_paths" >> "$MERGE_LOG"
    return 1
  fi

  # 合入前复查非侵入门禁：同参重跑，失败只拒合，绝不修改已审 SHA
  if [[ "$CUSTOM_GATE_ENABLED" -eq 1 ]] && ! run_custom_gate "$AUDITED_COMMIT" "$AUDITED_BASE"; then
    MERGE_REASON="custom_gate_${CUSTOM_GATE_REASON}"
    {
      echo "custom gate blocked merge: reason=${CUSTOM_GATE_REASON}"
      if [[ "${#CUSTOM_GATE_VIOLATIONS[@]}" -gt 0 ]]; then
        for v in "${CUSTOM_GATE_VIOLATIONS[@]}"; do echo "$v"; done
      fi
    } >> "$MERGE_LOG"
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
  cp -a "$AUDIT_FILE" "$BUNDLE_FILE" "$AUDIT_PROMPT_FILE" "$MERGE_LOG" "$TASK_DIR/$TICKET_ID.jsonl" "$ARCHIVE_DIR/" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 5. 纯文本异构审查（REVIEW_CLI=pi 默认：bwrap 禁写 + --no-tools + @file；agy 可回退）
# ---------------------------------------------------------------------------
if [[ "$PI_EXIT" -eq 0 ]]; then
  git -C "$WORKTREE_DIR" fetch origin "$BASE_BRANCH" >/dev/null 2>&1 || true
  AUDITED_BASE="$(git -C "$WORKTREE_DIR" rev-parse "refs/remotes/origin/$BASE_BRANCH" 2>/dev/null \
    || git -C "$WORKTREE_DIR" rev-parse "$BASE_BRANCH")"

  # 审查前清理：先摘掉已 tracked 的运行目录（.task/out/projects/.pi）再绑已审 SHA，
  # 审查指纹才对得上干净树
  TIP_CLEAN=1
  sanitize_audited_tip || TIP_CLEAN=0

  AUDITED_COMMIT="$(git -C "$WORKTREE_DIR" rev-parse HEAD)"
  COMMITS_AHEAD="$(git -C "$WORKTREE_DIR" rev-list --count "$AUDITED_BASE..$AUDITED_COMMIT" 2>/dev/null || echo 0)"
  STATE_AT_AUDIT="$(worktree_state)"

  # 门禁启用判定：只要遗漏的 base / 待合 tip / 原工作树任一处有宪章就启用。
  # pi 删掉 custom/AGENTS.md 也逃不过 base 树里的那份。
  if [[ "$CHARTER_SEEN_ORIGINAL" -eq 1 ]] || charter_present "$AUDITED_BASE" "$AUDITED_COMMIT"; then
    CUSTOM_GATE_ENABLED=1
  fi

  if [[ "$TIP_CLEAN" -ne 1 ]]; then
    echo "tip not clean: $AUDIT_REASON" >> "$MERGE_LOG"   # sanitize_audited_tip 已写入精确 reason
  elif worktree_dirty; then
    AUDIT_VERDICT="FAIL"; AUDIT_REASON="dirty_worktree"
  elif [[ "$COMMITS_AHEAD" -lt 1 ]] && ! git -C "$WORKTREE_DIR" merge-base --is-ancestor "$AUDITED_COMMIT" "$AUDITED_BASE"; then
    # 例外：本分支已合入 base（重复执行），此时 commits_ahead=0 属正常幂等
    AUDIT_VERDICT="FAIL"; AUDIT_REASON="no_commits_ahead_of_base"
  else
    REVIEW_ENGINE="$(review_cli_name)"
    if [[ "$REVIEW_ENGINE" == "codex" ]]; then
      ensure_codex_on_path || true
    fi
    if ! command -v "$REVIEW_ENGINE" >/dev/null 2>&1; then
    AUDIT_VERDICT="FAIL"; AUDIT_REASON="${REVIEW_ENGINE}_missing"
  else
    build_review_bundle
    # 审查 prompt 全文落盘后从 stdin 送审：Linux 单参数上限约 128KiB（MAX_ARG_STRLEN），
    # 146KB 的 bundle 放进 -p 会让 agy 以 126 Argument list too long 直接退出、审查根本没启动。
    # agy 的 -p/--print 必须带非空参数，-p - 只把 "-" 当 prompt，所以用 --input-format text
    # （print 模式文档化输入格式）读 stdin 到 EOF。
    {
      cat <<'AUDIT_PROMPT_HEAD'
你是独立只读代码审查官，本轮只做纯文本审查。
【硬性禁令】禁止调用任何工具：不得使用 bash/shell/终端/文件读写/搜索/编辑/MCP 等任何工具或扩展命令，你只能阅读本条消息里的文本。违反本禁令即判 FAIL。
【输出格式】第一行必须且只能是下面两者之一，前后不得有任何字符、反引号、标题或空行：
VERDICT: PASS
VERDICT: FAIL
第二行起按 [Act On]、[Consider]、[Dismissed] 三级分流输出精简中文报告，覆盖 Standards 规范轴（AGENTS.md 约定、类型安全、Laziness Protocol）与 Spec & Proof 实绩轴（任务书 Done Check 是否 100% 交付、证据是否真实可复核）。
【审查材料】
AUDIT_PROMPT_HEAD
      cat "$BUNDLE_FILE"
    } > "$AUDIT_PROMPT_FILE"

    # 物理门禁：pi 成功结束后、agy 启动前跑一次；违规只写 FAIL 证据，不启动 agy。
    CUSTOM_GATE_BLOCKED=0
    if [[ "$CUSTOM_GATE_ENABLED" -eq 1 ]] && ! run_custom_gate "$AUDITED_COMMIT" "$AUDITED_BASE"; then
      CUSTOM_GATE_BLOCKED=1
      write_custom_gate_fail
    fi

    if [[ "$CUSTOM_GATE_BLOCKED" -eq 0 ]]; then
      set +e
      case "$REVIEW_ENGINE" in
        agy)
          # SSH 会话下 agy 会改走文件凭证并表现为未登录：子进程摘掉 SSH_* 复用本机已登录 keyring。
          run_agy_review "$AUDIT_PROMPT_FILE" "$AUDIT_FILE"
          REVIEW_EXIT=$?
          AGY_EXIT="$REVIEW_EXIT"
          ;;
        pi)
          run_pi_review "$AUDIT_PROMPT_FILE" "$AUDIT_FILE.raw" "$TASK_DIR" "$AUDIT_FILE.err"
          REVIEW_EXIT=$?
          ;;
        *)
          # Codex 内核/原生 --sandbox read-only；不使用 bypass；prompt 从 stdin 读到 EOF。
          run_codex_review "$AUDIT_PROMPT_FILE" "$AUDIT_FILE" "$WORKTREE_DIR" "$TASK_DIR" "$AUDIT_FILE.err"
          REVIEW_EXIT=$?
          ;;
      esac
      set -e
      if [[ "$REVIEW_ENGINE" == "pi" && "$REVIEW_EXIT" -eq 90 ]]; then
        printf 'VERDICT: FAIL\n[Act On] review sandbox (bwrap) is required and was not available.\n' > "$AUDIT_FILE"
        AUDIT_VERDICT="FAIL"
        AUDIT_REASON="review_sandbox_missing_bwrap"
      elif [[ "$REVIEW_ENGINE" == "pi" ]]; then
        extract_review_text "$AUDIT_FILE.raw" "$AUDIT_FILE" >/dev/null
      fi
    fi

    AUDIT_FIRST="$(sed -n '1p' "$AUDIT_FILE" 2>/dev/null | tr -d '\r' | sed -e 's/[[:space:]]*$//')"
    if [[ "$CUSTOM_GATE_BLOCKED" -eq 1 ]]; then
      : # write_custom_gate_fail 已写入首行 VERDICT: FAIL 与越界路径
    elif [[ "${AUDIT_REASON:-}" == "review_sandbox_missing_bwrap" ]]; then
      :
    elif [[ -n "${REVIEW_EXIT}" && "$REVIEW_EXIT" -ne 0 ]]; then
      if [[ "$REVIEW_ENGINE" == "agy" ]]; then
        AUDIT_VERDICT="FAIL"; AUDIT_REASON="agy_exit_$REVIEW_EXIT"
      else
        AUDIT_VERDICT="FAIL"; AUDIT_REASON="review_exit_$REVIEW_EXIT"
      fi
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
  "review_cli": "$(json_escape "${REVIEW_ENGINE:-}")",
  "engine": "$(json_escape "${REVIEW_ENGINE:-}")",
  "review_exit": ${REVIEW_EXIT:-null},
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
echo "[DONE] ticket=$TICKET_ID pi_exit=$PI_EXIT audit=$AUDIT_VERDICT audit_reason=$AUDIT_REASON engine=${REVIEW_ENGINE:-none} review_exit=${REVIEW_EXIT:-} auto_merged=$AUTO_MERGED merge_commit=${MERGE_COMMIT:-NONE} merge_reason=$MERGE_REASON session=$SES_FILE"
