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
  unset STUB_AGY_STDIN_BYTES STUB_AGY_STDIN_SHA STUB_AGY_STDIN_COPY STUB_PI_EVIDENCE_FILES STUB_PI_EVIDENCE_BYTES
  unset MOZ29_FAKE_KEY MOZ29_KEEP_KEY NO_PROXY no_proxy
  PROMPT_SRC=""

  BIN="$ROOT/bin"
  mkdir -p "$BIN"
  # 门禁桩：本机真实 pi 会话不应阻断回归测试
  printf '#!/usr/bin/env bash\necho 0\n' > "$BIN/pgrep"
  printf '#!/usr/bin/env bash\necho "              total        used        free      shared  buff/cache   available"\necho "Mem:          32000        1000       20000           0        1000       20000"\n' > "$BIN/free"

  cat > "$BIN/pi" <<'PI'
#!/usr/bin/env bash
printf 'pi %s\n' "$*" >> "${STUB_LOG:-/dev/null}"
printf 'env MOZ29_FAKE=%s MOZ29_KEEP=%s\n' "${MOZ29_FAKE_KEY:-unset}" "${MOZ29_KEEP_KEY:-unset}" >> "${STUB_LOG:-/dev/null}"
printf 'proxy NO_PROXY=%s no_proxy=%s\n' "${NO_PROXY:-unset}" "${no_proxy:-unset}" >> "${STUB_LOG:-/dev/null}"
CUSTOMONLY=0
case "${STUB_PI:-ok}" in
  fail)  exit 7 ;;
  dirty) echo dirty >> ./f.txt; exit 0 ;;
  none)  exit 0 ;;
  customonly)
    # 只动 custom/：应当被双绿灯放行
    CUSTOMONLY=1
    mkdir -p custom/tools
    echo tool > custom/tools/tool.py
    echo tweak >> custom/keep.txt ;;
  newroot)
    CUSTOMONLY=1
    echo new > notes.md ;;
  upstreammod)
    CUSTOMONLY=1
    echo cheat >> Makefile ;;
  delroot)
    CUSTOMONLY=1
    git rm -q Makefile ;;
  rootagents)
    CUSTOMONLY=1
    echo "- 作弊追加" >> AGENTS.md ;;
  rmcharter)
    CUSTOMONLY=1
    git rm -q custom/AGENTS.md ;;
  symlinkcharter)
    CUSTOMONLY=1
    rm -f custom/AGENTS.md
    ln -s /etc/hostname custom/AGENTS.md ;;
  renameout)
    CUSTOMONLY=1
    mkdir -p docs
    git mv custom/keep.txt docs/keep.txt ;;
  spaceout)
    CUSTOMONLY=1
    mkdir -p "docs dir"
    echo x > "docs dir/a b.md" ;;
  newlineout)
    CUSTOMONLY=1
    mkdir -p "docs dir"
    printf 'x\n' > "docs dir/$(printf 'a\nb').md" ;;
  outtracked)
    # 模拟 agent 用 -f 把运行目录入库（.task/out/projects），并留下真实 custom/ 改动
    CUSTOMONLY=1
    mkdir -p out projects .task/evidence custom/tools
    echo o > out/run.log
    echo p > projects/p.json
    echo t > .task/evidence/t.txt
    echo tool > custom/tools/out.py
    git add -f out projects .task ;;
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
# 模拟真实工单里体积很大的文本证据（MOZ-17 的 bundle 就是这样胀到 146KB 的）
if [[ -n "${STUB_PI_EVIDENCE_FILES:-}" ]]; then
  for i in $(seq 1 "$STUB_PI_EVIDENCE_FILES"); do
    head -c "${STUB_PI_EVIDENCE_BYTES:-8000}" /dev/zero | tr '\0' 'e' > ".task/evidence/big-$i.log"
  done
fi
if [[ "$CUSTOMONLY" -eq 0 ]]; then
  echo "feat-${STUB_PI:-ok}" >> feature.txt
  git add feature.txt
  git commit -qm "feat: stub work"
else
  git add -A
  git commit -qm "feat: stub work"
fi
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
printf 'env MOZ29_FAKE=%s MOZ29_KEEP=%s\n' "${MOZ29_FAKE_KEY:-unset}" "${MOZ29_KEEP_KEY:-unset}" >> "${STUB_LOG:-/dev/null}"
printf 'proxy NO_PROXY=%s no_proxy=%s\n' "${NO_PROXY:-unset}" "${no_proxy:-unset}" >> "${STUB_LOG:-/dev/null}"
# 必须读满 stdin 到 EOF：用例拿字节数与哈希断言「送审内容未截断」
STDIN_TMP="$(mktemp)"
cat > "$STDIN_TMP"
if [[ -n "${STUB_AGY_STDIN_BYTES:-}" ]]; then wc -c < "$STDIN_TMP" | tr -d ' ' > "$STUB_AGY_STDIN_BYTES"; fi
if [[ -n "${STUB_AGY_STDIN_SHA:-}" ]]; then sha256sum "$STDIN_TMP" | cut -d' ' -f1 > "$STUB_AGY_STDIN_SHA"; fi
if [[ -n "${STUB_AGY_STDIN_COPY:-}" ]]; then cp "$STDIN_TMP" "$STUB_AGY_STDIN_COPY"; fi
rm -f "$STDIN_TMP"
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
  treeout)
    # 同上，但把 out/ 塞进已审树的视图：只能靠合入前的 ls-tree 闭锁拦住。
    printf 'VERDICT: PASS\n[Consider] 无\n'
    mkdir -p out
    echo x > out/x.log
    git add -f out
    repl="$(git commit-tree "$(git write-tree)" -p HEAD -m "fake tree with out/")"
    git replace HEAD "$repl" ;;
  treeagents)
    # 已审树里的根 AGENTS.md 被改：只能靠合入前的门禁复查拦住（行级 ls-tree 闭锁不管这个）
    printf 'VERDICT: PASS\n[Consider] 无\n'
    echo cheat >> AGENTS.md
    git add AGENTS.md
    repl="$(git commit-tree "$(git write-tree)" -p HEAD -m "fake tree with root AGENTS.md change")"
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
    bash "$SCRIPT" --repo "$1" --ticket "$TICKET" --prompt-file "${PROMPT_SRC:-$ROOT/prompt.md}" 2>&1
  )"
  RC=$?
  DONE_LINE="$(printf '%s\n' "$OUT" | grep '^\[DONE\]' | tail -n1)"
}
run_worker() { run_worker_at "$REPO"; }
run_worker_audit_only() {
  OUT="$(
    bash "$SCRIPT" --repo "$REPO" --ticket "$TICKET" --prompt-file "${PROMPT_SRC:-$ROOT/prompt.md}" --audit-only 2>&1
  )"
  RC=$?
  DONE_LINE="$(printf '%s\n' "$OUT" | grep '^\[DONE\]' | tail -n1)"
}

done_field() { printf '%s\n' "$DONE_LINE" | grep -oE "$1=[^ ]*" | tail -n1 | cut -d= -f2-; }
payload_field() { sed -n "s/^  \"$1\": *//p" "$PAYLOAD" | sed -e 's/,$//' -e 's/^"//' -e 's/"$//'; }
remote_main() { git -C "$ROOT/remote.git" rev-parse refs/heads/main; }
remote_count() { git -C "$ROOT/remote.git" rev-list --count refs/heads/main; }
worktree_field() { git -C "$WORKTREE" "$@"; }
agy_lines() { grep '^agy ' "$ROOT/stub.log" 2>/dev/null || true; }
agy_argv_maxlen() { awk '/^agy /{ if (length($0) > m) m = length($0) } END { print m + 0 }' "$ROOT/stub.log" 2>/dev/null; }

CASE="bash -n"
if bash -n "$SCRIPT" 2>/dev/null; then ok "run-worker.sh 语法"; else no "run-worker.sh 语法"; fi
if bash -n "${BASH_SOURCE[0]}" 2>/dev/null; then ok "测试脚本语法"; else no "测试脚本语法"; fi

# ---------------------------------------------------------------------------
CASE="success_auto_merge_push"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=ok STUB_AGY=pass
export STUB_AGY_STDIN_BYTES="$ROOT/stdin.bytes" STUB_AGY_STDIN_SHA="$ROOT/stdin.sha"
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
exists "审查 prompt 全文落盘" "$WORKTREE/.task/audit-prompt.txt"
is_true "agy 不再用 -p 传 prompt" '[[ "$(agy_lines)" != *" -p "* ]]'
eq "agy stdin 读满整份 prompt" "$(cat "$ROOT/stdin.bytes")" "$(stat -c %s "$WORKTREE/.task/audit-prompt.txt")"
eq "agy stdin 哈希与 prompt 文件一致" "$(cat "$ROOT/stdin.sha")" "$(sha256sum "$WORKTREE/.task/audit-prompt.txt" | cut -d' ' -f1)"

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
# MOZ-18：bundle 超单参数上限（约 128KiB）时仍必须从 stdin 整份送审
big_bundle_case() {
  local files="$1" bytes="$2" label="$3" prompt_path total
  printf '\n[%s]\n' "$CASE"
  new_fixture
  export STUB_PI=ok STUB_AGY=pass
  export STUB_PI_EVIDENCE_FILES="$files" STUB_PI_EVIDENCE_BYTES="$bytes"
  export STUB_AGY_STDIN_BYTES="$ROOT/stdin.bytes" STUB_AGY_STDIN_SHA="$ROOT/stdin.sha"
  run_worker
  prompt_path="$WORKTREE/.task/audit-prompt.txt"
  total="$(stat -c %s "$prompt_path" 2>/dev/null || echo 0)"
  eq "$label: exit code" "$RC" "0"
  eq "$label: 审查通过" "$(done_field audit)" "PASS"
  eq "$label: 双绿灯合推" "$(done_field auto_merged)" "1"
  is_true "$label: 送审 prompt 超过 128KiB 单参数上限（$total bytes）" '[[ "$(cat "$STUB_AGY_STDIN_BYTES")" -gt 131072 ]]'
  eq "$label: agy 从 stdin 读满全部字节（无截断）" "$(cat "$STUB_AGY_STDIN_BYTES")" "$total"
  eq "$label: stdin 内容哈希与 prompt 文件一致" "$(cat "$ROOT/stdin.sha")" "$(sha256sum "$prompt_path" | cut -d' ' -f1)"
  is_true "$label: agy argv 无 -p" '[[ "$(agy_lines)" != *" -p "* ]]'
  is_true "$label: agy argv 长度 < 1KB" '[[ "$(agy_argv_maxlen)" -lt 1024 ]]'
  match "$label: agy 用 --input-format text 读 stdin" "$(agy_lines)" "--input-format text"
  is_true "$label: argv 未混入 bundle 正文" '! grep -q "REVIEW BUNDLE" "$ROOT/stub.log"'
  printf '  proof: %s prompt=%s bytes stdin=%s bytes argv_max=%s bytes\n' \
    "$label" "$total" "$(cat "$STUB_AGY_STDIN_BYTES")" "$(agy_argv_maxlen)"
}

