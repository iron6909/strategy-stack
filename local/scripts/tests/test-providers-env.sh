#!/usr/bin/env bash
# providers.env 注入回归：注入库单测 + run-video-worker.sh 集成 + 两脚本注入顺序静态检查。
# 全部在 mktemp 临时 HOME 里跑，只用编造的假值，绝不读写真实 ~/.harness/providers.env。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib/providers-env.sh"
VIDEO="$HERE/../run-video-worker.sh"
WORKER="$HERE/../run-worker.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/pe-tests.XXXXXX")"
if [[ "${KEEP_TMP:-0}" == "1" ]]; then
  trap 'printf "\n[kept] 临时目录保留在 %s\n" "$TMPROOT"' EXIT
else
  trap 'rm -rf "$TMPROOT"' EXIT
fi
BASE_PATH="$PATH"
FAKE_KEY="moz29-fake-do-not-use-0001"   # 编造假值：任何断言只认它
CANARY="moz29-canary-broken-line-0002" # 只用于验证损坏行不会被回显

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
lines() { grep -cxF -- "$2" "$1" 2>/dev/null || true; }

# 单测驱动：source 注入库 -> 注入 -> 用子进程回报变量可见性与 allexport 状态
cat > "$TMPROOT/inject-driver.sh" <<'DRIVER'
#!/usr/bin/env bash
set -uo pipefail
. "$LIB_PATH"
[[ "${PRE_ALLEXPORT:-0}" == 1 ]] && set -a
inject_providers_env "${EVIDENCE_PATH:-}"
echo "inject_rc=$?"
echo "child_fake=$(bash -c 'printf %s "${MOZ29_FAKE_KEY-unset}"')"
echo "child_keep=$(bash -c 'printf %s "${MOZ29_KEEP_KEY-unset}"')"
echo "allexport=$(if [[ -o allexport ]]; then echo on; else echo off; fi)"
DRIVER

new_home() {
  CASE_HOME="$(mktemp -d "$TMPROOT/case.XXXXXX")/home"
  export HOME="$CASE_HOME"
  mkdir -p "$HOME/.harness"
  EVIDENCE="$CASE_HOME/evidence.txt"
  unset MOZ29_FAKE_KEY MOZ29_KEEP_KEY PRE_ALLEXPORT
}
unit_run() {
  OUT="$(LIB_PATH="$LIB" EVIDENCE_PATH="$EVIDENCE" PRE_ALLEXPORT="${PRE_ALLEXPORT:-0}" \
    bash "$TMPROOT/inject-driver.sh" 2>&1)"
  RC=$?
}
field() { printf '%s\n' "$OUT" | grep -oE "^$1=.*" | head -n1 | cut -d= -f2-; }

# ---------------------------------------------------------------------------
CASE="syntax"
if bash -n "$LIB"; then ok "注入库语法"; else no "注入库语法"; fi
if bash -n "$VIDEO"; then ok "run-video-worker.sh 语法"; else no "run-video-worker.sh 语法"; fi
if bash -n "$WORKER"; then ok "run-worker.sh 语法"; else no "run-worker.sh 语法"; fi

# ---------------------------------------------------------------------------
CASE="unit_missing_file"
printf '\n[%s]\n' "$CASE"
new_home
unit_run
eq "rc" "$RC" "0"
eq "注入返回 0" "$(field inject_rc)" "0"
eq "子进程看不到假键" "$(field child_fake)" "unset"
eq "证据记录受信路径" "$(lines "$EVIDENCE" "path=$HOME/.harness/providers.env")" "1"
eq "证据记录 exists=0" "$(lines "$EVIDENCE" 'exists=0')" "1"
eq "证据记录 injected=0" "$(lines "$EVIDENCE" 'injected=0')" "1"
eq "证据里没有键名行" "$(lines "$EVIDENCE" 'key=MOZ29_FAKE_KEY:set')" "0"

