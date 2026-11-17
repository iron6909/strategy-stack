---
name: implement-tdd
description: 垂直切片 TDD 实现技能（移植自 Matt Pocock /implement）
---

# 垂直切片 TDD 实现规程
1. 先读取当前项目根目录 `AGENTS.md` 与 `docs/agents/GLOSSARY.md`，严格遵守已有命名与类型边界。
2. 遵循 `Laziness Protocol`：采用能满足验收标准的最小代码改动，严禁顺手重构无关文件或引入多余抽象层。
3. 先针对接口契约或核心业务行为编写失败测试（Red），再编写最小实现使其通过（Green），最后清理冗余注释（Refactor）。
