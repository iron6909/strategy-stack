#!/usr/bin/env bash
# run-worker.sh 回归测试。
# 全部用例只在 mktemp 临时仓库 + 临时 bare remote 中跑，绝不触碰真实 origin/main。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../run-worker.sh"
TICKET="MOZ-11"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/rw-tests.XXXXXX")"
if [[ "${KEEP_TMP:-0}" == "1" ]]; then
  trap 'printf "\n[kept] 临时仓库与临时 remote 保留在 %s\n" "$TMPROOT"' EXIT
else
  trap 'rm -rf "$TMPROOT"' EXIT
fi
BASE_PATH="$PATH"

PASSED=0
FAILED=0
FAILED_NAMES=()

ok()    { PASSED=$((PASSED + 1)); printf '  ok   - %s\n' "$1"; }
no()    { FAILED=$((FAILED + 1)); FAILED_NAMES+=("$CASE: $1"); printf '  FAIL - %s\n' "$1"; }
eq()    { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (expected [$3] got [$2])"; fi; }
match() { if [[ "$2" =~ $3 ]]; then ok "$1"; else no "$1 ([$2] !~ /$3/)"; fi; }
exists(){ if [[ -e "$2" ]]; then ok "$1"; else no "$1 (missing $2)"; fi; }
absent(){ if [[ ! -e "$2" ]]; then ok "$1"; else no "$1 (unexpected $2)"; fi; }
is_true(){ if eval "$2"; then ok "$1"; else no "$1"; fi; }

new_fixture() {
  ROOT="$(mktemp -d "$TMPROOT/case.XXXXXX")"
  export HOME="$ROOT/home"
  mkdir -p "$HOME/.harness/webhooks"
  printf '[user]\n\tname = Test\n\temail = test@example.invalid\n' > "$HOME/.gitconfig"
  unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM STUB_AGY STUB_PI STUB_CURL_OUT STUB_PI_TASK STUB_SHA_OUT

  BIN="$ROOT/bin"
  mkdir -p "$BIN"
  # 门禁桩：本机真实 pi 会话不应阻断回归测试
  printf '#!/usr/bin/env bash\necho 0\n' > "$BIN/pgrep"
  printf '#!/usr/bin/env bash\necho "              total        used        free      shared  buff/cache   available"\necho "Mem:          32000        1000       20000           0        1000       20000"\n' > "$BIN/free"

  cat > "$BIN/pi" <<'PI'
#!/usr/bin/env bash
printf 'pi %s\n' "$*" >> "${STUB_LOG:-/dev/null}"
case "${STUB_PI:-ok}" in
  fail)  exit 7 ;;
  dirty) echo dirty >> ./f.txt; exit 0 ;;
  none)  exit 0 ;;
  piartifacts|piartifacts_noexclude)
    # pi 运行时在 worktree 留下未跟踪的 .pi/（不得入库，也不得被判成脏树）
    mkdir -p .pi/tasks
    echo "harness log for ${STUB_PI}" > .pi/tasks/run.log
    if [[ "${STUB_PI}" == "piartifacts_noexclude" ]]; then
      # 模拟 info/exclude 里沒有 .pi/ 的情况：过滤逻辑必须自己兜住
      excl="$(git rev-parse --git-common-dir)/info/exclude"
      tmp="$(mktemp)"
      grep -vxF '.pi/' "$excl" > "$tmp"
      cat "$tmp" > "$excl"
      rm -f "$tmp"
    fi ;;
esac
mkdir -p .task/evidence
echo "proof line for ${STUB_PI:-ok}" > .task/evidence/proof.txt
echo "feat-${STUB_PI:-ok}" >> feature.txt
git add feature.txt
git commit -qm "feat: stub work"
# 模拟 agent 把 .task/ 证据入库（-f 绕过 info/exclude，正是本项目要防的场景）
case "${STUB_PI_TASK:-}" in
  tracked)
    mkdir -p .task/evidence
    echo "tracked proof" > .task/evidence/tracked-proof.txt
    git add -f .task
    git commit -qm "feat: stub work with tracked .task evidence" ;;
  tracked_space)
    mkdir -p ".task/evidence/proof dir"
    echo "spaced proof" > ".task/evidence/proof dir/my proof.txt"
    git add -f .task
    git commit -qm "feat: stub work with tracked .task (spaced path)" ;;
esac
git rev-parse HEAD > "${STUB_SHA_OUT:-/dev/null}"
PI
  cat > "$BIN/agy" <<'AGY'
#!/usr/bin/env bash
printf 'agy %s\n' "$*" >> "${STUB_LOG:-/dev/null}"
case "${STUB_AGY:-pass}" in
  fail)  printf 'VERDICT: FAIL\n[Act On] 缺真实证据\n' ;;
  empty) : ;;
  fake)  printf '好的，我先说明一下审查口径。\nVERDICT: PASS\n[Act On] 无\n' ;;
  late)  printf 'VERDICT: PASS\n[Act On] 无\n'; exit 4 ;;
  postchange)
    printf 'VERDICT: PASS\n[Consider] 无\n'
    echo tampered >> ./f.txt ;;
  basepush)
    printf 'VERDICT: PASS\n[Consider] 无\n'
    ( cd "$STUB_REPO" && echo base-moved > f.txt \
      && git commit -qam "base moved during audit" \
      && git push -q origin main ) ;;
  treetask)
    # 审计通过但已审 SHA 的 tree 里仍有 .task：只动 index + replace ref，不动 HEAD，
    # 因此 post_audit_* 全部通过，只能靠合入前的 ls-tree 闭锁拦住（index/ignore 不作数）。
    printf 'VERDICT: PASS\n[Consider] 无\n'
    git add -f .task/evidence/proof.txt
    repl="$(git commit-tree "$(git write-tree)" -p HEAD -m "fake tree with .task")"
    git replace HEAD "$repl" ;;
  *) printf 'VERDICT: PASS\n[Act On] 无\n[Consider] 无\n[Dismissed] 无\n' ;;
esac
AGY
  cat > "$BIN/curl" <<'CURL'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
  if [[ "$prev" == "-d" ]]; then cp "${a#@}" "${STUB_CURL_OUT:-/dev/null}"; fi
  prev="$a"
done
CURL
  chmod +x "$BIN/pgrep" "$BIN/free" "$BIN/pi" "$BIN/agy" "$BIN/curl"
  export PATH="$BIN:$BASE_PATH"
  export STUB_LOG="$ROOT/stub.log"

  git init -q --bare "$ROOT/remote.git"
  git -C "$ROOT/remote.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$ROOT/remote.git" "$ROOT/work" 2>/dev/null
  REPO="$ROOT/work"
  (
    cd "$REPO" || exit 1
    echo base > f.txt
    git add f.txt
    git commit -qm init
    git push -q -u origin main
  ) >/dev/null 2>&1
  INIT_SHA="$(git -C "$ROOT/remote.git" rev-parse refs/heads/main)"
  printf '任务书：实现一个薄切片并留下真实证据。\n' > "$ROOT/prompt.md"
  WORKTREE="$ROOT/worktrees/$TICKET"
  PAYLOAD="$WORKTREE/.task/webhook-payload.json"
}

run_worker_at() {
  OUT="$(
    bash "$SCRIPT" --repo "$1" --ticket "$TICKET" --prompt-file "$ROOT/prompt.md" 2>&1
  )"
  RC=$?
  DONE_LINE="$(printf '%s\n' "$OUT" | grep '^\[DONE\]' | tail -n1)"
}
run_worker() { run_worker_at "$REPO"; }

done_field() { printf '%s\n' "$DONE_LINE" | grep -oE "$1=[^ ]*" | tail -n1 | cut -d= -f2-; }
payload_field() { sed -n "s/^  \"$1\": *//p" "$PAYLOAD" | sed -e 's/,$//' -e 's/^"//' -e 's/"$//'; }
remote_main() { git -C "$ROOT/remote.git" rev-parse refs/heads/main; }
remote_count() { git -C "$ROOT/remote.git" rev-list --count refs/heads/main; }
worktree_field() { git -C "$WORKTREE" "$@"; }

CASE="bash -n"
if bash -n "$SCRIPT" 2>/dev/null; then ok "run-worker.sh 语法"; else no "run-worker.sh 语法"; fi
if bash -n "${BASH_SOURCE[0]}" 2>/dev/null; then ok "测试脚本语法"; else no "测试脚本语法"; fi

# ---------------------------------------------------------------------------
CASE="success_auto_merge_push"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=ok STUB_AGY=pass
printf 'WEBHOOK_URL="http://127.0.0.1:1/hook"\nWEBHOOK_KEY="test-key"\n' > "$HOME/.harness/webhooks/mozi.env"
export STUB_CURL_OUT="$ROOT/posted.json"
run_worker
eq "exit code" "$RC" "0"
eq "audit verdict" "$(done_field audit)" "PASS"
eq "auto_merged" "$(done_field auto_merged)" "1"
eq "merge reason" "$(done_field merge_reason)" "merged_and_pushed"
MERGE_SHA="$(done_field merge_commit)"
eq "remote tip == merge_commit" "$MERGE_SHA" "$(remote_main)"
eq "远端只有一次 --no-ff 合并" "$(remote_count)" "3"
printf '  proof: temp_remote=%s merge_commit=%s remote_main=%s\n' "$ROOT/remote.git" "$MERGE_SHA" "$(remote_main)"
eq "合并提交有两个父提交" "$(git -C "$ROOT/remote.git" rev-list --parents -n 1 refs/heads/main | awk '{print NF}')" "3"
is_true "远端已含已审 commit" "git -C '$ROOT/remote.git' merge-base --is-ancestor '$MERGE_SHA^2' refs/heads/main"
exists "review-bundle 已生成" "$WORKTREE/.task/review-bundle.txt"
match "bundle 绑定已审 commit" "$(cat "$WORKTREE/.task/review-bundle.txt" 2>/dev/null)" "audited_commit=[0-9a-f]{40}"
match "bundle 含硬性禁令与判定词" "$(cat "$WORKTREE/.task/review-bundle.txt" 2>/dev/null)" "## 3."
exists "审查报告落盘" "$WORKTREE/.task/$TICKET-audit.md"
exists "合推证据落盘" "$WORKTREE/.task/$TICKET-merge.txt"
exists "证据已归档到 worktree 之外" "$HOME/task-archive/$TICKET/$(basename "$WORKTREE/.task/$TICKET-audit.md")"
eq "payload audit_verdict" "$(payload_field audit_verdict)" "PASS"
eq "payload auto_merged" "$(payload_field auto_merged)" "1"
eq "payload merge_commit" "$(payload_field merge_commit)" "$MERGE_SHA"
eq "payload evidence_dir 为持久目录" "$(payload_field evidence_dir)" "$HOME/task-archive/$TICKET"
eq "webhook 投递体 auto_merged" "$(grep -oE '\"auto_merged\": [01]' "$ROOT/posted.json" 2>/dev/null)" '"auto_merged": 1'
eq "payload 向后兼容字段 pi_exit" "$(payload_field pi_exit)" "0"
match "agy 使用纯文本审查参数" "$(cat "$ROOT/stub.log" 2>/dev/null)" "dangerously-skip-permissions"
match "agy 禁用 slash/skill 展开" "$(cat "$ROOT/stub.log" 2>/dev/null)" "disable-slash-commands"

# ---------------------------------------------------------------------------
CASE="pi_failure"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=fail
run_worker
eq "审计跳过" "$(done_field audit)" "SKIPPED"
eq "auto_merged" "$(done_field auto_merged)" "0"
eq "远端未变" "$(remote_main)" "$INIT_SHA"
absent "未跑审查" "$WORKTREE/.task/$TICKET-audit.md"
exists "worktree 保留" "$WORKTREE"

# ---------------------------------------------------------------------------
CASE="audit_fail"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=ok STUB_AGY=fail
run_worker
eq "audit verdict" "$(done_field audit)" "FAIL"
eq "audit reason" "$(done_field audit_reason)" "verdict_fail"
eq "auto_merged" "$(done_field auto_merged)" "0"
eq "远端未变" "$(remote_main)" "$INIT_SHA"
exists "worktree 保留" "$WORKTREE"

# ---------------------------------------------------------------------------
CASE="audit_empty_report"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=ok STUB_AGY=empty
run_worker
eq "audit verdict" "$(done_field audit)" "FAIL"
eq "audit reason" "$(done_field audit_reason)" "empty_report"
eq "auto_merged" "$(done_field auto_merged)" "0"
eq "远端未变" "$(remote_main)" "$INIT_SHA"

# ---------------------------------------------------------------------------
CASE="audit_verdict_not_first_line"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=ok STUB_AGY=fake
run_worker
eq "audit verdict" "$(done_field audit)" "FAIL"
eq "audit reason" "$(done_field audit_reason)" "verdict_not_exact_first_line"
eq "auto_merged" "$(done_field auto_merged)" "0"
eq "远端未变" "$(remote_main)" "$INIT_SHA"

# ---------------------------------------------------------------------------
CASE="audit_nonzero_exit"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=ok STUB_AGY=late
run_worker
eq "audit reason" "$(done_field audit_reason)" "agy_exit_4"
eq "auto_merged" "$(done_field auto_merged)" "0"
eq "远端未变" "$(remote_main)" "$INIT_SHA"

# ---------------------------------------------------------------------------
CASE="push_rejected"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=ok STUB_AGY=pass
printf '#!/bin/sh\necho "rejected by policy" >&2\nexit 1\n' > "$ROOT/remote.git/hooks/pre-receive"
chmod +x "$ROOT/remote.git/hooks/pre-receive"
run_worker
eq "audit verdict" "$(done_field audit)" "PASS"
eq "merge reason" "$(done_field merge_reason)" "push_rejected"
eq "auto_merged" "$(done_field auto_merged)" "0"
eq "远端未变" "$(remote_main)" "$INIT_SHA"
match "本地已生成 merge commit 留证" "$(done_field merge_commit)" "^[0-9a-f]{40}$"
exists "worktree 保留" "$WORKTREE"
match "合推日志记录推送失败" "$(cat "$WORKTREE/.task/$TICKET-merge.txt" 2>/dev/null)" "rejected by policy"

# ---------------------------------------------------------------------------
CASE="merge_conflict"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=ok STUB_AGY=pass
git -C "$REPO" worktree add -q "$WORKTREE" -b "feat/$TICKET" main
(
  cd "$WORKTREE" || exit 1
  echo featline > f.txt
  git commit -qam "feat change"
) >/dev/null 2>&1
(
  cd "$REPO" || exit 1
  echo basemove > f.txt
  git commit -qam "base change"
  git push -q origin main
) >/dev/null 2>&1
CONFLICT_BASE="$(remote_main)"
run_worker
eq "audit verdict" "$(done_field audit)" "PASS"
eq "merge reason" "$(done_field merge_reason)" "merge_conflict"
eq "auto_merged" "$(done_field auto_merged)" "0"
eq "远端回到未合并基线" "$(remote_main)" "$CONFLICT_BASE"
eq "冲突后已 merge --abort" "$(git -C "$REPO" status --porcelain -uno)" ""
exists "worktree 保留" "$WORKTREE"

# ---------------------------------------------------------------------------
CASE="dirty_worktree"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=dirty STUB_AGY=pass
run_worker
eq "audit verdict" "$(done_field audit)" "FAIL"
eq "audit reason" "$(done_field audit_reason)" "dirty_worktree"
eq "auto_merged" "$(done_field auto_merged)" "0"
eq "远端未变" "$(remote_main)" "$INIT_SHA"
absent "脏树不进入审查" "$WORKTREE/.task/$TICKET-audit.md"

# ---------------------------------------------------------------------------
CASE="post_audit_change"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=ok STUB_AGY=postchange
run_worker
eq "audit verdict" "$(done_field audit)" "FAIL"
eq "audit reason" "$(done_field audit_reason)" "post_audit_worktree_changed"
eq "auto_merged" "$(done_field auto_merged)" "0"
eq "远端未变" "$(remote_main)" "$INIT_SHA"

# ---------------------------------------------------------------------------
CASE="base_changed_during_audit"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=ok STUB_AGY=basepush STUB_REPO="$REPO"
run_worker
eq "audit verdict" "$(done_field audit)" "PASS"
eq "merge reason" "$(done_field merge_reason)" "base_changed"
eq "auto_merged" "$(done_field auto_merged)" "0"
eq "远端只剩审查期间被推进的 base" "$(remote_count)" "2"
eq "远端未被写入合并提交" "$(remote_main)" "$(git -C "$REPO" rev-parse refs/remotes/origin/main)"

# ---------------------------------------------------------------------------
CASE="concurrency_lock"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=ok STUB_AGY=pass
mkdir -p "$ROOT/worktrees/.$TICKET.lock"
echo "$$" > "$ROOT/worktrees/.$TICKET.lock/pid"
run_worker
eq "exit code" "$RC" "3"
match "输出锁占用" "$OUT" "\[LOCK_BLOCKED\]"
eq "远端未变" "$(remote_main)" "$INIT_SHA"
absent "未创建 worktree" "$WORKTREE"

# ---------------------------------------------------------------------------
CASE="idempotent_rerun"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=ok STUB_AGY=pass
run_worker
FIRST_SHA="$(done_field merge_commit)"
FIRST_COUNT="$(remote_count)"
export STUB_PI=none
run_worker
eq "二次执行仍 auto_merged" "$(done_field auto_merged)" "1"
eq "二次执行识别已合并" "$(done_field merge_reason)" "already_merged"
eq "未产生第二次合并提交" "$(remote_count)" "$FIRST_COUNT"
eq "merge_commit 未漂移" "$(done_field merge_commit)" "$FIRST_SHA"
eq "远端 tip 未漂移" "$(remote_main)" "$FIRST_SHA"

# ---------------------------------------------------------------------------
CASE="exclude_from_worktree_repo"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=ok STUB_AGY=pass
# --repo 本身就是一个 worktree：common dir 仍必须解析到主仓，不能写进 worktree 的 .git
# （worktree 的 .git 是文件，写错会直接失败）
git -C "$REPO" worktree add -q "$ROOT/worktrees/host" -b host-branch main
is_true "host 是 worktree（.git 为文件）" '[[ -f "$ROOT/worktrees/host/.git" ]]'
run_worker_at "$ROOT/worktrees/host"
HOST_EXCLUDE="$REPO/.git/info/exclude"
eq "exit code" "$RC" "0"
exists "主仓 info/exclude 被写入" "$HOST_EXCLUDE"
eq ".task/ 已写入主仓 exclude" "$(grep -cxF '.task/' "$HOST_EXCLUDE" 2>/dev/null)" "1"
eq "out/ 已写入主仓 exclude" "$(grep -cxF 'out/' "$HOST_EXCLUDE" 2>/dev/null)" "1"
eq "projects/ 已写入主仓 exclude" "$(grep -cxF 'projects/' "$HOST_EXCLUDE" 2>/dev/null)" "1"
eq ".pi/ 已写入主仓 exclude" "$(grep -cxF '.pi/' "$HOST_EXCLUDE" 2>/dev/null)" "1"
exists "worktree 已建立" "$ROOT/worktrees/worktrees/$TICKET"

# ---------------------------------------------------------------------------
CASE="common_dir_relative_fallback"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=ok STUB_AGY=pass
# 模拟旧 git：拒绝 --path-format，且 --git-common-dir 只给相对路径（须由脚本安全拼接）
REAL_GIT="$(command -v git)"
mkdir -p "$ROOT/bingit"
cat > "$ROOT/bingit/git" <<GIT
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ "\$a" == --path-format=* ]]; then echo "error: unknown option" >&2; exit 129; fi
done
if [[ "\$*" == *--git-common-dir* ]]; then
  repo="\$PWD"
  if [[ "\$1" == "-C" ]]; then repo="\$2"; shift 2; fi
  out="\$("$REAL_GIT" -C "\$repo" rev-parse --git-common-dir)" || exit \$?
  [[ "\$out" == /* ]] && out="\$(realpath --relative-to="\$repo" "\$out")"
  printf '%s\\n' "\$out"; exit 0
fi
exec "$REAL_GIT" "\$@"
GIT
chmod +x "$ROOT/bingit/git"
export PATH="$ROOT/bingit:$PATH"
run_worker
eq "exit code" "$RC" "0"
eq "回退路径下仍写对主仓 exclude" "$(grep -cxF '.task/' "$REPO/.git/info/exclude" 2>/dev/null)" "1"
eq "回退路径下双绿灯仍成立" "$(done_field auto_merged)" "1"

# ---------------------------------------------------------------------------
CASE="tracked_task_removed_before_audit"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=ok STUB_PI_TASK=tracked STUB_AGY=pass STUB_SHA_OUT="$ROOT/pi.sha"
run_worker
PI_SHA="$(cat "$ROOT/pi.sha")"
AUDITED="$(payload_field audited_commit)"
eq "审查通过" "$(done_field audit)" "PASS"
eq "dual green 合推" "$(done_field auto_merged)" "1"
eq "merge reason" "$(done_field merge_reason)" "merged_and_pushed"
is_true "已审 SHA 换成了不含 .task 的 tip" '[[ "$AUDITED" != "$PI_SHA" ]]'
is_true "已审 tip 树无 .task" '[[ -z "$(git -C "$WORKTREE" ls-tree -r --name-only "$AUDITED" -- .task)" ]]'
is_true "远端 main 树无 .task" '[[ -z "$(git -C "$ROOT/remote.git" ls-tree -r --name-only refs/heads/main -- .task)" ]]'
is_true "带 .task 的历史提交未进 main" '! git -C "$ROOT/remote.git" cat-file -e "$PI_SHA^{commit}" 2>/dev/null'
is_true "main 上任何可达 tree 都无 .task" '[[ -z "$(for c in $(git -C "$ROOT/remote.git" rev-list refs/heads/main); do git -C "$ROOT/remote.git" ls-tree -r --name-only "$c" -- .task; done)" ]]'
eq "历史被压成一个干净 tip（不留中间 .task 提交）" "$(remote_count)" "3"
exists "证据文件仍在工作区（未被删）" "$WORKTREE/.task/evidence/tracked-proof.txt"
echo "  proof: pi_sha=$PI_SHA audited=$AUDITED"

# ---------------------------------------------------------------------------
CASE="tracked_task_with_space_in_path"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=ok STUB_PI_TASK=tracked_space STUB_AGY=pass STUB_SHA_OUT="$ROOT/pi.sha"
run_worker
PI_SHA="$(cat "$ROOT/pi.sha")"
AUDITED="$(payload_field audited_commit)"
eq "dual green 合推" "$(done_field auto_merged)" "1"
is_true "已审 tip 树无 .task（含空格路径）" '[[ -z "$(git -C "$WORKTREE" ls-tree -r --name-only "$AUDITED" -- .task)" ]]'
is_true "远端 main 树无 .task（含空格路径）" '[[ -z "$(git -C "$ROOT/remote.git" ls-tree -r --name-only refs/heads/main -- .task)" ]]'
is_true "含空格 .task 提交未进 main" '! git -C "$ROOT/remote.git" cat-file -e "$PI_SHA^{commit}" 2>/dev/null'
exists "含空格证据文件仍在工作区" "$WORKTREE/.task/evidence/proof dir/my proof.txt"

# ---------------------------------------------------------------------------
CASE="exclude_idempotent"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=ok STUB_AGY=pass
run_worker
export STUB_PI=none
run_worker
EXCLUDE="$REPO/.git/info/exclude"
eq ".task/ 重复执行不重复写行" "$(grep -cxF '.task/' "$EXCLUDE")" "1"
eq "out/ 重复执行不重复写行" "$(grep -cxF 'out/' "$EXCLUDE")" "1"
eq "projects/ 重复执行不重复写行" "$(grep -cxF 'projects/' "$EXCLUDE")" "1"
eq ".pi/ 重复执行不重复写行" "$(grep -cxF '.pi/' "$EXCLUDE")" "1"

# ---------------------------------------------------------------------------
CASE="untracked_pi_not_dirty"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=piartifacts STUB_AGY=pass
run_worker
eq "审查未被 .pi/ 误判" "$(done_field audit)" "PASS"
eq "audit reason" "$(done_field audit_reason)" "ok"
eq "双绿灯合推" "$(done_field auto_merged)" "1"
AUDITED="$(payload_field audited_commit)"
is_true "待审 tip 无 .pi/.task" '[[ -z "$(git -C "$WORKTREE" ls-tree -r --name-only "$AUDITED" -- .pi .task)" ]]'
is_true "远端 main 无 .pi/.task" '[[ -z "$(git -C "$ROOT/remote.git" ls-tree -r --name-only refs/heads/main -- .pi .task)" ]]'
exists ".pi/ 运行日志确实还在工作区" "$WORKTREE/.pi/tasks/run.log"

# ---------------------------------------------------------------------------
CASE="untracked_pi_not_dirty_without_exclude"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=piartifacts_noexclude STUB_AGY=pass
run_worker
EXCLUDE="$REPO/.git/info/exclude"
eq "前提：exclude 里确实没有 .pi/" "$(grep -cxF '.pi/' "$EXCLUDE" 2>/dev/null || true)" "0"
is_true "排除规则缺失时 status 确实列出 .pi/" '[[ -n "$(git -C "$WORKTREE" status --porcelain -uall | grep -E "^\\?\\? \\.pi/")" ]]'
eq "仍然不判 dirty_worktree" "$(done_field audit_reason)" "ok"
eq "仍能合推" "$(done_field auto_merged)" "1"
AUDITED="$(payload_field audited_commit)"
is_true "待审 tip 无 .pi/.task" '[[ -z "$(git -C "$WORKTREE" ls-tree -r --name-only "$AUDITED" -- .pi .task)" ]]'

# ---------------------------------------------------------------------------
CASE="merge_gate_task_dir_in_audited_tree"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=ok STUB_AGY=treetask STUB_SHA_OUT="$ROOT/pi.sha"
run_worker
PI_SHA="$(cat "$ROOT/pi.sha")"
eq "审查本身通过" "$(done_field audit)" "PASS"
eq "merge reason" "$(done_field merge_reason)" "task_dir_in_audited_tree"
eq "auto_merged" "$(done_field auto_merged)" "0"
eq "已审 SHA 未被改" "$(payload_field audited_commit)" "$PI_SHA"
eq "未在合入阶段新造提交" "$(git -C "$WORKTREE" rev-parse HEAD)" "$PI_SHA"
eq "远端未变" "$(remote_main)" "$INIT_SHA"
exists "worktree 保留" "$WORKTREE"
exists ".task 证据保留" "$WORKTREE/.task/evidence/proof.txt"
match "合推日志记录拒合原因" "$(cat "$WORKTREE/.task/$TICKET-merge.txt" 2>/dev/null)" "task_dir_in_audited_tree|audited tree still tracks"

# ---------------------------------------------------------------------------
printf '\n==== summary: %d passed, %d failed ====\n' "$PASSED" "$FAILED"
if [[ "$FAILED" -gt 0 ]]; then
  printf 'failed:\n'
  printf '  - %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi
