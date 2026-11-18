#!/usr/bin/env bash
set -euo pipefail

MONTAGE_DIR=""
TICKET_ID=""
CATEGORY="00_Uncategorized"
MODE="prod" # prod 或 test
PROMPT_FILE=""
RESUME_SESSION=""
GDRIVE_REMOTE="${GDRIVE_REMOTE:-gdrive:MyMontage_Studio}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --montage-dir) MONTAGE_DIR="$2"; shift 2 ;;
    --ticket) TICKET_ID="$2"; shift 2 ;;
    --category) CATEGORY="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --resume) RESUME_SESSION="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$MONTAGE_DIR" || -z "$TICKET_ID" || -z "$PROMPT_FILE" ]]; then
  echo "Usage: $0 --montage-dir <path> --ticket <MOZ-25> --category <Folder> --mode <prod|test> --prompt-file <path> [--resume <session_jsonl>]"
  exit 1
fi

# 0. 自动同步最新 strategy-stack 规则
git -C "$HOME/strategy-stack" pull --ff-only >/dev/null 2>&1 || true

# 1. 24G 内存与 2 并发硬门禁检查（与墨翟共享同一物理算力池）
# 锚定完整命令词，避免 brave/grok/pipewire/acpi/napi 等含 "pi" 的无关进程被计入
ACTIVE_JOBS=$(pgrep -fc '(^|/)(pi|agy|ffmpeg)( |$)' || true)
FREE_MEM=$(free -m | awk '/^Mem:/{print $7}')
if [[ "$ACTIVE_JOBS" -ge 2 ]] || [[ "$FREE_MEM" -lt 6000 ]]; then
  echo "[GATE_BLOCKED] active_jobs=$ACTIVE_JOBS, free_mem=${FREE_MEM}MB (<6000MB)"
  exit 2
fi

# 2. 创建独立任务沙箱目录（复用 MyMontage 主环境虚拟环境与插件，不重复拷贝大体积素材）
JOB_DIR="$MONTAGE_DIR/jobs/$TICKET_ID"
mkdir -p "$JOB_DIR/output" "$JOB_DIR/tmp" "$JOB_DIR/.task/sessions" "$JOB_DIR/.task/evidence"
cp "$PROMPT_FILE" "$JOB_DIR/.task/$TICKET_ID-prompt.md"

# 3. 启动 Pi 在 MyMontage 中执行剧本编写、TTS 与视频合成
cd "$MONTAGE_DIR"
EXEC_INSTRUCTION="你当前位于 MyMontage 根目录（$MONTAGE_DIR）。请严格在独立任务目录 $JOB_DIR 下组织本次视频创作的剧本、分镜与中间文件，并将最终合成的视频成片输出为 $JOB_DIR/output/final.mp4（若有字幕或封面请一并放入 $JOB_DIR/output/）。任务要求如下：
$(cat "$JOB_DIR/.task/$TICKET_ID-prompt.md")"

set +e
if [[ -n "$RESUME_SESSION" && -f "$RESUME_SESSION" ]]; then
  pi --session-dir "$JOB_DIR/.task/sessions" --session "$RESUME_SESSION" --mode json \
     -p "$EXEC_INSTRUCTION" > "$JOB_DIR/.task/$TICKET_ID.jsonl" 2>&1
else
  pi --session-dir "$JOB_DIR/.task/sessions" --mode json \
     -p "$EXEC_INSTRUCTION" > "$JOB_DIR/.task/$TICKET_ID.jsonl" 2>&1
fi
PI_EXIT=$?
set -e

SES_FILE=$(ls -t "$JOB_DIR/.task/sessions/"*.jsonl 2>/dev/null | head -n 1 || echo "")
FINAL_VIDEO="$JOB_DIR/output/final.mp4"
PROBE_OK=0
PROBE_SUMMARY="$JOB_DIR/.task/probe-summary.txt"
AUDIT_FILE="$JOB_DIR/.task/$TICKET_ID-audit.md"
AUDIT_VERDICT="SKIPPED"
GDRIVE_DEST="NOT_UPLOADED"
GDRIVE_LINK="NONE"

