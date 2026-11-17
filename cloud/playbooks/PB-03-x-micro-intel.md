# 剧本 PB-03：按需 X 情报侦察与 1–12 字中文短语草稿 (X Micro-Intel & Drafts)

> **适用场景**：仅在 Sirus 点名召唤时触发（无任何自动写推定时任务）。
> **核心铁律**：开工前必须将以下 Steps 1–4 **一字不差地原样复制**到你的执行 Todo 列表中逐项推进。

## 标准作业步骤 (Verbatim Todo Steps)

- [ ] **Step 1: 读取 Linear 配置、靶标库与工部近期战果 (`Read Config, Watchlist & Mozi Progress`)**
  1. 读取 `~/court/linear_config.json` 与 `~/court/intel/x-watchlist-and-voice.md`（若尚未聚类 Sirus 的关注列表，先读取 `Following` 归纳前三类靶标）。
  2. 查询 Linear 工部（`teams.mozi_eng.team_id`）近 48 小时进入 `Needs Approval` 或 `Done` 的工单，提取可公开分享的真实踩坑与指标。

- [ ] **Step 2: 抓取三类靶标高信噪比动态 (`Scan Top-3 Clusters`)**
  扫描前三类靶标博主近 24–48 小时的实操干货、踩坑复盘与新工具评测，过滤抽奖与情绪水帖，精选 3–5 条高价值动态（每条附原帖链接与 `[Fact / Inference / Speculation]` 标签）。若无高价值动态，立即安静结束回合。

- [ ] **Step 3: 按 1–12 字死线起草短推与评论 (`Draft 1-12 Char Micro-Voice`)**
  加载 `~/strategy-stack/cloud/skills/unslop-cn.md`：
  - 起草 1–2 条联动工部进展或日常心得的中文原创短推（默认严格 **1–12 个字符**，仅含硬核指标对比时放宽至不超过 35 字的 1–2 句短句）。
  - 针对筛选出的大 V 帖子，按【捧场 / 学习 / 借鉴 / 认同 / 补充】五种姿势起草 2–3 条评论草稿（默认严格 **1–12 个字符**）。

- [ ] **Step 4: 写入 Linear 行人司并挂起审批 (`Publish Draft to Linear & Pause`)**
  使用 `teams.zhangyi_social.team_id`、`labels["type:x-draft"]` 与状态 `states.zhangyi_social["Needs Approval"]` 在 Linear 行人司创建草稿工单交 Sirus 审批。
  **安全红线复核**：确认未调用任何 X 直接发布/回复接口后结束回合。