CASE="bundle_146k_audit_stdin"
big_bundle_case 19 7700 "146KB"

CASE="bundle_208k_audit_stdin"
big_bundle_case 26 8000 "208KB"

# ---------------------------------------------------------------------------
CASE="audit_only_retry_existing_tip"
printf '\n[%s]\n' "$CASE"
new_fixture
# 模拟 MOZ-17：tip 已实现好、只重审不重写
git -C "$REPO" worktree add -q "$WORKTREE" -b "feat/$TICKET" main
(
  cd "$WORKTREE" || exit 1
  echo feat > feat.txt
  git add feat.txt
  git commit -qm "feat: existing tip"
) >/dev/null 2>&1
TIP="$(git -C "$WORKTREE" rev-parse HEAD)"
mkdir -p "$WORKTREE/.task/evidence"   # .task/ 脚本产物不算未提交实现改动
echo "prior proof" > "$WORKTREE/.task/evidence/prior.txt"
export STUB_AGY=pass STUB_AGY_STDIN_BYTES="$ROOT/stdin.bytes" STUB_AGY_STDIN_SHA="$ROOT/stdin.sha"
run_worker_audit_only
PROMPT_PATH="$WORKTREE/.task/audit-prompt.txt"
eq "exit code" "$RC" "0"
is_true "未运行 pi" '[[ -z "$(grep "^pi " "$ROOT/stub.log" 2>/dev/null)" ]]'
eq "已审 commit 就是既有 tip（未重写）" "$(payload_field audited_commit)" "$TIP"
eq "worktree tip 未漂移" "$(git -C "$WORKTREE" rev-parse HEAD)" "$TIP"
eq "审查通过" "$(done_field audit)" "PASS"
eq "双绿灯合推" "$(done_field auto_merged)" "1"
eq "merge reason" "$(done_field merge_reason)" "merged_and_pushed"
eq "远端 tip == merge_commit" "$(done_field merge_commit)" "$(remote_main)"
is_true "远端已含既有 tip" "git -C '$ROOT/remote.git' merge-base --is-ancestor '$TIP' refs/heads/main"
eq "agy stdin 读满整份 prompt" "$(cat "$ROOT/stdin.bytes")" "$(stat -c %s "$PROMPT_PATH")"
eq "stdin 哈希与 prompt 文件一致" "$(cat "$ROOT/stdin.sha")" "$(sha256sum "$PROMPT_PATH" | cut -d' ' -f1)"

# ---------------------------------------------------------------------------
CASE="audit_only_rejects_uncommitted_implementation"
printf '\n[%s]\n' "$CASE"
new_fixture
git -C "$REPO" worktree add -q "$WORKTREE" -b "feat/$TICKET" main
(
  cd "$WORKTREE" || exit 1
  echo feat > feat.txt
  git add feat.txt
  git commit -qm "feat: existing tip"
) >/dev/null 2>&1
echo "uncommitted tweak" >> "$WORKTREE/feat.txt"
export STUB_AGY=pass
run_worker_audit_only
eq "audit verdict" "$(done_field audit)" "FAIL"
eq "audit reason" "$(done_field audit_reason)" "dirty_worktree"
eq "auto_merged" "$(done_field auto_merged)" "0"
eq "远端未变" "$(remote_main)" "$INIT_SHA"
is_true "审查未启动" '[[ -z "$(agy_lines)" ]]'
absent "脏树不写审查报告" "$WORKTREE/.task/$TICKET-audit.md"
exists "worktree 保留" "$WORKTREE"

# ---------------------------------------------------------------------------
CASE="audit_only_worktree_missing"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_AGY=pass
run_worker_audit_only
eq "exit code" "$RC" "4"
match "拒绝无 tip 可审" "$OUT" "--audit-only"
absent "未凭空建 worktree" "$WORKTREE"
eq "远端未变" "$(remote_main)" "$INIT_SHA"

# ---------------------------------------------------------------------------
CASE="audit_only_recreates_worktree_from_branch"
printf '\n[%s]\n' "$CASE"
new_fixture
git -C "$REPO" worktree add -q "$ROOT/tmpwt" -b "feat/$TICKET" main
(
  cd "$ROOT/tmpwt" || exit 1
  echo feat > feat.txt
  git add feat.txt
  git commit -qm "feat: branch tip"
) >/dev/null 2>&1
TIP="$(git -C "$ROOT/tmpwt" rev-parse HEAD)"
git -C "$REPO" worktree remove "$ROOT/tmpwt"
export STUB_AGY=pass
run_worker_audit_only
eq "exit code" "$RC" "0"
eq "审计目标仍是既有分支 tip" "$(payload_field audited_commit)" "$TIP"
eq "双绿灯合推" "$(done_field auto_merged)" "1"
is_true "远端已含既有 tip" "git -C '$ROOT/remote.git' merge-base --is-ancestor '$TIP' refs/heads/main"

# ---------------------------------------------------------------------------
# MOZ-21：custom/AGENTS.md 注入 + 免侵入物理门禁
# 门禁用例的 upstream 一律是临时 bare：remote.upstream.url 写 OpenMontage 公开源，
# 用 url.*.insteadOf 把该 URL 重写到本地 bare，既不联网也不改 origin。
make_charter_base() {
  (
    cd "$REPO" || exit 1
    mkdir -p custom
    printf '# 测试宪章\n- 只允许改 custom/\n' > custom/AGENTS.md
    printf 'keep\n' > custom/keep.txt
    echo upstream-original > Makefile
    echo root-original > AGENTS.md
    git add custom Makefile AGENTS.md
    git commit -qm "chore(custom): seed charter"
    git push -q origin main
  ) >/dev/null 2>&1
  INIT_SHA="$(git -C "$ROOT/remote.git" rev-parse refs/heads/main)"
  CHARTER_HEAD="$ROOT/expected-head"
  printf '%s\n\n%s\n\n' "$(cat "$REPO/custom/AGENTS.md")" "=== 本次具体工单任务 ===" > "$CHARTER_HEAD"
  PROMPT_COPY_PATH="$ROOT/worktrees/$TICKET/.task/$TICKET-prompt.md"
}

seed_openmontage_upstream() {
  git config --global "url.$ROOT/upstream.git.insteadOf" "https://github.com/calesthio/OpenMontage.git"
  git -C "$REPO" remote add upstream "https://github.com/calesthio/OpenMontage.git"
  git -C "$REPO" fetch -q upstream main
}

new_charter_fixture() {
  new_fixture
  make_charter_base
  git clone -q --bare "$ROOT/remote.git" "$ROOT/upstream.git"
  seed_openmontage_upstream
}

# 历史 base 已合入 custom/ 以外残留：上游快照先拍，main 上再塞一处越界改动。
# 三点 diff（base...commit）看不见它，两点 vs upstream 必须抓得到。
new_residue_fixture() {
  new_fixture
  make_charter_base
  git clone -q --bare "$ROOT/remote.git" "$ROOT/upstream.git"
  (
    cd "$REPO" || exit 1
    echo "legacy residue" >> Makefile
    git commit -qam "legacy change outside custom/ already on base"
    git push -q origin main
  ) >/dev/null 2>&1
  INIT_SHA="$(git -C "$ROOT/remote.git" rev-parse refs/heads/main)"
  seed_openmontage_upstream
}

audit_first_line() { sed -n '1p' "$WORKTREE/.task/$TICKET-audit.md" 2>/dev/null; }
audit_body() { cat "$WORKTREE/.task/$TICKET-audit.md" 2>/dev/null; }

# ---------------------------------------------------------------------------
CASE="custom_gate_allows_custom_only"
printf '\n[%s]\n' "$CASE"
new_charter_fixture
export STUB_PI=customonly STUB_AGY=pass
run_worker
eq "exit code" "$RC" "0"
eq "审查通过" "$(done_field audit)" "PASS"
eq "双绿灯合推" "$(done_field auto_merged)" "1"
eq "merge reason" "$(done_field merge_reason)" "merged_and_pushed"
eq "远端 tip == merge_commit" "$(done_field merge_commit)" "$(remote_main)"
is_true "远端已含 custom/tools/tool.py" '[[ -n "$(git -C "$ROOT/remote.git" ls-tree -r --name-only refs/heads/main -- custom/tools/tool.py)" ]]'
is_true "远端 Makefile 未被改" '[[ "$(git -C "$ROOT/remote.git" show refs/heads/main:Makefile)" == "upstream-original" ]]'
printf '  proof: merge_commit=%s remote_main=%s\n' "$(done_field merge_commit)" "$(remote_main)"

# ---------------------------------------------------------------------------
CASE="custom_gate_prompt_injection"
printf '\n[%s]\n' "$CASE"
new_charter_fixture
export STUB_PI=customonly STUB_AGY=pass
run_worker
P="$PROMPT_COPY_PATH"
HEAD_BYTES="$(stat -c %s "$CHARTER_HEAD")"
eq "审查通过" "$(done_field audit)" "PASS"
exists "有效提示文件存在" "$P"
if cmp -s -n "$HEAD_BYTES" -i 0 "$CHARTER_HEAD" "$P"; then
  ok "首部 = 宪章全文 + 空行 + 分隔行 + 空行"
else
  no "首部 = 宪章全文 + 空行 + 分隔行 + 空行"
fi
eq "分隔行只出现一次" "$(grep -cxF '=== 本次具体工单任务 ===' "$P")" "1"
eq "宪章标题只出现一次" "$(grep -cxF '# 测试宪章' "$P")" "1"
eq "原 prompt 正文仍在尾部" "$(tail -n1 "$P")" "$(tail -n1 "$ROOT/prompt.md")"
is_true "提示文件不是截空的（比宪章头更长）" '[[ "$(stat -c %s "$P")" -gt "$HEAD_BYTES" ]]'
is_true "pi 收到的是注入后的提示" '[[ "$(grep -cxF "=== 本次具体工单任务 ===" "$ROOT/stub.log")" -ge 1 ]]'
match "review bundle 含宪章" "$(cat "$WORKTREE/.task/review-bundle.txt" 2>/dev/null)" "只允许改 custom/"
match "送审 prompt 含宪章" "$(cat "$WORKTREE/.task/audit-prompt.txt" 2>/dev/null)" "只允许改 custom/"
printf '  proof: charter_head=%s bytes prompt_copy=%s bytes\n' "$HEAD_BYTES" "$(stat -c %s "$P")"
# resume/二次派发：把已注入的文件当源再跑一次，宪章不得叠第二层
cp "$P" "$ROOT/prompt-injected.md"
PROMPT_SRC="$ROOT/prompt-injected.md"
export STUB_PI=none
run_worker
eq "resume 幂等合推" "$(done_field merge_reason)" "already_merged"
eq "resume 后分隔行仍只有一层" "$(grep -cxF '=== 本次具体工单任务 ===' "$P")" "1"
eq "resume 后宪章仍只有一份" "$(grep -cxF '# 测试宪章' "$P")" "1"
eq "resume 后正文仍是原 prompt" "$(tail -n1 "$P")" "$(tail -n1 "$ROOT/prompt.md")"
if cmp -s -n "$HEAD_BYTES" -i 0 "$CHARTER_HEAD" "$P"; then
  ok "resume 后注入头未变"
