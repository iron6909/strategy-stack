#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/providers-env.sh
. "$SCRIPT_DIR/lib/providers-env.sh"

MONTAGE_DIR=""
TICKET_ID=""
CATEGORY="01_English_Drama"
MODE="prod" # prod 或 test
PROMPT_FILE=""
GDRIVE_REMOTE="${GDRIVE_REMOTE:-gdrive:MyMontage_Studio}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --montage-dir) MONTAGE_DIR="$2"; shift 2 ;;
    --ticket) TICKET_ID="$2"; shift 2 ;;
    --category) CATEGORY="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$MONTAGE_DIR" || -z "$TICKET_ID" || -z "$PROMPT_FILE" ]]; then
  echo "Usage: $0 --montage-dir <path> --ticket <MOZ-30> --category <Folder> --mode <prod|test> --prompt-file <path>"
  exit 1
fi

# 0. 无感拉取最新 strategy-stack 规则
git -C "$HOME/strategy-stack" pull --ff-only >/dev/null 2>&1 || true

# 1. 24G 内存与 2 并发硬门禁检查
# 锚定完整命令词（MOZ-9）：避免 brave/grok/pipewire/acpi/napi 等含 "pi" 的无关进程被计入
ACTIVE_JOBS=$(pgrep -fc '(^|/)(pi|agy|ffmpeg|remotion)( |$)' || true)
FREE_MEM=$(free -m | awk '/^Mem:/{print $7}')
if [[ "$ACTIVE_JOBS" -ge 2 ]] || [[ "$FREE_MEM" -lt 6000 ]]; then
  echo "[GATE_BLOCKED] active_jobs=$ACTIVE_JOBS, free_mem=${FREE_MEM}MB (<6000MB)"
  exit 2
fi

# 2. 创建免侵入式创作项目沙箱（绝不创建 git worktree，绝不改动框架源码）
PROJECT_DIR="$MONTAGE_DIR/projects/$TICKET_ID"
mkdir -p "$PROJECT_DIR/output" "$PROJECT_DIR/tmp" "$PROJECT_DIR/.task/evidence"
cp "$PROMPT_FILE" "$PROJECT_DIR/.task/$TICKET_ID-brief.md"

# 2.5 受信本地凭据注入：只在 $HOME/.harness/providers.env 存在时 source，缺失即跳过。
# 必须在 agy 启动之前完成；source 失败一律硬失败，绝不 || true。
inject_providers_env "$PROJECT_DIR/.task/evidence/providers-env.txt" || {
  echo "[FAIL] 注入 $HOME/.harness/providers.env 失败（source 返回 $?）"
  exit 5
}

# 3. 启动 agy 全权操纵 OpenMontage 五层流水线（免批模式 + 闭合 Stdin 防止后台挂起）
cd "$MONTAGE_DIR"
AGY_DIRECTIVE="你是 OpenMontage (MyMontage) 自主视频创作引擎统帅。当前位于仓库根目录（$MONTAGE_DIR）。
请严格遵循 OpenMontage 五层架构（读取根目录 SKILL.md / AGENTS.md 入口契约、调用内置产线与 custom/ 扩展插件、使用 tools/ 注册表工具与 remotion-composer 渲染，并执行内置工程化质量门禁），全权完成本次视频创作任务。
【免侵入式创作铁律】
1. 严禁修改 MyMontage 任何现有框架源码或配置文件（保持 git status 干净）。
2. 所有分镜脚本、TTS 音频、字幕与中间资产必须存放在独立项目目录：$PROJECT_DIR/。
3. 最终合成通过内置质量门禁的视频成片必须输出至：$PROJECT_DIR/output/final.mp4（配套 .srt 字幕、封面图或分镜说明一并输出至 $PROJECT_DIR/output/）。

=== 本次视频创作任务书 ===
$(cat "$PROJECT_DIR/.task/$TICKET_ID-brief.md")"

# 自动探测 agy 支持的免批参数（如 --yolo）并闭合标准输入
AGY_FLAGS=""
if agy --help 2>&1 | grep -q -- "--yolo"; then
  AGY_FLAGS="--yolo"
