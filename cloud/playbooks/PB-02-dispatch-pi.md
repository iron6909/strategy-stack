# PB-02 工程派单与 PR 出货

1. 从 Linear 读取工程子单、目标项目和原生依赖。只派发已解锁的切片。建立 [v1 派单](../../contracts/dispatch.schema.json)，填 `kind: code`、稳定 `run_id`、`attempt`、五要素和项目标识。写 `options.issue_type: slice`、`options.unresolved_dependencies: []`。可选指定 `engine` 和 `model`。重试保留 run ID 并递增 attempt，记录 `options.hypothesis_id`。
2. 在已信任 Tailscale SSH 入口传入 JSON，运行 `local/scripts/dispatch-worker.sh accept <dispatch.json>`。记录接单回执和 attempt 后再将 Linear 标为 In Progress。后台运行 `dispatch-worker.sh run <run_id> <attempt>`，随后运行 `dispatch-worker.sh deliver <run_id> <attempt>`，然后休眠。若中断在接单后，可凭同一 run ID 继续。Worker 用目标仓隔离 worktree 和固定版原版 poteto-mode 出货。
3. Webhook 只唤醒 Routine。经 SSH 用 `dispatch-worker.sh status <run_id> <attempt>` 读取可信回执，使用当前 Linear 快照调用 `dispatch-worker.sh transition <event.json> <snapshot.json>`。快照含 `ticket`、`run_id`、`attempt`、`state` 和可选 `last_event_id`。同事件重复处理时先核对 Linear 中的事件标记；接收动作由一个协调器负责。
4. `merged` 才将代码单推进 Done，评论记录事件 ID、PR 链接、已审 SHA、合入 SHA 和实证。读回 Linear 后执行 `dispatch-worker.sh ack <run_id> <attempt> <event_id>`。随后查实际依赖，推进已全部解锁的后继切片。重复唤醒若已读回 Done 但尚未完成后继调度，按原派单 ID 继续对账。
5. `awaiting_review`、`merge_wait` 等待对应条件恢复后再次调用同一 run。启用低频对账兜底。提交或基线变化由受信操作者核对 PR 后执行 `refresh <run_id> <attempt> <head> --vendor <vendor>`，重新验证并清除旧审核和豁免。同型号不可用优先用下一合格席位。同假设同门禁两次失败则 Blocked。交接或暂停以本地回执为准。

独立只读终审默认跨厂。需要单票豁免时由已配置的人类操作者执行 `waive <run_id> <attempt> <head> --reason '<reason>'`。豁免只对当前 PR head 有效。

二败阻塞后，操作者先核实前提变化，再执行 `authorize-retry <run_id> <attempt> <new-hypothesis-id>`。下一次派单须使用同一 run、下一 attempt 和已批准的新假设 ID。