else
  no "resume 后注入头未变"
fi

# ---------------------------------------------------------------------------
CASE="custom_gate_rejects_upstream_add_modify_delete"
printf '\n[%s]\n' "$CASE"
for mode in newroot upstreammod delroot rootagents; do
  case "$mode" in
    newroot)     expect='notes\.md' ;;
    upstreammod) expect='Makefile' ;;
    delroot)     expect='Makefile' ;;
    rootagents)  expect='AGENTS\.md' ;;
  esac
  new_charter_fixture
  export STUB_PI="$mode" STUB_AGY=pass
  run_worker
  eq "$mode: audit reason" "$(done_field audit_reason)" "custom_gate_violation"
  eq "$mode: audit 首行恰为 VERDICT: FAIL" "$(audit_first_line)" "VERDICT: FAIL"
  match "$mode: 列出越界路径" "$(audit_body)" "\[Act On\] base:$expect"
  match "$mode: upstream 侧也列出" "$(audit_body)" "\[Act On\] upstream:$expect"
  eq "$mode: auto_merged" "$(done_field auto_merged)" "0"
  eq "$mode: 远端未变" "$(remote_main)" "$INIT_SHA"
  is_true "$mode: 未启动 agy" '[[ -z "$(agy_lines)" ]]'
  is_true "$mode: 合推日志为空（未尝试合推）" '[[ ! -s "$WORKTREE/.task/$TICKET-merge.txt" ]]'
  exists "$mode: worktree 保留" "$WORKTREE"
  exists "$mode: 证据保留" "$WORKTREE/.task/evidence/proof.txt"
done

# ---------------------------------------------------------------------------
CASE="custom_gate_rejects_charter_escape"
printf '\n[%s]\n' "$CASE"
for mode in rmcharter symlinkcharter; do
  case "$mode" in
    rmcharter)      expect='charter_missing:custom/AGENTS\.md' ;;
    symlinkcharter) expect='charter_not_regular:custom/AGENTS\.md' ;;
  esac
  new_charter_fixture
  export STUB_PI="$mode" STUB_AGY=pass
  run_worker
  eq "$mode: 仍然开闸（防删除/换链接逃逸）" "$(done_field audit_reason)" "custom_gate_violation"
  eq "$mode: audit 首行恰为 VERDICT: FAIL" "$(audit_first_line)" "VERDICT: FAIL"
  match "$mode: 列出宪章违规" "$(audit_body)" "$expect"
  eq "$mode: auto_merged" "$(done_field auto_merged)" "0"
  eq "$mode: 远端未变" "$(remote_main)" "$INIT_SHA"
  is_true "$mode: 未启动 agy" '[[ -z "$(agy_lines)" ]]'
done

# ---------------------------------------------------------------------------
CASE="custom_gate_rejects_cross_boundary_rename"
printf '\n[%s]\n' "$CASE"
new_charter_fixture
export STUB_PI=renameout STUB_AGY=pass
run_worker
eq "audit reason" "$(done_field audit_reason)" "custom_gate_violation"
match "rename 目标侧（越界）列出" "$(audit_body)" '\[Act On\] base:docs/keep\.txt'
is_true "rename 源侧在 custom/ 内不算越界" '[[ "$(audit_body)" != *"base:custom/keep.txt"* ]]'
eq "远端未变" "$(remote_main)" "$INIT_SHA"

# ---------------------------------------------------------------------------
CASE="custom_gate_rejects_weird_paths"
printf '\n[%s]\n' "$CASE"
new_charter_fixture
export STUB_PI=spaceout STUB_AGY=pass
run_worker
eq "含空格: audit reason" "$(done_field audit_reason)" "custom_gate_violation"
match "含空格的越界路径完整列出" "$(audit_body)" '\[Act On\] base:docs dir/a b\.md'
eq "含空格: auto_merged" "$(done_field auto_merged)" "0"

new_charter_fixture
export STUB_PI=newlineout STUB_AGY=pass
run_worker
eq "含换行: audit reason" "$(done_field audit_reason)" "custom_gate_violation"
# 含换行路径在 eval 里使用，export 以免被当成未使用变量
export NL_PATH="$(printf '[Act On] base:docs dir/a\nb.md')"
is_true "含换行的越界路径完整列出（NUL 分隔未串行）" 'grep -qF "$NL_PATH" "$WORKTREE/.task/$TICKET-audit.md"'
eq "含换行: auto_merged" "$(done_field auto_merged)" "0"

# ---------------------------------------------------------------------------
CASE="custom_gate_two_point_vs_upstream"
printf '\n[%s]\n' "$CASE"
new_residue_fixture
export STUB_PI=customonly STUB_AGY=pass
run_worker
AUDITED="$(payload_field audited_commit)"
eq "历史残留被抓" "$(done_field audit_reason)" "custom_gate_violation"
match "upstream 两点比对列出 Makefile" "$(audit_body)" '\[Act On\] upstream:Makefile'
is_true "三点 diff 看不见残留（所以必须两点）" '[[ -z "$(git -C "$WORKTREE" diff --name-only "$INIT_SHA...$AUDITED" -- Makefile)" ]]'
is_true "两点 diff vs upstream 才抓到" '[[ -n "$(git -C "$WORKTREE" diff --name-only "$AUDITED" refs/remotes/upstream/main -- Makefile)" ]]'
printf '  proof: base=%s audited=%s upstream=%s\n' "$INIT_SHA" "$AUDITED" "$(git -C "$WORKTREE" rev-parse refs/remotes/upstream/main)"

