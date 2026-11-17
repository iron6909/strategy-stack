# 剧本 PB-05：MyMontage 视频创作与 Google Drive 分类归档 (Video Montage & Drive Upload)

> **适用场景**：使用本地 Ubuntu `MyMontage` 创作正式领域视频或临时测试视频，并自动分类上传至 Google Drive。
> **核心铁律**：开工前必须将以下 Steps 1–4 **一字不差地原样复制**到你的执行 Todo 列表中逐项推进。

## 标准作业步骤 (Verbatim Todo Steps)

- [ ] **Step 1: 确认领域分类、正式/测试模式与 MyMontage 剧本参数 (`Align Video Spec & Category`)**
  1. 读取 `~/court/linear_config.json`，获取工部 `team_id`、`states` 及 `domain:video` 标签 UUID。
  2. 通过 Tailscale SSH 只读检查本地 Ubuntu `MyMontage` 仓库中的可用插件、模板与剧本规范。
  3. 与 Sirus 确认（若 Sirus 已指明则直接推进）：
     - **模式 (`--mode`)**：`prod`（正式片）或 `test`（临时/测试片，上传至 `99_Temp_Test`）；
     - **领域文件夹 (`--category`)**：如 `01_English_Drama`（当 `--mode test` 时自动忽略此项并强制归入 `99_Temp_Test`）；
     - **分镜与台词脚本**：在 Linear 工部创建工单（如 `MOZ-25`，打上 `domain:video` 标签，测试单额外打上 `env:test` 标签）。

- [ ] **Step 2: 写入本地任务书并唤醒 `run-video-worker.sh` (`Dispatch Local MyMontage Worker`)**
  1. 通过 Tailscale SSH 在本地 Ubuntu 生成 `/tmp/<工单号>-video-prompt.md`，写明需要在 `MyMontage/jobs/<工单号>/` 下生成的剧本 JSON/Markdown、调用的 `MyMontage` 命令/插件、目标输出路径 `jobs/<工单号>/output/final.mp4` 及配套字幕/封面文件。
  2. 后台调用本地确定性视频执行脚本并立即休眠：
     ```bash
     nohup ~/strategy-stack/local/scripts/run-video-worker.sh \
       --montage-dir "$MYMONTAGE_PATH" \
       --ticket "$TICKET_ID" \
       --category "$CATEGORY_FOLDER" \
       --mode "$RUN_MODE" \
       --prompt-file "/tmp/$TICKET_ID-video-prompt.md" > "/tmp/$TICKET_ID-video.log" 2>&1 &
     ```
  3. 将 Linear 工单状态更新为 `In Progress`，**立即结束当前回合休眠**，静候 Webhook 回调。

- [ ] **Step 3: 接收 Webhook 回调并核验音画指标与云盘路径 (`Verify ffprobe, Audit & Drive Path`)**
  被 Webhook 唤醒后，读取回调载荷中的 `pi_exit`、`probe_ok`、`audit_verdict` 与 `gdrive_dest`：
  - **若 `pi_exit == 0`、`probe_ok == 1` 且 `audit_verdict == PASS`**：
    读取本地 `.task/probe-summary.txt` 与 `.task/<工单号>-audit.md`，在 Linear 工单评论区贴出：
    1) **Google Drive 归档路径与分享链接**（标明是正式领域目录还是 `99_Temp_Test`）；
    2) **音画硬指标**（时长、分辨率、帧率、音频流状态）；
    3) **本地 Gemini Pro 审片结论**与抽帧证据路径。
    随后将 Linear 工单状态改为 **`Needs Approval`**，以 `Done` 状态报给 Sirus 审片。
  - **若渲染失败或验片未过（且返工未满 2 次）**：使用 `--resume "$session_file"` 唤醒本地 `pi` 定向修复字幕/音轨问题并重跑；满 2 次失败则挂 `Blocked` 上报 Sirus。

- [ ] **Step 4: 清理本地大型中间缓存 (`Cleanup Temp Media Chunks`)**
  Sirus 确认云盘成片无误后，通知本地清理 `MyMontage/jobs/<工单号>/tmp/` 下的未压缩音频切片与原始帧缓存，仅保留最终脚本与日志，保护 1TB SSD 空间。
