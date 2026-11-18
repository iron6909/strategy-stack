---
name: mymontage-non-intrusive
description: MyMontage（OpenMontage 派生仓）免侵入式二开宪章副本与物理门禁行为
---

# MyMontage 免侵入式二开宪章 (Zero-Intrusion Development Rules)

> 规范正文与 MyMontage 仓库里的 `custom/AGENTS.md` **完全一致**；本文件是 strategy-stack 侧的副本，
> 供云端剧本与本地 `run-worker.sh` 引用。正文有变化时，先改 `custom/AGENTS.md`，再同步这里。

本项目是 `OpenMontage` 的下游派生仓库。为确保随时执行 `git pull upstream main` 零冲突，所有 Agent（Pi / agy）在本仓库开发时必须遵守以下五条死律：

## 1. 上游原生文件 100% 只读铁律 (Zero Upstream Modification)
- **严禁直接修改或删除**任何 `OpenMontage` 上游已追踪的文件（包括但不限于根目录 `AGENTS.md`、`SKILL.md`、`Makefile`、`.gitignore`、`config.yaml`、`requirements.txt`、`tools/**` 及 `remotion-composer` 下的 `Root.tsx`、`tsconfig.json`）。
- 仓库与 `upstream/main` 的 Git 差异中，`custom/` 目录以外的文件变更数必须为 **0**。

## 2. 四大定制资产强制归口 `custom/` 命名空间
1. **工具 (Tools)**：自研 TTS、逐词时间戳对齐、视觉/音频处理工具一律放入 `custom/tools/<domain>/`。若需修复上游原生工具 Bug，优先在 `custom/tools/` 编写 Wrapper；若必须打补丁，须将 `.patch` 存入 `custom/patches/`，由 `custom/scripts/setup_local.sh` 在运行期自动 `git apply` 并执行 `git update-index --skip-worktree <上游文件>`，严禁将修改提交进 Git。
2. **插件 (Plugins)**：自研管线插件与外部 API 路由一律放入 `custom/plugins/<name>/`，通过 CLI 参数或环境变量挂载，严禁修改上游 `__init__.py` 或核心注册表。
3. **剧本 (Playbooks)**：英语微短剧等领域的分镜模板、叙事规则与系统提示词一律放入 `custom/playbooks/<genre>/`，严禁修改上游默认剧本模板。
4. **风格 (Styles)**：字幕动效、逐词高亮样式、配色与画幅预设一律放入 `custom/styles/<style_name>/`，通过配置参数注入渲染器，严禁硬编码侵入 `Root.tsx`。

## 3. 依赖、配置与命令入口外挂化
- 新增依赖写入 `custom/requirements.txt`，新增配置写入 `custom/config/`，新增快捷命令写入 `custom/Makefile`（使用 `make -f custom/Makefile <target>` 调用）。

## 4. 运行产物与验证证据零入库
- `.task/`、`out/`、`projects/` 仅通过本地 `.git/info/exclude` 忽略，**严禁将 `.task/evidence/` 下的任何日志或截图 `git add` 提交入库**。

## 安全注记（本仓补充，不属宪章正文）

- `git update-index --skip-worktree <上游文件>` 只是把改动藏在 index 里，**不保证零冲突**：上游改了同一文件时 `pull` 照样冲突，而且 `skip-worktree` 会让 `git status` 看不见改动。所以审查门禁一律以**提交树**为准，不认 `git status`、index 或 skip-worktree。
- 本地 `run-worker.sh` 的物理门禁（违规只 FAIL 并列出路径，不做任何自动 `git checkout`／回滚）：
  1. **启用条件**：捕获的 base 树、待合 tip 树、或工作树里出现 `custom/AGENTS.md` 任一为真就启用；pi 删掉文件、或用符号链接指向仓外/空目标都骗不过去（链接也算「存在」，且宪章必须是普通 blob）。
  2. **两点完整树比对**：待合 commit 分别对「本次捕获的 base tip」和「已核实的 OpenMontage `upstream/main`」比对完整树，`custom/` 以外的任何新增／修改／删除／重命名（源或目标任一侧越界）／类型变更一律 FAIL。只用三点 `A...B` 会漏掉 base 上已合入的历史越界改动，所以必须两点。
  3. **运行目录**：`.task/`、`out/`、`projects/`、`.pi/` 不得出现在待合树；若被 `git add -f` 入库，审查前先摘成干净 tip 再审，审查后改 index 不算数。
  4. **upstream 解析**：必须存在名为 `upstream`（或其它同 URL 别名）的 remote，且 `remote.<name>.url` 指向 `https://github.com/calesthio/OpenMontage.git`（含 ssh 等价形态），并已 fetch 出 `refs/remotes/<name>/main`。ref 或 diff 解析失败一律 fail-closed，不用 `|| true` 吞 git 错误。它比对的是**本地已 fetch 的** `upstream/main`：上游已前进而 base 未同步时，两点比对会（按设计）把上游侧差异当越界并拒合，所以派发前先 `git fetch upstream` 并确认 base 与 upstream 在 `custom/` 外差异为 0。
  5. **提示注入**：`custom/AGENTS.md` 存在时，pi 真正读取的 `.task/<工单号>-prompt.md` 首部是宪章全文 + `=== 本次具体工单任务 ===` 分隔行 + 原任务书；resume 重复派发不会叠第二层。审查 bundle 因此天然包含宪章。
  6. **合入前复查**：门禁在合入前用同一参数再跑一次；失败只拒合，已审 SHA 不变。