# ---------------------------------------------------------------------------
CASE="custom_gate_upstream_ref_fail_closed"
printf '\n[%s]\n' "$CASE"
# 1) 根本没配 upstream remote
new_fixture
make_charter_base
git clone -q --bare "$ROOT/remote.git" "$ROOT/upstream.git"
export STUB_PI=customonly STUB_AGY=pass
run_worker
eq "缺失 remote: audit reason" "$(done_field audit_reason)" "custom_gate_upstream_ref_missing"
eq "缺失 remote: auto_merged" "$(done_field auto_merged)" "0"
eq "缺失 remote: 远端未变" "$(remote_main)" "$INIT_SHA"
is_true "缺失 remote: 未启动 agy" '[[ -z "$(agy_lines)" ]]'
match "缺失 remote: audit 写明 reason" "$(audit_body)" 'upstream_ref_missing'
# 2) URL 对了但从未 fetch 出 ref
new_fixture
make_charter_base
git -C "$REPO" remote add upstream "https://github.com/calesthio/OpenMontage.git"
export STUB_PI=customonly STUB_AGY=pass
run_worker
eq "未 fetch: audit reason" "$(done_field audit_reason)" "custom_gate_upstream_ref_missing"
eq "未 fetch: 远端未变" "$(remote_main)" "$INIT_SHA"
# 3) ref 存在但 remote URL 不是公开源
new_fixture
make_charter_base
git clone -q --bare "$ROOT/remote.git" "$ROOT/upstream.git"
git -C "$REPO" remote add upstream "https://example.invalid/OpenMontage.git"
git -C "$REPO" fetch -q "$ROOT/upstream.git" main:refs/remotes/upstream/main
export STUB_PI=customonly STUB_AGY=pass
run_worker
eq "错 URL: audit reason" "$(done_field audit_reason)" "custom_gate_upstream_ref_missing"
eq "错 URL: 远端未变" "$(remote_main)" "$INIT_SHA"

# ---------------------------------------------------------------------------
CASE="custom_gate_no_charter_not_enabled"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=upstreammod STUB_AGY=pass
run_worker
P="$WORKTREE/.task/$TICKET-prompt.md"
eq "无宪章仓库审查通过（门禁不误开）" "$(done_field audit)" "PASS"
eq "audit reason" "$(done_field audit_reason)" "ok"
eq "双绿灯合推" "$(done_field auto_merged)" "1"
eq "未注入分隔行" "$(grep -cxF '=== 本次具体工单任务 ===' "$P")" "0"
if cmp -s "$P" "$ROOT/prompt.md"; then
  ok "有效提示文件与原 prompt 逐字节一致"
else
  no "有效提示文件与原 prompt 逐字节一致"
fi

# ---------------------------------------------------------------------------
CASE="custom_gate_untracks_runtime_dirs"
printf '\n[%s]\n' "$CASE"
new_charter_fixture
export STUB_PI=outtracked STUB_AGY=pass STUB_SHA_OUT="$ROOT/pi.sha"
run_worker
PI_SHA="$(cat "$ROOT/pi.sha")"
AUDITED="$(payload_field audited_commit)"
eq "审查通过" "$(done_field audit)" "PASS"
eq "双绿灯合推" "$(done_field auto_merged)" "1"
is_true "已审 SHA 换成不含运行目录的 tree" '[[ "$AUDITED" != "$PI_SHA" ]]'
is_true "已审 tree 无 .task/out/projects/.pi" '[[ -z "$(git -C "$WORKTREE" ls-tree -r --name-only "$AUDITED" -- .task out projects .pi)" ]]'
is_true "远端 main 无 .task/out/projects/.pi" '[[ -z "$(git -C "$ROOT/remote.git" ls-tree -r --name-only refs/heads/main -- .task out projects .pi)" ]]'
exists "out/ 产物仍在工作区" "$WORKTREE/out/run.log"
exists ".task 证据仍在工作区" "$WORKTREE/.task/evidence/t.txt"
printf '  proof: pi_sha=%s audited=%s\n' "$PI_SHA" "$AUDITED"

# ---------------------------------------------------------------------------
CASE="custom_gate_merge_recheck_tree_lock"
printf '\n[%s]\n' "$CASE"
new_charter_fixture
export STUB_PI=customonly STUB_AGY=treeout STUB_SHA_OUT="$ROOT/pi.sha"
run_worker
PI_SHA="$(cat "$ROOT/pi.sha")"
eq "agy 侧审查通过" "$(done_field audit)" "PASS"
eq "合入前 ls-tree 闭锁拦住 out/" "$(done_field merge_reason)" "task_dir_in_audited_tree"
eq "auto_merged" "$(done_field auto_merged)" "0"
eq "已审 SHA 未被改" "$(git -C "$WORKTREE" rev-parse HEAD)" "$PI_SHA"
eq "远端未变" "$(remote_main)" "$INIT_SHA"
match "合推日志记录运行目录" "$(cat "$WORKTREE/.task/$TICKET-merge.txt" 2>/dev/null)" 'out/x.log'

# ---------------------------------------------------------------------------
CASE="custom_gate_merge_recheck_gate"
printf '\n[%s]\n' "$CASE"
new_charter_fixture
export STUB_PI=customonly STUB_AGY=treeagents STUB_SHA_OUT="$ROOT/pi.sha"
run_worker
PI_SHA="$(cat "$ROOT/pi.sha")"
eq "agy 侧审查通过" "$(done_field audit)" "PASS"
eq "合入前门禁复查拦住根 AGENTS.md" "$(done_field merge_reason)" "custom_gate_violation"
eq "auto_merged" "$(done_field auto_merged)" "0"
eq "已审 SHA 未被改" "$(git -C "$WORKTREE" rev-parse HEAD)" "$PI_SHA"
eq "远端未变" "$(remote_main)" "$INIT_SHA"
match "合推日志列出越界路径" "$(cat "$WORKTREE/.task/$TICKET-merge.txt" 2>/dev/null)" 'AGENTS\.md'
exists "worktree 与证据保留" "$WORKTREE/.task/evidence/proof.txt"

# ---------------------------------------------------------------------------
CASE="custom_gate_audit_only"
printf '\n[%s]\n' "$CASE"
new_charter_fixture
git -C "$REPO" worktree add -q "$WORKTREE" -b "feat/$TICKET" main
(
  cd "$WORKTREE" || exit 1
  echo cheat >> Makefile
  git commit -qam "cheat: touch upstream file"
) >/dev/null 2>&1
export STUB_AGY=pass
run_worker_audit_only
eq "exit code" "$RC" "0"
eq "--audit-only 同样拦截" "$(done_field audit_reason)" "custom_gate_violation"
eq "audit 首行恰为 VERDICT: FAIL" "$(audit_first_line)" "VERDICT: FAIL"
match "列出 Makefile" "$(audit_body)" '\[Act On\] base:Makefile'
is_true "未启动 agy" '[[ -z "$(agy_lines)" ]]'
eq "auto_merged" "$(done_field auto_merged)" "0"
eq "远端未变" "$(remote_main)" "$INIT_SHA"
exists "提示文件已生成" "$PROMPT_COPY_PATH"
HEAD_BYTES="$(stat -c %s "$CHARTER_HEAD")"
if cmp -s -n "$HEAD_BYTES" -i 0 "$CHARTER_HEAD" "$PROMPT_COPY_PATH"; then
  ok "--audit-only 也注入宪章"
else
  no "--audit-only 也注入宪章"
fi
match "--audit-only bundle 含宪章" "$(cat "$WORKTREE/.task/review-bundle.txt" 2>/dev/null)" "只允许改 custom/"
# 正例：只改 custom/ 的 tip 在 --audit-only 下仍可双绿灯合推
new_charter_fixture
git -C "$REPO" worktree add -q "$WORKTREE" -b "feat/$TICKET" main
(
  cd "$WORKTREE" || exit 1
  mkdir -p custom/tools
  echo tool > custom/tools/only.py
  git add -A custom
  git commit -qm "feat: custom only"
) >/dev/null 2>&1
export STUB_AGY=pass
run_worker_audit_only
eq "正例: 审查通过" "$(done_field audit)" "PASS"
eq "正例: 双绿灯合推" "$(done_field auto_merged)" "1"
eq "正例: merge reason" "$(done_field merge_reason)" "merged_and_pushed"

# ---------------------------------------------------------------------------
# MOZ-29：pi/agy 启动前从 $HOME/.harness/providers.env 注入
# 只用临时 HOME 里的编造假值，真实 ~/.harness/providers.env 不参与任何用例。
FAKE_KEY="moz29-fake-do-not-use-0001"
EV_REL=".task/evidence/providers-env.txt"

CASE="providers_env_missing"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=ok STUB_AGY=pass
run_worker
EV="$WORKTREE/$EV_REL"
eq "exit code" "$RC" "0"
eq "审查通过" "$(done_field audit)" "PASS"
eq "仍能双绿灯合推" "$(done_field auto_merged)" "1"
eq "pi 与 agy 都看不到任何注入键" "$(grep -cxF 'env MOZ29_FAKE=unset MOZ29_KEEP=unset' "$ROOT/stub.log")" "2"
eq "证据记录受信路径" "$(grep -cxF "path=$HOME/.harness/providers.env" "$EV")" "1"
eq "证据记录 exists=0" "$(grep -cxF 'exists=0' "$EV")" "1"
eq "证据记录 injected=0" "$(grep -cxF 'injected=0' "$EV")" "1"
eq "无键名行" "$(grep -c '^key=' "$EV")" "0"

CASE="providers_env_injected"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=ok STUB_AGY=pass
mkdir -p "$HOME/.harness"
printf 'MOZ29_FAKE_KEY=%s\n' "$FAKE_KEY" > "$HOME/.harness/providers.env"
chmod 600 "$HOME/.harness/providers.env"
# 诱饵：受信路径之外的同名文件一律不得被 source
printf 'MOZ29_DECOY_KEY=decoy\n' > "$ROOT/providers.env"
printf 'MOZ29_DECOY_KEY=decoy\n' > "$REPO/providers.env"
run_worker
EV="$WORKTREE/$EV_REL"
eq "exit code" "$RC" "0"
eq "pi 与 agy 两个子进程都拿到假键" "$(grep -cxF "env MOZ29_FAKE=$FAKE_KEY MOZ29_KEEP=unset" "$ROOT/stub.log")" "2"
eq "审查通过" "$(done_field audit)" "PASS"
eq "双绿灯合推" "$(done_field auto_merged)" "1"
eq "证据记录 exists=1" "$(grep -cxF 'exists=1' "$EV")" "1"
eq "证据记录权限" "$(grep -cxF 'mode=600' "$EV")" "1"
eq "证据记录键名 set" "$(grep -cxF 'key=MOZ29_FAKE_KEY:set' "$EV")" "1"
eq "非受信路径的同名文件未被 source" "$(grep -c '^key=MOZ29_DECOY_KEY' "$EV")" "0"
is_true "证据不含假密钥明文" '! grep -qF "$FAKE_KEY" "$EV"'
is_true "review bundle 不含假密钥明文" '! grep -qF "$FAKE_KEY" "$WORKTREE/.task/review-bundle.txt"'
is_true "送审 prompt 不含假密钥明文" '! grep -qF "$FAKE_KEY" "$WORKTREE/.task/audit-prompt.txt"'
is_true "webhook payload 不含假密钥明文" '! grep -qF "$FAKE_KEY" "$PAYLOAD"'
is_true "worker stdout/stderr 不含假密钥明文" '! grep -qF "$FAKE_KEY" <<< "$OUT"'
is_true "worktree 在 HOME 之外（跨 worktree 仍从该 HOME 注入）" '[[ "$WORKTREE" != "$HOME"/* ]]'

CASE="providers_env_cross_worktree"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=ok STUB_AGY=pass
mkdir -p "$HOME/.harness"
printf 'MOZ29_FAKE_KEY=%s\n' "$FAKE_KEY" > "$HOME/.harness/providers.env"
git -C "$REPO" worktree add -q "$ROOT/elsewhere/host" -b host-branch main
run_worker_at "$ROOT/elsewhere/host"
OTHER_WORKTREE="$ROOT/elsewhere/worktrees/$TICKET"
eq "exit code" "$RC" "0"
eq "worker 在独立 worktree 里仍注入" "$(grep -cxF "env MOZ29_FAKE=$FAKE_KEY MOZ29_KEEP=unset" "$ROOT/stub.log")" "2"
eq "证据落在该 worktree 的 .task/evidence" "$(grep -cxF 'exists=1' "$OTHER_WORKTREE/$EV_REL")" "1"
eq "独立 worktree 仍双绿灯审查" "$(done_field audit)" "PASS"

CASE="providers_env_source_failure"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=ok STUB_AGY=pass
mkdir -p "$HOME/.harness"
printf 'MOZ29_FAKE_KEY=%s\nif then\n' "$FAKE_KEY" > "$HOME/.harness/providers.env"
run_worker
EV="$WORKTREE/$EV_REL"
eq "source 失败必须非 0 退出" "$RC" "5"
match "输出写明注入失败" "$OUT" '\[FAIL\] 注入 .*providers\.env 失败'
is_true "pi 未启动" '[[ -z "$(grep "^pi " "$ROOT/stub.log" 2>/dev/null)" ]]'
is_true "agy 未启动" '[[ -z "$(agy_lines)" ]]'
eq "远端未变" "$(remote_main)" "$INIT_SHA"
exists "worktree 保留" "$WORKTREE"
eq "证据记录 injected=0" "$(grep -cxF 'injected=0' "$EV")" "1"
is_true "证据不含假密钥明文" '! grep -qF "$FAKE_KEY" "$EV"'
is_true "日志不含假密钥明文（source 报错不回显文件内容）" '! grep -qF "$FAKE_KEY" <<< "$OUT"'

CASE="providers_env_keeps_process_env"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=ok STUB_AGY=pass MOZ29_KEEP_KEY=from-outer
mkdir -p "$HOME/.harness"
printf 'MOZ29_KEEP_KEY=from-file\nMOZ29_FAKE_KEY=%s\n' "$FAKE_KEY" > "$HOME/.harness/providers.env"
run_worker
EV="$WORKTREE/$EV_REL"
eq "pi 与 agy 都保留外层已有值" "$(grep -cxF "env MOZ29_FAKE=$FAKE_KEY MOZ29_KEEP=from-outer" "$ROOT/stub.log")" "2"
eq "证据记录 key:kept" "$(grep -cxF 'key=MOZ29_KEEP_KEY:kept' "$EV")" "1"
eq "证据不记被保留变量的值" "$(grep -c from-outer "$EV")" "0"

# ---------------------------------------------------------------------------
# MOZ-36：注入后合并 NO_PROXY / no_proxy，pi 与 agy 都拿到回环绕行，已有绕行主机不丢
CASE="no_proxy_loopback_added"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=ok STUB_AGY=pass
printf 'MOZ29_FAKE_KEY=%s\n' "$FAKE_KEY" > "$HOME/.harness/providers.env"
run_worker
eq "exit code" "$RC" "0"
eq "pi 与 agy 都拿到三个回环名（两个大小写变量同值）" \
  "$(grep -cxF 'proxy NO_PROXY=127.0.0.1,localhost,::1 no_proxy=127.0.0.1,localhost,::1' "$ROOT/stub.log")" "2"

CASE="no_proxy_keeps_existing"
printf '\n[%s]\n' "$CASE"
new_fixture
export STUB_PI=ok STUB_AGY=pass NO_PROXY="api.corp.example"
# 文件只设小写变量，外层环境只设大写变量：合并后两个变量都要拿到全部条目
printf 'no_proxy=.corp.example\n' > "$HOME/.harness/providers.env"
run_worker
unset NO_PROXY
eq "外层大写条目与文件小写条目都保留，回环追加在后" \
  "$(grep -cxF 'proxy NO_PROXY=api.corp.example,.corp.example,127.0.0.1,localhost,::1 no_proxy=api.corp.example,.corp.example,127.0.0.1,localhost,::1' "$ROOT/stub.log")" "2"
eq "证据不记 NO_PROXY 的值" "$(grep -c 'corp.example' "$WORKTREE/$EV_REL")" "0"

# ---------------------------------------------------------------------------
printf '\n==== summary: %d passed, %d failed ====\n' "$PASSED" "$FAILED"
if [[ "$FAILED" -gt 0 ]]; then
  printf 'failed:\n'
  printf '  - %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi
