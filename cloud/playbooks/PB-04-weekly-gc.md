# 剧本 PB-04：每周垃圾回收、额度审计与仓库进化 (Weekly GC & Evolution)

> **适用场景**：每周日夜间或周一早间定时运行一次，平时完全休眠。

## 标准作业步骤 (Verbatim Todo Steps)

- [ ] **Step 1: Linear 免费版 250 条未归档工单护城河清理 (`Archive Old Done Issues`)**
  读取 `~/court/linear_config.json`，查询工部与行人司中处于 `Done` 或 `Canceled` 超过 3 天的工单并执行归档（Archive），确保未归档活跃工单始终低于 100 条。
- [ ] **Step 2: 检查各成员上下文水位与 `N世` 转世门禁 (`Check Token Thresholds`)**
  读取 `~/court/rolls.json`，检查各 Bot 累积对话是否超过 120K Tokens；若有超限且手头无 `In Progress` 工单者，调用 `~/strategy-stack/cloud/skills/reincarnation.md` 执行 N世 交接。
- [ ] **Step 3: 本地 Ubuntu 工作树与临时视频缓存清理 (`Clean Stale Worktrees & Temp Video`)**
  通过 Tailscale 检查本地 Ubuntu：
  1. 从 Linear 的 Done 工单和回执识别 run/attempt。操作者执行 `dispatch-worker.sh gc <run_id> <attempt> --linear-done-at <ISO-8601>` 生成计划，核验远端可达、归档哈希、干净工作树与非活动状态。确认后加 `--apply`。失败现场及证据保留。
  2. 视频缓存与测试归档的保留规则由目标项目维护。涉及核心数据的删除需人工操作。
- [ ] **Step 4: 清理收尾 (`Quiet Termination`)**
  Step 1–5 均由韩非执行。Step 1–3 仅在归档了异常僵尸工单、发现超限成员（转交鬼谷交接）或清理了工作树/临时视频缓存时向 Sirus 发送简报；若无异常，安静结束回合。
- [ ] **Step 5: Strategy-Stack 仓库进化审计 (`Evolve Strategy-Stack`)**
  由韩非执行，独立于 Step 1–4 的结果：
  1. 扫描本周【墨翟 1世】与【张仪 1世】的卡壳记录与返工原因（Linear `Blocked` 工单、二败回滚、`--resume` 返工、Sirus 的纠正）。
  2. 若发现某条剧本步骤冗余或缺失边界检查，拟定针对 `~/strategy-stack` 的具体文件修改方案，附修改前后的 Diff 对比，以 `Needs me` 状态报给 Sirus；**获批后**才执行 `git commit` 与 `git push`。
  3. 对可复现的反例优先提出结构校验或测试。涉及技能路由变化时使用固定版本 pstack 的 `reflect`、`correct` 或 `eval`，用相同验收目标检查候选产物和实际读取的依据。删除活动少的规则前，说明替代入口与其验证结果。
  4. 无提案时安静结束回合。
