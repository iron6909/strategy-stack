# 剧本 PB-05：OpenMontage 免侵入式视频创作与 Google Drive 归档

> **适用场景**：由【公输】调度本地 `agy` 全权操纵 `MyMontage (OpenMontage)` 流水线生产视频，并自动分类归档至 Google Drive。
> **核心铁律**：开工前必须将以下 Steps 1–4 **一字不差地原样复制**到你的执行 Todo 列表中逐项推进。

## 标准作业步骤 (Verbatim Todo Steps)

- [ ] **Step 1: 锁定产线、领域分类与免侵入式创作规格 (`Lock Pipeline, Category & Spec`)**
  1. 读取 `~/court/linear_config.json`，获取工部 `team_id`、`states` 及 `domain:video`（与 `env:test`）标签 UUID。
  2. 明确本次视频任务的四项输入参数（若 Sirus 已给清，无需停下追问，直接推进）：
     - **运行模式（`--mode`）**：`prod`（正式片，入对应领域文件夹）或 `test`（临时/测试片，强制入 `99_Temp_Test` 文件夹）；
     - **领域目录（`--category`）**：如 `01_English_Drama`、`02_Tech_Agent`、`03_Anime_Lore`；
     - **调用产线与自定义扩展**：指明使用 `MyMontage` 的哪条产线（`SKILL.md`）、哪个自定义剧本风格及 `tools/` 插件；
     - **主题与台词/分镜要求**：明确视频核心内容、时长与画幅（`9:16` 竖屏或 `16:9` 横屏）。
  3. 在 Linear 工部创建带 `domain:video` 标签的工单（如 `MOZ-30`），状态设为 `In Progress`。

- [ ] **Step 2: 下发 OpenMontage 创作指令书并唤醒本地 `agy` (`Dispatch agy on LECOO-MINI`)**
  1. 通过 Tailscale SSH 在本地 `LECOO-MINI` 生成 `/tmp/$TICKET_ID-montage-brief.md`，写明：
     - 本次视频的主题、剧本/台词要求、目标画幅与时长；
     - 要求 `agy` 遵循 `OpenMontage` 五层架构，在 `projects/$TICKET_ID/` 目录下执行免侵入式创作（调用 `tools/` 注册表工具与 `remotion-composer` 渲染，通过内置质量门禁），将最终成片输出至 `projects/$TICKET_ID/output/final.mp4`（配套字幕/封面一并放入 `output/`），**严禁修改任何框架源码文件**。
  2. 后台启动本地 `run-video-worker.sh` 并立即结束当前回合休眠：
     ```bash
     nohup ~/strategy-stack/local/scripts/run-video-worker.sh \
       --montage-dir "$MYMONTAGE_PATH" \
       --ticket "$TICKET_ID" \
       --category "$CATEGORY_FOLDER" \
       --mode "$RUN_MODE" \
       --prompt-file "/tmp/$TICKET_ID-montage-brief.md" > "/tmp/$TICKET_ID-video.log" 2>&1 &
     ```

- [ ] **Step 3: 接收 Webhook 回调并自动结案 (`Process Callback & Auto-Close`)**
  被 Webhook 唤醒后，读取载荷中的 `agy_exit`、`probe_ok`、`gdrive_dest` 与 `gdrive_link`：
  - **若 `agy_exit == 0`、`probe_ok == 1` 且 `gdrive_dest` 上传成功**：
    在 Linear 工单评论区贴出 **Google Drive 归档路径/链接**、`ffprobe` 音画参数摘要及 `OpenMontage` 产物清单，**直接将 Linear 工单状态更新为 `Done`**（无需挂 `Needs Approval`），向 Sirus 发送一句包含云盘链接的 `Done` 说明；若有下一张排队的视频工单，在同一回合立即自动派发。
  - **若渲染或门禁未过（且重试未满 2 次）**：读取错误日志摘要，修正指令后重新触发一次 `run-video-worker.sh`；连续 2 次失败则将 Linear 工单标为 `Blocked` 并上报 Sirus。

- [ ] **Step 4: 清理本地大体积中间渲染缓存 (`Clean Remotion & Audio Temp Cache`)**
  工单 `Done` 后，通过 Tailscale 清理 `projects/$TICKET_ID/` 下的临时渲染帧与未压缩音频缓存（保留最终脚本与日志备查），释放 SSD 空间。
