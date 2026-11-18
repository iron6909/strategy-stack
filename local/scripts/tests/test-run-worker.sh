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
  unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM STUB_AGY STUB_PI STUB_CURL_OUT

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
esac
mkdir -p .task/evidence
echo "proof line for ${STUB_PI:-ok}" > .task/evidence/proof.txt
echo "feat-${STUB_PI:-ok}" >> feature.txt
git add feature.txt
git commit -qm "feat: stub work"
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

run_worker() {
  OUT="$(
    bash "$SCRIPT" --repo "$REPO" --ticket "$TICKET" --prompt-file "$ROOT/prompt.md" 2>&1
  )"
  RC=$?
  DONE_LINE="$(printf '%s\n' "$OUT" | grep '^\[DONE\]' | tail -n1)"
}

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
printf '\n==== summary: %d passed, %d failed ====\n' "$PASSED" "$FAILED"
if [[ "$FAILED" -gt 0 ]]; then
  printf 'failed:\n'
  printf '  - %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi
