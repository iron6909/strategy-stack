# Strategy Stack（云薄本厚双环工作流引擎）

本仓库为云端 Grok Bot 编排层与本地 Ubuntu `Pi Coding Agent` 执行层的共享工程规范。

## `/strategy` 粘性模式触发铁律
当收到带有 `/strategy` 的指令，或岗位设定默认常驻 `/strategy` 模式时，立即进入**粘性策略模式（Sticky Strategy Mode）**，直至收到 `new task`：
1. **五要素先对齐**：开工前核齐 `Goal`（目标）、`Done Check`（可判定通过/失败标准）、`Proof`（截图/日志/Diff 证据路径）、`Known Info`（仓库路径与 Linear 工单号）、`Constraints`（硬约束）。可逆探索直接动手验证，核心设计歧义一次性浓缩提请澄清。
2. **剧本逐字拷贝防偷懒**：匹配对应剧本后，必须将标准步骤**一字不差地原样复制**到当前 Todo 列表；不适用步骤须保留原行并标注 `skip: [原因]`，严禁私自删减。
3. **二败强制回滚（Theory Rollback）**：同一假设的修改若验证失败，立即执行 `git checkout` 回滚探索性改动；连续 2 次在同一门禁失败，立即停手回滚并挂 `Blocked` 质疑前提，严禁打第 3 个补丁。
4. **真实表面取证（Prove It Works）**：编译通过或退出码为 0 不等于完成，必须留下截图、实测响应或音视频抽帧证据；结案须注明遵循了 `principles.md` 中的哪条原则。
5. **双绿灯自动合推（Auto-Merge on Double Green）**：`pi_exit == 0` 且本地 `agy` 纯文本审查首行恰为 `VERDICT: PASS` 时，由 `local/scripts/run-worker.sh` 自动 `git merge --no-ff` 合入 base branch 并推送；代码工程合入的人工审批已取消，云端只在回调 `auto_merged == 1` 时标 `Done` 并在同一回合派发父 Spec 下下一个已解锁 `Queued` 子单。

## 剧本与技能路由表
- **云端外环（Grok Bot）**：
  - 需求澄清与 Linear 垂直切片拆单 → `cloud/playbooks/PB-01-spec-slice.md`
  - Tailscale 派单本地 Pi 与双绿灯自动合推 → `cloud/playbooks/PB-02-dispatch-pi.md`
  - 按需 X 情报聚类与 1–12 字短语草稿 → `cloud/playbooks/PB-03-x-micro-intel.md`
  - 每周垃圾回收、Linear 旧单归档与仓库进化审计 → `cloud/playbooks/PB-04-weekly-gc.md`
  - MyMontage 视频创作与 Google Drive 分类归档 → `cloud/playbooks/PB-05-video-montage.md`
  - 120K Token 触发 `N世` 转世交接 → `cloud/skills/reincarnation.md`
  - 1–12 字中文短语与去 AI 味过滤 → `cloud/skills/unslop-cn.md`
- **本地内环（Ubuntu Pi）**：
  - 垂直切片 TDD 实现 → `local/skills/implement-tdd.md`
  - 五步真实验证与二败回滚 → `local/skills/prove-it-works.md`
  - 本地 Gemini Pro (`agy -p`) 双轴只读审查 → `local/skills/local-cross-audit.md`
  - 本地 MyMontage 视频调度、验片与 rclone 直传 Google Drive → `local/scripts/run-video-worker.sh`

## 合推门禁（唯一标准）

1. `PI_EXIT == 0`：实施用 `pi --mode json ... < /dev/null` 正常退出，且改动已提交到 `feat/<工单号>`（留下未提交改动直接判 FAIL）。
2. `AUDIT_VERDICT == PASS`：审查用 `agy --disable-slash-commands --dangerously-skip-permissions --print-timeout 15m -p ... < /dev/null`，prompt 首句硬禁 bash/shell/文件工具，只喂 `.task/review-bundle.txt` 纯文本（任务书 + `.task/evidence/` 文本证据 + 文件清单 + 绑定已审 commit 的 `git diff`），报告首行必须恰为 `VERDICT: PASS`。
3. 两条同时成立才 `git merge --no-ff` 合入 `$BASE_BRANCH`，随后 `git push`（不 `--force`）。
4. `auto_merged == 1` 必须同时满足：merge 成功、push 成功、且已 `git fetch` + `git merge-base --is-ancestor` 核实远端分支包含该 merge commit。缺一即 `AUTO_MERGED=0`（并发锁、基线变化、脏仓库、冲突、推送拒绝都走这条路）。
5. 失败一律写证据到 `.task/<工单号>-merge.txt` 与 `.task/webhook-payload.json`，worktree 保留；脚本从不 `--force` 删除工作树，证据先归档到 `~/task-archive/<工单号>/`。
6. 回归测试 `local/scripts/tests/test-run-worker.sh` 只在临时仓库 + 临时 bare remote 中运行，禁止对真实 `origin/main` 做故障推送或重置。

## 红线（永不自动化）

代码工程合并的人工审批已取消，但以下动作必须保留人工卡口，任何剧本、脚本或 Bot 都不得自行执行：**X 发帖/回复/私信、任何付费与订阅、删除核心数据**、修改凭据/Webhook 密钥/平台安全控制、改动托管 skills 与 Routine。

## 仓库政策

本仓库只放规范与脚本。`~/court/` 整目录与 `/home/box/studio_rules.md` 一律不提交进本仓库；需要引用时只写「读取 `~/court/...`」这类运行时指令。