# ---------------------------------------------------------------------------
CASE="unit_injects_existing_file"
printf '\n[%s]\n' "$CASE"
new_home
printf 'export MOZ29_FAKE_KEY=%s\n' "$FAKE_KEY" > "$HOME/.harness/providers.env"
chmod 640 "$HOME/.harness/providers.env"
unit_run
eq "rc" "$RC" "0"
eq "子进程看到假键" "$(field child_fake)" "$FAKE_KEY"
eq "证据记录 exists=1" "$(lines "$EVIDENCE" 'exists=1')" "1"
eq "证据记录权限" "$(lines "$EVIDENCE" 'mode=640')" "1"
eq "证据记录键名 set" "$(lines "$EVIDENCE" "key=MOZ29_FAKE_KEY:set")" "1"
eq "默认不改动 allexport" "$(field allexport)" "off"
eq "证据记录 allexport_after=0" "$(lines "$EVIDENCE" 'allexport_after=0')" "1"
is_true "证据不含假值明文" '! grep -qF "$FAKE_KEY" "$EVIDENCE"'

# ---------------------------------------------------------------------------
CASE="unit_source_failure"
printf '\n[%s]\n' "$CASE"
new_home
# 断行为：失败行里带一个专属于本用例的 canary，验证 source 的 stderr 没把文件内容回显到日志
printf 'MOZ29_FAKE_KEY=%s\nMOZ29_BROKEN="%s\n' "$FAKE_KEY" "$CANARY" > "$HOME/.harness/providers.env"
unit_run
is_true "注入返回非 0" '[[ "$(field inject_rc)" != "0" ]]'
is_true "驱动本身没被 source 失败带崩" '[[ "$RC" -eq 0 ]]'
eq "证据记录 injected=0" "$(lines "$EVIDENCE" 'injected=0')" "1"
is_true "输出不含损坏行内容" '! grep -qF "$CANARY" <<< "$OUT"'

# ---------------------------------------------------------------------------
CASE="unit_keeps_process_env"
printf '\n[%s]\n' "$CASE"
new_home
printf 'MOZ29_KEEP_KEY=from-file\nMOZ29_FAKE_KEY=%s\n' "$FAKE_KEY" > "$HOME/.harness/providers.env"
export MOZ29_KEEP_KEY=from-outer
unit_run
unset MOZ29_KEEP_KEY
eq "已在进程环境里的变量不被文件覆盖" "$(field child_keep)" "from-outer"
eq "文件里的新键照常注入" "$(field child_fake)" "$FAKE_KEY"
eq "证据记录 key:kept" "$(lines "$EVIDENCE" "key=MOZ29_KEEP_KEY:kept")" "1"
is_true "证据不记被保留变量的值" '! grep -qF from-outer "$EVIDENCE"'

# ---------------------------------------------------------------------------
CASE="unit_allexport_restore"
printf '\n[%s]\n' "$CASE"
new_home
printf 'MOZ29_FAKE_KEY=%s\n' "$FAKE_KEY" > "$HOME/.harness/providers.env"
export PRE_ALLEXPORT=1
unit_run
unset PRE_ALLEXPORT
eq "调用前已开 allexport，返回后仍开启" "$(field allexport)" "on"
eq "证据记录 allexport_before=1" "$(lines "$EVIDENCE" 'allexport_before=1')" "1"
eq "证据记录 allexport_after=1" "$(lines "$EVIDENCE" 'allexport_after=1')" "1"

