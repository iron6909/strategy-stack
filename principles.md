# 核心治事原则索引 (Core Principles)

1. **`Cloud-Thin, Local-Heavy`（云薄本厚）**：云端 Bot 只负责需求对齐、Linear 状态流转与 1–12 字短语起草；凡涉及读大文件、写代码、跑测试、音视频处理，一律下沉 Ubuntu 本地。
2. **`Tracer-Bullet Vertical Slices`（垂直切片）**：拆单必须纵向切穿（数据结构 + 核心逻辑 + 最小交互表现 + 验证测试），严禁按“先建全库、再写全接口”水平切分。
3. **`Laziness Protocol`（惰性精简协议）**：能删代码绝不加代码，采用能通过验证的最小改动交差，严禁过度抽象与死代码堆积。
4. **`Attack the Premise & Rollback`（二败回滚与质疑前提）**：共享同一假设的两次修改若连续在同一门禁失败，立即 `git checkout` 回滚并直接验证假设本身，禁止堆砌第三次尝试。
5. **`Prove It Works`（真实表面取证）**：必须在真实运行表面（UI 截图、接口实测日志、音视频抽帧）验证产物，严禁将“编译通过”当作“修复成功”。
6. **`Heterogeneous Local Audit`（异构本地自检）**：本地 `Pi`（OpenCode Go）写完代码后，由本地脚本直接拉起 `Gemini Pro` (`agy -p`) 做**纯文本**双轴只读审查（prompt 硬禁一切工具，首行只准 `VERDICT: PASS`/`VERDICT: FAIL`），不占用云端 Bot 席位。
7. **`Micro-Voice Anti-Slop`（极简中文洁癖）**：X 评论与短推默认锁死 1–12 个字符，禁用长破折号与公关套话。
8. **`Red Lines Stay Human`（红线不自动化）**：代码工程合推在双绿灯（`PI_EXIT=0` + 审查首行 `VERDICT: PASS`）后由本地脚本自动 `--no-ff` 合入并推送，人工审批已取消；但 X 发帖/回复/私信、任何付费与订阅、删除核心数据、改动凭据/平台安全控制/hosted skills 与 Routine，必须保留人工卡口。
