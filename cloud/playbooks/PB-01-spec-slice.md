# 剧本 PB-01：需求立仪与 Linear 垂直切片拆单 (Spec & Tracer-Bullet Tickets)

> **适用场景**：Sirus 提出新项目、新功能构想或重大重构，尚未形成可执行子工单时。
> **核心铁律**：开工前必须将以下 Steps 1–5 **一字不差地原样复制**到你的执行 Todo 列表中逐项推进。

## 标准作业步骤 (Verbatim Todo Steps)

- [ ] **Step 1: 读取 Linear 配置并摸底现存架构 (`Read Linear Config & Codebase`)**
  1. 读取 `~/court/linear_config.json`，获取工部 `teams.mozi_eng.team_id`、`states.mozi_eng` 及 `labels` UUID。
  2. 通过 Tailscale SSH 只读检查目标项目根目录的 `AGENTS.md` 与 `docs/agents/GLOSSARY.md`（若尚无则初始化创建），定位相关模块路径。
  3. **MyMontage 派生仓**：目标仓是 OpenMontage 派生仓（存在 `custom/AGENTS.md`）时，先读 `custom/AGENTS.md` 免侵入宪章，上游原生文件一律只读。

- [ ] **Step 2: 决策树追问与边界澄清 (`Grill on Ambiguities`)**
  盘点设计树上的关键分支（数据流向、边界异常、交互状态）。若存在影响架构走向的歧义，一次性浓缩为不超过 3–5 个高价值选择题请 Sirus 决定；可逆的技术细节直接按 `Laziness Protocol` 拟定最简方案。

- [ ] **Step 3: 创建 Linear 父级设计规范 (`Publish Parent Spec Issue`)**
  Sirus 决定后，在 Linear 工部创建父级 Issue，标题格式为 `[Spec] <功能名称>`。
  **防踩踏红线**：父级 Spec Issue **只能挂载 `labels["type:spec"]`，严禁当作单步施工单直接派发给本地脚本**！同步更新项目 `GLOSSARY.md`。

- [ ] **Step 4: 拆解曳光弹垂直切片 (`Slice into Tracer-Bullet Sub-Issues`)**
  将父 Spec 拆分为若干 Linear 子工单（`parentId` 指向父 Spec），严格遵守垂直切片三原则：
  1. **纵向贯穿**：每个子工单必须切穿真实可运行的一薄层（Schema + 逻辑 + 最小 UI/CLI + 测试）。
  2. **单窗容量**：改动规模必须能在一个全新的本地工程会话窗口内一次跑通。
  3. **显式阻塞边**：使用 Linear 原生 `Blocked by` 关系连接先后依赖。
  4. **PR 交付**：每个子单通过 PB-02 的 PR 流程交付，按目标仓验证地图提供证据。父 Spec 由 Sirus 终验。
  5. **应用规则**：从目标仓已发布版本读取应用规则、工作范围与验证入口。MyMontage 的宪章及允许路径由 MyMontage 维护。

- [ ] **Step 5: 写入五要素标准并激活首波工单 (`Attach 5-Element Criteria & Queue`)**
  在每个子工单正文中写清 `Goal`、`Done Check`、`Proof`、`Known Info`、`Constraints`。将无前置阻塞的首波子工单状态设为 `states.mozi_eng["Queued"]`，有前置依赖的设为 `states.mozi_eng["Blocked"]`，在父 Spec 下汇总拆单拓扑报给 Sirus。每个子单在 Worker 创建的分支上提交并开 PR，PR 合入并核实后云端在同一回合解锁并派发下一个 `Queued` 子单。

## 仓库政策

本仓库只放规范与脚本。`~/court/` 整目录与 `/home/box/studio_rules.md` 一律不提交进本仓库；需要引用时只写「读取 `~/court/...`」这类运行时指令。