# 4. 视频硬指标检验 (ffprobe) 与三点抽帧取证 (15%, 50%, 85%)
if [[ "$PI_EXIT" -eq 0 && -f "$FINAL_VIDEO" ]]; then
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

  # 检查时长大于 1 秒且同时包含 video 和 audio 流
  if awk "BEGIN {exit !($DURATION > 1.0)}" && echo "$STREAMS" | grep -q "video" && echo "$STREAMS" | grep -q "audio"; then
    PROBE_OK=1
    T1=$(awk "BEGIN {printf \"%.2f\", $DURATION * 0.15}")
    T2=$(awk "BEGIN {printf \"%.2f\", $DURATION * 0.50}")
    T3=$(awk "BEGIN {printf \"%.2f\", $DURATION * 0.85}")
    ffmpeg -y -ss "$T1" -i "$FINAL_VIDEO" -frames:v 1 "$JOB_DIR/.task/evidence/frame_15pct.jpg" >/dev/null 2>&1 || true
    ffmpeg -y -ss "$T2" -i "$FINAL_VIDEO" -frames:v 1 "$JOB_DIR/.task/evidence/frame_50pct.jpg" >/dev/null 2>&1 || true
    ffmpeg -y -ss "$T3" -i "$FINAL_VIDEO" -frames:v 1 "$JOB_DIR/.task/evidence/frame_85pct.jpg" >/dev/null 2>&1 || true
  fi
fi

# 5. 本地 Gemini Pro (agy -p) 双轴审片（核查剧本、字幕与音画指标）
if [[ "$PROBE_OK" -eq 1 ]] && command -v agy >/dev/null 2>&1; then
  OUTPUT_FILES=$(ls -lh "$JOB_DIR/output/" 2>/dev/null || echo "")
  set +e
  agy -p "你是独立只读视频质量审查官。请对照视频任务要求，检查生成的剧本/字幕文件、输出目录清单及 ffprobe 音画参数。首行必须输出 VERDICT: PASS 或 VERDICT: FAIL，随后按 [Act On]、[Consider]、[Dismissed] 输出精简审片报告：
=== 任务要求 ===
$(cat "$JOB_DIR/.task/$TICKET_ID-prompt.md")
=== ffprobe 指标 ===
$(cat "$PROBE_SUMMARY")
=== 输出文件清单 ===
$OUTPUT_FILES" > "$AUDIT_FILE" 2>&1
  set -e

  if grep -q "VERDICT: PASS" "$AUDIT_FILE"; then
    AUDIT_VERDICT="PASS"
  else
    AUDIT_VERDICT="FAIL"
  fi
elif [[ "$PROBE_OK" -eq 1 ]]; then
  AUDIT_VERDICT="PASS"
fi

# 6. 自动分类上传至 Google Drive（正式归入对应领域文件夹，测试强制归入 99_Temp_Test）
if [[ "$PROBE_OK" -eq 1 && "$AUDIT_VERDICT" == "PASS" ]] && command -v rclone >/dev/null 2>&1; then
  DATE_PREFIX=$(date +%Y-%m-%d)
  if [[ "$MODE" == "test" ]]; then
    GDRIVE_DEST="$GDRIVE_REMOTE/99_Temp_Test/${DATE_PREFIX}_${TICKET_ID}"
  else
    GDRIVE_DEST="$GDRIVE_REMOTE/${CATEGORY}/${DATE_PREFIX}_${TICKET_ID}"
  fi

  if rclone copy "$JOB_DIR/output/" "$GDRIVE_DEST/" --include "*.mp4" --include "*.srt" --include "*.vtt" --include "*.jpg" --include "*.png" --include "*.md"; then
    GDRIVE_LINK=$(rclone link "$GDRIVE_DEST" 2>/dev/null || echo "$GDRIVE_DEST")
  else
    GDRIVE_DEST="UPLOAD_FAILED"
  fi
fi

# 7. 触发 Webhook 回调叫醒云端【公输 1世】
if [[ -f "$HOME/.harness/webhooks/gongshu.env" ]]; then
  set -a; . "$HOME/.harness/webhooks/gongshu.env"; set +a
  curl -s -X POST "$WEBHOOK_URL" \
    -H "Authorization: Bearer $WEBHOOK_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"ticket\": \"$TICKET_ID\", \"mode\": \"$MODE\", \"category\": \"$CATEGORY\", \"pi_exit\": $PI_EXIT, \"probe_ok\": $PROBE_OK, \"audit_verdict\": \"$AUDIT_VERDICT\", \"gdrive_dest\": \"$GDRIVE_DEST\", \"gdrive_link\": \"$GDRIVE_LINK\", \"job_dir\": \"$JOB_DIR\", \"session_file\": \"$SES_FILE\", \"audit_file\": \"$AUDIT_FILE\"}" >/dev/null 2>&1 || true
fi

echo "[DONE] ticket=$TICKET_ID mode=$MODE probe_ok=$PROBE_OK audit=$AUDIT_VERDICT gdrive=$GDRIVE_DEST"
