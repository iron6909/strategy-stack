# Strategy Stack

Grok Bot 根据用户意图管理 Linear 及任务依赖，经 Tailscale 向本地派单。工程 Worker 从固定 gitlink 读取原版 pstack `poteto-mode`。目标仓维护领域规则、验证入口及生产管线。

## 路由

- 需求与垂直切片 → [PB-01](cloud/playbooks/PB-01-spec-slice.md)
- 工程派单、PR 与回调 → [PB-02](cloud/playbooks/PB-02-dispatch-pi.md)
- 中文情报草稿 → [PB-03](cloud/playbooks/PB-03-x-micro-intel.md)
- 回收与规则审计 → [PB-04](cloud/playbooks/PB-04-weekly-gc.md)
- 应用项目的内容生产 → [PB-05](cloud/playbooks/PB-05-video-montage.md)

## 版本与部署

发布提交携带 pstack gitlink。发布工作区执行 `git submodule update --init ref/pstack`，保留完整技能目录。Worker 核对发布提交及子模块工作树，运行中使用固定版本；升级通过 gitlink PR。运行结点安装 Git、GitHub CLI、Python 3.11+ 和各已启用助手。

从 [配置样例](local/strategy-worker.example.json) 生成部署侧 `~/.harness/strategy-worker.json`。样例中的模型标识需在实际助手核实。Pi 的 `muse-1.3` 同时需要核实 CLI 标识和实际厂商。已有可用的模型才启用。每个 launcher 接收原始 argv，保留 stdin，使用隔离环境运行。实施/生产只获得自身工作区和所需模型凭据；终审使用独立只读环境；验证使用可复核的项目入口。GitHub 合并权限、签发豁免的操作员入口和 Webhook Key 由可信执行层持有。Grok 的 SSH 能力仅开放派单、执行、读取结果与回执确认，运维命令由人操作。

[派单](contracts/dispatch.schema.json) 和 [结果](contracts/result.schema.json) 使用版本 1。接单需要有效五要素，工程单还需标明未完成依赖为空的切片。成功后发送 Webhook 唤醒，接收方通过可信 SSH 读取本地结果并按 PB-02 更新 Linear。HTTP 接受仅代表唤醒，Linear 读回完成后才确认事件。重投复用该 revision 的事件 ID。

## 模型和 PR 门禁

| 角色 | 助手与模型 |
|---|---|
| 工程 | Pi · `deepseek-v4.1-flash`、`muse-1.3`，其后可用的 agy |
| 内容 | agy · `Hydrogen`、`Carbon`、`Neon`；项目可经实测登记备选 |
| 终审 | Codex · `terra`、`sol`，其后可用、已隔离且满足跨厂的席位 |

人工指定助手与模型优先，指定组合不可用时回报原因。只指定助手则使用该助手的模型顺序。跨厂依据已配置并核验的实际模型厂商。独立只读审查须绑定 PR 当前 SHA。人工豁免绑定 PR 和 SHA，仅豁免厂商差异。测试、实证与其他门禁照常。

自动合并为项目配置项。启用前要求 GitHub 目标分支配置严格的必需状态检查，并验证 Worker 可读回分支保护。合并命令绑定已审 head。已合并状态、目标分支和实际合入提交均核实后才回调 Done。

## 本地回归

```bash
bash local/scripts/tests/test-providers-env.sh
bash local/scripts/tests/test-run-worker.sh
python3 -B -m unittest discover -s tests -v
```

新入口为 `local/scripts/dispatch-worker.sh`。先用隔离夹具和测试项目验证 Grok Routine/Linear 读回，再切换生产。切换前的旧托管调用仍由旧脚本服务，切换完成后同批退役旧直推与旧视频入口。

人工红线包括 X 发布/回复/私信、付费与订阅、核心数据删除和凭据、安全控制、托管技能与 Routine 的变更。运行时配置和凭据留在部署侧。
