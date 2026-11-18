# 剧本 PB-04：每周垃圾回收、额度审计与仓库进化 (Weekly GC & Evolution)

> **适用场景**：每周日夜间或周一早间定时运行一次，平时完全休眠。

## 标准作业步骤 (Verbatim Todo Steps)

- [ ] **Step 1: Linear 免费版 250 条未归档工单护城河清理 (`Archive Old Done Issues`)**
  读取 `~/court/linear_config.json`，查询工部与行人司中处于 `Done` 或 `Canceled` 超过 3 天的工单并执行归档（Archive），确保未归档活跃工单始终低于 100 条。
- [ ] **Step 2: 检查各成员上下文水位与 `N世` 转世门禁 (`Check Token Thresholds`)**
  读取 `~/court/rolls.json`，检查各 Bot 累积对话是否超过 120K Tokens；若有超限且手头无 `In Progress` 工单者，调用 `~/strategy-stack/cloud/skills/reincarnation.md` 执行 N世 交接。
- [ ] **Step 3: 本地 Ubuntu 工作树与临时视频缓存清理 (`Clean Stale Worktrees & Temp Video`)**
  通过 Tailscale 检查本地 Ubuntu：
  1. 清理 `~/work/worktrees/` 下对应 Linear 已 `Done` 超过 7 天的遗留工作树，释放 SSD 空间：只清 `auto_merged == 1` 的工单；`auto_merged == 0`（冲突、推送拒绝、基线变化、脏树）一律保留现场。清理前必须先把 `.task/` 证据（审查报告、review-bundle、合推日志、测试日志）复制到 worktree 之外的 `~/task-archive/<工单号>/`，且**禁止 `git worktree remove --force`**。
  2. 清理 Google Drive `99_Temp_Test/` 下超过 7 天的临时测试视频（经本地 `rclone` 删除，不经由云端中转）。
  3. 清理本地 `MyMontage/jobs/` 下已完结工单的 `tmp/` 缓存，保留最终脚本与日志。
- [ ] **Step 4: 清理收尾 (`Quiet Termination`)**
  Step 1–5 均由韩非执行。Step 1–3 仅在归档了异常僵尸工单、发现超限成员（转交鬼谷交接）或清理了工作树/临时视频缓存时向 Sirus 发送简报；若无异常，安静结束回合。
- [ ] **Step 5: Strategy-Stack 仓库进化审计 (`Evolve Strategy-Stack`)**
  由韩非执行，独立于 Step 1–4 的结果：
  1. 扫描本周【墨翟 1世】与【张仪 1世】的卡壳记录与返工原因（Linear `Blocked` 工单、二败回滚、`--resume` 返工、Sirus 的纠正）。
  2. 若发现某条剧本步骤冗余或缺失边界检查，拟定针对 `~/strategy-stack` 的具体文件修改方案，附修改前后的 Diff 对比，以 `Needs me` 状态报给 Sirus；**获批后**才执行 `git commit` 与 `git push`。
  3. 核查 `cloud/playbooks/` 与 `local/skills/` 中是否有连续两周未被触发的冗余文件，提议归档删除，同样以 `Needs me` 报给 Sirus，获批后才动手。
  4. 无提案时安静结束回合。