elif agy --help 2>&1 | grep -q -- "--dangerously-skip-permissions"; then
  AGY_FLAGS="--dangerously-skip-permissions"
fi

set +e
agy $AGY_FLAGS -p "$AGY_DIRECTIVE" < /dev/null > "$PROJECT_DIR/.task/$TICKET_ID-agy.log" 2>&1
AGY_EXIT=$?
set -e

FINAL_VIDEO="$PROJECT_DIR/output/final.mp4"
PROBE_OK=0
PROBE_SUMMARY="$PROJECT_DIR/.task/probe-summary.txt"
GDRIVE_DEST="NOT_UPLOADED"
GDRIVE_LINK="NONE"

# 4. 物理流完备性校验 (ffprobe) 与关键帧留档（无需二次 Agent 审批）
if [[ "$AGY_EXIT" -eq 0 && -f "$FINAL_VIDEO" ]]; then
  DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$FINAL_VIDEO" 2>/dev/null || echo "0")
  STREAMS=$(ffprobe -v error -show_entries stream=codec_type,codec_name,width,height -of compact "$FINAL_VIDEO" 2>/dev/null || echo "")
  cat << PROB > "$PROBE_SUMMARY"
Ticket: $TICKET_ID
Mode: $MODE
Category: $CATEGORY
Duration_Sec: $DURATION
Streams:
$STREAMS
PROB

  if awk "BEGIN {exit !($DURATION > 1.0)}" && echo "$STREAMS" | grep -q "video" && echo "$STREAMS" | grep -q "audio"; then
    PROBE_OK=1
    T_MID=$(awk "BEGIN {printf \"%.2f\", $DURATION * 0.50}")
    ffmpeg -y -ss "$T_MID" -i "$FINAL_VIDEO" -frames:v 1 "$PROJECT_DIR/output/cover_preview.jpg" >/dev/null 2>&1 || true
  fi
fi

# 5. 自动分类直传 Google Drive（正式片按领域归档，测试片强制入 99_Temp_Test）
if [[ "$PROBE_OK" -eq 1 ]] && command -v rclone >/dev/null 2>&1; then
  DATE_PREFIX=$(date +%Y-%m-%d)
  if [[ "$MODE" == "test" ]]; then
    GDRIVE_DEST="$GDRIVE_REMOTE/99_Temp_Test/${DATE_PREFIX}_${TICKET_ID}"
  else
    GDRIVE_DEST="$GDRIVE_REMOTE/${CATEGORY}/${DATE_PREFIX}_${TICKET_ID}"
  fi

  if rclone copy "$PROJECT_DIR/output/" "$GDRIVE_DEST/" --include "*.mp4" --include "*.srt" --include "*.vtt" --include "*.jpg" --include "*.png" --include "*.json" --include "*.md"; then
    GDRIVE_LINK=$(rclone link "$GDRIVE_DEST" 2>/dev/null || echo "$GDRIVE_DEST")
  else
    GDRIVE_DEST="UPLOAD_FAILED"
  fi
fi

# 6. 清理未压缩中间缓存并触发 Webhook 回调叫醒【公输 1世】
rm -rf "$PROJECT_DIR/tmp" 2>/dev/null || true

if [[ -f "$HOME/.harness/webhooks/gongshu.env" ]]; then
  set -a; . "$HOME/.harness/webhooks/gongshu.env"; set +a
  curl -s -X POST "$WEBHOOK_URL" \
    -H "Authorization: Bearer $WEBHOOK_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"ticket\": \"$TICKET_ID\", \"mode\": \"$MODE\", \"category\": \"$CATEGORY\", \"agy_exit\": $AGY_EXIT, \"probe_ok\": $PROBE_OK, \"gdrive_dest\": \"$GDRIVE_DEST\", \"gdrive_link\": \"$GDRIVE_LINK\", \"project_dir\": \"$PROJECT_DIR\"}" >/dev/null 2>&1 || true
fi

echo "[DONE] ticket=$TICKET_ID mode=$MODE agy_exit=$AGY_EXIT probe_ok=$PROBE_OK gdrive=$GDRIVE_DEST"
