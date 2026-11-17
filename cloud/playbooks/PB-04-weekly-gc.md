# 剧本 PB-04：每周垃圾回收、额度审计与仓库进化 (Weekly GC & Evolution)

> **适用场景**：每周日夜间或周一早间定时运行一次，平时完全休眠。

## 标准作业步骤 (Verbatim Todo Steps)

- [ ] **Step 1: Linear 免费版 250 条未归档工单护城河清理 (`Archive Old Done Issues`)**
  读取 `~/court/linear_config.json`，查询工部与行人司中处于 `Done` 或 `Canceled` 超过 3 天的工单并执行归档（Archive），确保未归档活跃工单始终低于 100 条。
- [ ] **Step 2: 检查百官上下文水位与 `N世` 转世门禁 (`Check Token Thresholds`)**
  读取 `~/court/rolls.json`，检查在任 Bot 累积对话是否超过 120K Tokens；若有超限且手头无 `In Progress` 工单者，调用 `~/strategy-stack/cloud/skills/reincarnation.md` 执行袭爵转世。
- [ ] **Step 3: 本地 Ubuntu 工作树清理 (`Clean Stale Worktrees`)**
  通过 Tailscale 检查本地 Ubuntu `~/work/worktrees/` 下对应 Linear 已 `Done` 超过 7 天的遗留工作树并安全清理释放 SSD 空间。
- [ ] **Step 4: `strategy-stack` 仓库进化审计 (`Audit Strategy-Stack Diff`)**
  扫描本周【墨翟】与【张仪】的卡壳或返工记录。若发现剧本步骤冗余或缺失边界检查，拟定针对 `~/strategy-stack` 的修改 Diff，以 `Needs me` 状态呈主公批准后再执行 `git commit` 与 `git push`；提议归档连续两周未被触发的冗余文件。
- [ ] **Step 5: 静默收尾 (`Quiet Termination`)**
  仅在清理了异常僵尸工单、完成了 Bot 转世或有仓库进化提案时向主公发送简报；若无异常，安静结束回合。
