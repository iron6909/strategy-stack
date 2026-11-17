# Strategy Stack（云薄本厚双环工作流引擎）

本仓库为云端 Grok Bot 编排层与本地 Ubuntu `Pi Coding Agent` 执行层的共享工程规范。

## `/strategy` 粘性模式触发铁律
当收到带有 `/strategy` 的指令，或岗位设定默认常驻 `/strategy` 模式时，立即进入**粘性策略模式（Sticky Strategy Mode）**，直至收到 `new task`：
1. **五要素先对齐**：开工前核齐 `Goal`（目标）、`Done Check`（可判定通过/失败标准）、`Proof`（截图/日志/Diff 证据路径）、`Known Info`（仓库路径与 Linear 工单号）、`Constraints`（硬约束）。可逆探索直接动手验证，核心设计歧义一次性浓缩提请澄清。
2. **剧本逐字拷贝防偷懒**：匹配对应剧本后，必须将标准步骤**一字不差地原样复制**到当前 Todo 列表；不适用步骤须保留原行并标注 `skip: [原因]`，严禁私自删减。
3. **二败强制回滚（Theory Rollback）**：同一假设的修改若验证失败，立即执行 `git checkout` 回滚探索性改动；连续 2 次在同一门禁失败，立即停手回滚并挂 `Blocked` 质疑前提，严禁打第 3 个补丁。
4. **真实表面取证（Prove It Works）**：编译通过或退出码为 0 不等于完成，必须留下截图、实测响应或音视频抽帧证据；结案须注明遵循了 `principles.md` 中的哪条原则。

## 剧本与技能路由表
- **云端外环（Grok Bot）**：
  - 需求澄清与 Linear 垂直切片拆单 → `cloud/playbooks/PB-01-spec-slice.md`
  - Tailscale 派单本地 Pi 与结果呈报 → `cloud/playbooks/PB-02-dispatch-pi.md`
  - 按需 X 情报聚类与 1–12 字短语草稿 → `cloud/playbooks/PB-03-x-micro-intel.md`
  - 每周垃圾回收、Linear 旧单归档与仓库进化审计 → `cloud/playbooks/PB-04-weekly-gc.md`
  - 120K Token 触发 `N世` 转世交接 → `cloud/skills/reincarnation.md`
  - 1–12 字中文短语与去 AI 味过滤 → `cloud/skills/unslop-cn.md`
- **本地内环（Ubuntu Pi）**：
  - 垂直切片 TDD 实现 → `local/skills/implement-tdd.md`
  - 五步真实验证与二败回滚 → `local/skills/prove-it-works.md`
  - 本地 Gemini Pro (`agy -p`) 双轴只读审查 → `local/skills/local-cross-audit.md`