# ---------------------------------------------------------------------------
# run-video-worker.sh 集成：假 HOME + 假 agy，验证注入发生在 agy 启动之前
new_video_fixture() {
  VROOT="$(mktemp -d "$TMPROOT/video.XXXXXX")"
  export HOME="$VROOT/home"
  mkdir -p "$HOME/.harness" "$VROOT/bin" "$VROOT/montage"
  export AGY_ENV_OUT="$VROOT/agy-env.txt"
  printf '#!/usr/bin/env bash\necho 0\n' > "$VROOT/bin/pgrep"
  printf '#!/usr/bin/env bash\necho "Mem:  32000  1000  20000  0  1000  20000"\n' > "$VROOT/bin/free"
  cat > "$VROOT/bin/agy" <<'AGY'
#!/usr/bin/env bash
[[ "${1:-}" == "--help" ]] && exit 0
printf 'env MOZ29_FAKE=%s MOZ29_KEEP=%s\n' "${MOZ29_FAKE_KEY:-unset}" "${MOZ29_KEEP_KEY:-unset}" >> "$AGY_ENV_OUT"
printf 'proxy NO_PROXY=%s no_proxy=%s\n' "${NO_PROXY:-unset}" "${no_proxy:-unset}" >> "$AGY_ENV_OUT"
AGY
  chmod +x "$VROOT/bin/pgrep" "$VROOT/bin/free" "$VROOT/bin/agy"
  export PATH="$VROOT/bin:$BASE_PATH"
  printf '视频任务书：留一条真证据。\n' > "$VROOT/prompt.md"
  VPROJECT="$VROOT/montage/projects/MOZ-30"
  VEVIDENCE="$VPROJECT/.task/evidence/providers-env.txt"
  unset MOZ29_FAKE_KEY MOZ29_KEEP_KEY NO_PROXY no_proxy
}
run_video() {
  OUT="$(bash "$VIDEO" --montage-dir "$VROOT/montage" --ticket MOZ-30 --category Test \
    --mode test --prompt-file "$VROOT/prompt.md" 2>&1)"
  RC=$?
}

# ---------------------------------------------------------------------------
CASE="video_missing_file"
printf '\n[%s]\n' "$CASE"
new_video_fixture
# 诱饵：只有 $HOME/.harness/providers.env 是受信路径，别处的同名文件不得注入
printf 'MOZ29_DECOY_KEY=decoy\n' > "$VROOT/montage/providers.env"
printf 'MOZ29_DECOY_KEY=decoy\n' > "$HOME/providers.env"
run_video
eq "rc" "$RC" "0"
eq "agy 照常启动" "$(lines "$AGY_ENV_OUT" 'env MOZ29_FAKE=unset MOZ29_KEEP=unset')" "1"
eq "证据记录 exists=0" "$(lines "$VEVIDENCE" 'exists=0')" "1"
eq "证据记录 injected=0" "$(lines "$VEVIDENCE" 'injected=0')" "1"
eq "非受信路径的同名文件未被 source" "$(lines "$VEVIDENCE" 'key=MOZ29_DECOY_KEY:set')" "0"

# ---------------------------------------------------------------------------
CASE="video_injects_existing_file"
printf '\n[%s]\n' "$CASE"
new_video_fixture
printf 'MOZ29_FAKE_KEY=%s\n' "$FAKE_KEY" > "$HOME/.harness/providers.env"
chmod 600 "$HOME/.harness/providers.env"
run_video
eq "rc" "$RC" "0"
eq "agy 子进程看到假键" "$(lines "$AGY_ENV_OUT" "env MOZ29_FAKE=$FAKE_KEY MOZ29_KEEP=unset")" "1"
eq "证据记录路径" "$(lines "$VEVIDENCE" "path=$HOME/.harness/providers.env")" "1"
eq "证据记录权限" "$(lines "$VEVIDENCE" 'mode=600')" "1"
eq "证据记录键名 set" "$(lines "$VEVIDENCE" "key=MOZ29_FAKE_KEY:set")" "1"
is_true "证据不含假值明文" '! grep -qF "$FAKE_KEY" "$VEVIDENCE"'
is_true "worker 输出不含假值明文" '! grep -qF "$FAKE_KEY" <<< "$OUT"'

# ---------------------------------------------------------------------------
CASE="video_source_failure"
printf '\n[%s]\n' "$CASE"
new_video_fixture
printf 'MOZ29_FAKE_KEY=%s\nif then\n' "$FAKE_KEY" > "$HOME/.harness/providers.env"
run_video
eq "source 失败一律退出 5" "$RC" "5"
match "输出写明注入失败" "$OUT" '\[FAIL\] 注入 .*providers\.env 失败'
absent "agy 未启动" "$AGY_ENV_OUT"
eq "证据记录 injected=0" "$(lines "$VEVIDENCE" 'injected=0')" "1"
is_true "输出不含假值明文" '! grep -qF "$FAKE_KEY" <<< "$OUT"'

