# Strategy Stack（云薄本厚双环工作流引擎）

本仓库为云端 Grok Bot 编排层与本地 Ubuntu 执行层（默认 `codex` CLI，`pi` / `agy` 仍为环境变量回退）的共享工程规范。

## `/strategy` 粘性模式触发铁律
当收到带有 `/strategy` 的指令，或岗位设定默认常驻 `/strategy` 模式时，立即进入**粘性策略模式（Sticky Strategy Mode）**，直至收到 `new task`：
1. **五要素先对齐**：开工前核齐 `Goal`（目标）、`Done Check`（可判定通过/失败标准）、`Proof`（截图/日志/Diff 证据路径）、`Known Info`（仓库路径与 Linear 工单号）、`Constraints`（硬约束）。可逆探索直接动手验证，核心设计歧义一次性浓缩提请澄清。
2. **剧本逐字拷贝防偷懒**：匹配对应剧本后，必须将标准步骤**一字不差地原样复制**到当前 Todo 列表；不适用步骤须保留原行并标注 `skip: [原因]`，严禁私自删减。
3. **二败强制回滚（Theory Rollback）**：同一假设的修改若验证失败，立即执行 `git checkout` 回滚探索性改动；连续 2 次在同一门禁失败，立即停手回滚并挂 `Blocked` 质疑前提，严禁打第 3 个补丁。
4. **真实表面取证（Prove It Works）**：编译通过或退出码为 0 不等于完成，必须留下截图、实测响应或音视频抽帧证据；结案须注明遵循了 `principles.md` 中的哪条原则。
5. **双绿灯自动合推（Auto-Merge on Double Green）**：实施退出码为 0（回调仍带兼容字段 `pi_exit`）且本地独立 `codex exec --sandbox read-only` 审查首行恰为 `VERDICT: PASS` 时，由 `local/scripts/run-worker.sh` 自动 `git merge --no-ff` 合入 base branch 并推送；代码工程合入的人工审批已取消，云端只在回调 `auto_merged == 1` 时标 `Done` 并在同一回合派发父 Spec 下下一个已解锁 `Queued` 子单。`REVIEW_CLI=pi` 或 `agy` 仍为显式回退。

## 剧本与技能路由表
- **云端外环（Grok Bot）**：
  - 需求澄清与 Linear 垂直切片拆单 → `cloud/playbooks/PB-01-spec-slice.md`
  - Tailscale 派单本地 Codex（默认）与双绿灯自动合推 → `cloud/playbooks/PB-02-dispatch-pi.md`
  - 按需 X 情报聚类与 1–12 字短语草稿 → `cloud/playbooks/PB-03-x-micro-intel.md`
  - 每周垃圾回收、Linear 旧单归档与仓库进化审计 → `cloud/playbooks/PB-04-weekly-gc.md`
  - OpenMontage 免侵入式视频创作与 Google Drive 归档（本地默认 `codex` 全权驱动，不走二次审查 / worktree 合入；`MONTAGE_CLI=pi|agy` 为回退） → `cloud/playbooks/PB-05-video-montage.md`
  - 120K Token 触发 `N世` 转世交接 → `cloud/skills/reincarnation.md`
  - 1–12 字中文短语与去 AI 味过滤 → `cloud/skills/unslop-cn.md`
- **本地内环（Ubuntu / 默认 Codex）**：
  - 垂直切片 TDD 实现 → `local/skills/implement-tdd.md`
  - 五步真实验证与二败回滚 → `local/skills/prove-it-works.md`
  - 本地独立只读审查（默认 `codex exec --sandbox read-only --ephemeral`；`REVIEW_CLI=pi|agy` 为回退） → `local/skills/local-cross-audit.md`
  - 本地默认 `codex` 驱动 OpenMontage、ffprobe 物理流校验与 rclone 直传 Google Drive → `local/scripts/run-video-worker.sh`

## 合推门禁（唯一标准）

> 本门禁只适用于代码工程（PB-02 / `local/scripts/run-worker.sh`）。视频创作走 PB-05 / `local/scripts/run-video-worker.sh`：由本地默认 `codex`（`MONTAGE_CLI`，`pi` / `agy` 为回退）驱动 OpenMontage 五层流水线，用内置质量门禁 + `ffprobe` 校验物理流，经 `rclone` 按领域或 `99_Temp_Test` 直传 Google Drive；**上传成功后工单直接标 `Done`**，不挂 `Needs Approval`，也不做 git 合入。

1. 实施退出码为 0（回调兼容字段仍为 `pi_exit`）：默认用 `codex exec --dangerously-bypass-approvals-and-sandbox --color never -C "$WORK_DIR" --json - < prompt.md` 从 stdin 读到 EOF 后正常退出（该 bypass 只绕过 Codex 自己的审批与沙箱，不能绕过宿主审批），且改动已提交到 `feat/<工单号>`（留下未提交改动直接判 FAIL）。`WORKER_CLI=pi|agy` 为回退。切勿写成 `... - < prompt.md < /dev/null`：后一个重定向会覆盖前者，把 prompt 丢弃。
2. `AUDIT_VERDICT == PASS`：全新进程用 `codex exec --sandbox read-only --ephemeral --color never -C "$WORKTREE_DIR" --output-last-message FILE --json - < .task/audit-prompt.txt` 从 stdin 读到 EOF。审查不得带 `--dangerously-bypass-approvals-and-sandbox`，不挂实现会话。prompt（硬性禁令）+ `.task/review-bundle.txt` 全文（任务书 + `.task/evidence/` 文本证据 + 文件清单 + 绑定已审 commit 的 `git diff`）都走 stdin 文件，绝不进 argv（单参数上限约 128KiB），报告首行必须恰为 `VERDICT: PASS`。`REVIEW_CLI=pi|agy` 为回退。
3. 两条同时成立才 `git merge --no-ff` 合入 `$BASE_BRANCH`，随后 `git push`（不 `--force`）。
4. `auto_merged == 1` 必须同时满足：merge 成功、push 成功、且已 `git fetch` + `git merge-base --is-ancestor` 核实远端分支包含该 merge commit。缺一即 `AUTO_MERGED=0`（并发锁、基线变化、脏仓库、冲突、推送拒绝都走这条路）。
5. 失败一律写证据到 `.task/<工单号>-merge.txt` 与 `.task/webhook-payload.json`，worktree 保留；脚本从不 `--force` 删除工作树，证据先归档到 `~/task-archive/<工单号>/`。
6. 回归测试 `local/scripts/tests/test-run-worker.sh` 只在临时仓库 + 临时 bare remote 中运行，禁止对真实 `origin/main` 做故障推送或重置。

## 红线（永不自动化）

代码工程合并的人工审批已取消，但以下动作必须保留人工卡口，任何剧本、脚本或 Bot 都不得自行执行：**X 发帖/回复/私信、任何付费与订阅、删除核心数据**、修改凭据/Webhook 密钥/平台安全控制、改动托管 skills 与 Routine。

## 仓库政策

本仓库只放规范与脚本。`~/court/` 整目录与 `/home/box/studio_rules.md` 一律不提交进本仓库；需要引用时只写「读取 `~/court/...`」这类运行时指令。