# ---------------------------------------------------------------------------
CASE="video_keeps_process_env"
printf '\n[%s]\n' "$CASE"
new_video_fixture
printf 'MOZ29_KEEP_KEY=from-file\nMOZ29_FAKE_KEY=%s\n' "$FAKE_KEY" > "$HOME/.harness/providers.env"
export MOZ29_KEEP_KEY=from-outer
run_video
unset MOZ29_KEEP_KEY
eq "agy 看到外层已有值" "$(lines "$AGY_ENV_OUT" "env MOZ29_FAKE=$FAKE_KEY MOZ29_KEEP=from-outer")" "1"
eq "证据记录 key:kept" "$(lines "$VEVIDENCE" "key=MOZ29_KEEP_KEY:kept")" "1"

# ---------------------------------------------------------------------------
# MOZ-36：注入后合并 NO_PROXY / no_proxy，回环地址一定在，已有绕行主机不丢
CASE="video_no_proxy_loopback_added"
printf '\n[%s]\n' "$CASE"
new_video_fixture
printf 'MOZ29_FAKE_KEY=%s\n' "$FAKE_KEY" > "$HOME/.harness/providers.env"
run_video
eq "没有 NO_PROXY 时补上三个回环名（两个大小写变量同值）" \
  "$(lines "$AGY_ENV_OUT" 'proxy NO_PROXY=127.0.0.1,localhost,::1 no_proxy=127.0.0.1,localhost,::1')" "1"

CASE="video_no_proxy_keeps_existing"
printf '\n[%s]\n' "$CASE"
new_video_fixture
# 文件只设小写变量，外层环境只设大写变量：合并后两个变量都要拿到全部条目
printf 'no_proxy=.corp.example,10.0.0.0/8\n' > "$HOME/.harness/providers.env"
export NO_PROXY="api.corp.example"
run_video
unset NO_PROXY
eq "文件与环境的绕行主机都保留，回环追加在后" \
  "$(lines "$AGY_ENV_OUT" 'proxy NO_PROXY=api.corp.example,.corp.example,10.0.0.0/8,127.0.0.1,localhost,::1 no_proxy=api.corp.example,.corp.example,10.0.0.0/8,127.0.0.1,localhost,::1')" "1"
eq "证据不记 NO_PROXY 的值" "$(lines "$VEVIDENCE" '.corp.example')" "0"

# ---------------------------------------------------------------------------
# 静态顺序：注入语句必须出现在 pi/agy 启动行之前
CASE="static_inject_before_agent"
printf '\n[%s]\n' "$CASE"
line_of() { grep -nE "$2" "$1" 2>/dev/null | head -n1 | cut -d: -f1; }
for pair in "$WORKER|pi --session-dir|agy --disable-slash-commands" \
            "$VIDEO|AGY_FLAGS -p" ; do
  f="${pair%%|*}"; rest="${pair#*|}"
  inj="$(line_of "$f" 'inject_providers_env "\$')"
  [[ -n "$inj" ]] || { no "$(basename "$f"): 找不到注入调用"; continue; }
  IFS='|' read -r -a agents <<< "$rest"
  mrg="$(line_of "$f" '^merge_no_proxy_loopback$')"
  [[ -n "$mrg" ]] || { no "$(basename "$f"): 找不到 NO_PROXY 合并调用"; continue; }
  is_true "$(basename "$f"): 合并(line $mrg) 晚于注入(line $inj)" '[[ "$mrg" -gt "$inj" ]]'
  for a in "${agents[@]}"; do
    at="$(line_of "$f" "$a")"
    [[ -n "$at" ]] || { no "$(basename "$f"): 找不到启动行 [$a]"; continue; }
    is_true "$(basename "$f"): 注入(line $inj) 早于 [$a](line $at)" '[[ "$inj" -lt "$at" ]]'
    is_true "$(basename "$f"): 合并(line $mrg) 早于 [$a](line $at)" '[[ "$mrg" -lt "$at" ]]'
  done
done

# ---------------------------------------------------------------------------
printf '\n==== summary: %d passed, %d failed ====\n' "$PASSED" "$FAILED"
if [[ "$FAILED" -gt 0 ]]; then
  printf 'failed:\n'
  printf '  - %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi
