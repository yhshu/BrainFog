# BrainFog 设计文档

> 一个原生 macOS 应用：看清、管理、迁移 AI 编程 agent（Claude Code / Codex / opencode）的分层记忆与上下文。

## 1. 要解决的问题

每个 agent 都有自己的一套"记忆"：人写的指令文件（CLAUDE.md / AGENTS.md）、agent 自己写的记忆（Claude auto memory、Codex memories）、规则、skills、MCP 连接器。它们按**全局 → 项目 → 目录**分层，且三家规则各不相同。现有工具（见 §7）都是"按 agent 列文件"的阅读器，回答不了真正的问题：

> **我在这个目录启动某个 agent 时，它到底看到了什么？顺序如何？占多少 token？哪里互相冲突？**

## 2. 核心差异化

| # | 能力 | 说明 |
|---|---|---|
| 1 | **Context Lens（生效上下文解析器）** | 选任意目录，按各 agent 的真实规则模拟加载：文件、顺序、启动时 vs 按需、token、截断、遮蔽关系（例如 CLAUDE.md 存在时 Claude 不读 AGENTS.md）。 |
| 2 | **分层浏览与编辑** | agent × 层级（managed / user / project / local / directory / auto memory / rules）矩阵，原地编辑，外部修改检测与冲突提示。 |
| 3 | **`.agentpack` 导入导出** | 记忆、指令、规则、skills、MCP 配置打包；导出时自动剔除密钥；导入前给出逐文件 diff 预览，按目标 agent 重新映射路径。 |
| 4 | **时间线与回滚** | 监听（FSEvents）agent 写入，自动做内容寻址快照；"昨天 Claude 往这个项目记了什么"，一键回滚。 |
| 5 | **健康检查**（贯穿以上） | MEMORY.md 超 200 行/25KB、Codex 超 32KiB、空文件、断掉的 `@import`、CLAUDE.local.md 意外遮蔽 AGENTS.md 等。 |

后续方向（MVP 之后）：单一源编译到多格式（CLAUDE.md ⇄ AGENTS.md ⇄ opencode instructions）、漂移检测、跨机器同步。

## 3. 各 agent 加载规则（解析器依据，2026-10 核对官方文档）

### Claude Code（默认 `claude-md-or-agents-md` 模式）
1. Managed：`/Library/Application Support/ClaudeCode/CLAUDE.md`（最先加载，不能被排除）。
2. User：`~/.claude/CLAUDE.md`、`~/.claude/rules/**/*.md`。
3. 祖先目录：从文件系统根到 cwd，每层 `CLAUDE.md`、`.claude/CLAUDE.md`，然后 `CLAUDE.local.md`（同层内 local 在后）。全部拼接，越近越靠后。
4. 若 cwd 及其祖先**没有任何** `CLAUDE.md` / `.claude/CLAUDE.md` / `CLAUDE.local.md`，则改读每层的 `AGENTS.md`、`.claude/AGENTS.md`（v2.1.277+）。user / managed / rules 不参与这个判断。
5. `.claude/rules/**/*.md`：无 `paths` frontmatter 的启动时加载；有 `paths` 的在读写匹配文件时按需加载。
6. 子目录的 CLAUDE.md：按需（Claude 读写该子目录文件时）。
7. `@path` 导入：相对于所在文件解析，最多 4 跳。
8. Auto memory：`~/.claude/projects/<git 根路径编码>/memory/MEMORY.md`，启动时只加载前 200 行或 25KB；topic 文件按需读。`autoMemoryDirectory` 可改位置，`autoMemoryEnabled` 可关闭。编码：路径中非 `[A-Za-z0-9-]` 字符替换为 `-`。
9. `claudeMdExcludes`：按绝对路径 glob 排除（managed 除外）。

### Codex
1. `CODEX_HOME`（默认 `~/.codex`）下 `AGENTS.override.md`，否则 `AGENTS.md`，取第一个非空的。
2. 项目根（通常是 git 根；找不到则只看 cwd）向下走到 cwd，每层依次查 `AGENTS.override.md`、`AGENTS.md`、`project_doc_fallback_filenames`，每层最多取一个。
3. 根在前、cwd 在后拼接；空文件跳过；总量达到 `project_doc_max_bytes`（默认 32 KiB）即停止。
4. Memories：生成态，存于 `~/.codex/memories/`；流水线中间数据在 `~/.codex/memories_1.sqlite`（`stage1_outputs` 每线程原始记忆）。**BrainFog 对该数据库只读**——它归 Codex 所有，官方也不建议手改。

### opencode
1. 从 cwd 向上找 `AGENTS.md`，同层没有则找 `CLAUDE.md`；第一个命中即为项目规则。
2. 全局：`~/.config/opencode/AGENTS.md`，不存在则回退 `~/.claude/CLAUDE.md`。
3. `OPENCODE_DISABLE_CLAUDE_CODE=1` 关闭所有 `.claude` 回退；`OPENCODE_DISABLE_CLAUDE_CODE_PROMPT=1` 仅关闭 `~/.claude/CLAUDE.md`。
4. `opencode.json(c)` 的 `instructions`：路径、glob、远程 URL，与 AGENTS.md 合并。
5. 官方文档未说明多层父目录是否都加载、合并顺序——解析器按"第一个命中"实现，并在 UI 中标注为推断。

## 4. 架构

```
BrainFog (SwiftUI app, macOS 26+)
 ├─ BrainFogCore (纯 Foundation，可测试，无 UI)
 │   ├─ Model        AgentID / Scope / ContextEntry / ResolvedContext / Diagnostic
 │   ├─ Resolvers    ClaudeCodeResolver / CodexResolver / OpenCodeResolver
 │   ├─ Support      导入解析、frontmatter、glob、token 估算、路径编码、JSONC
 │   ├─ Stores       CodexMemoryStore（SQLite 只读）           [MVP-1]
 │   ├─ Pack         .agentpack 读写、密钥剔除、diff            [MVP-2]
 │   └─ Timeline     FSEvents 监听、内容寻址快照、回滚           [MVP-3]
 └─ App              窗口、侧边栏、Context Lens、编辑器
```

原则：
- **解析器是纯函数**：输入（cwd、home、环境变量、文件系统）→ 输出 `ResolvedContext`，用临时目录做单元测试。
- **对 agent 数据最小侵入**：只写用户明确编辑的文件；写入前比对 mtime/内容，冲突时提示；所有写入先进时间线快照。
- **不确定的规则显式标注**，不假装精确。

## 5. 设计语言

- macOS 26 Liquid Glass：`glassEffect`、`GlassEffectContainer`、`.buttonStyle(.glass)`；内容区保持清晰，玻璃只用于浮层与控件层。
- 每个 agent 一个稳定的识别色，作用于玻璃 tint 与层级标签。
- 键盘优先：⌘S 保存、⌘R 重新扫描、⌘1/2/3 切换 agent。

## 6. 里程碑

| 阶段 | 内容 |
|---|---|
| MVP-0（当前） | 工程骨架、三家解析器 + 测试、Context Lens 与全局/项目浏览编辑的首版 UI |
| MVP-1 | Codex 记忆数据库只读浏览、Claude auto memory 结构化编辑（frontmatter 表单）、健康检查面板 |
| MVP-2 | `.agentpack` 格式、密钥剔除、导入 diff 预览；skills 与 MCP 连接器纳入 |
| MVP-3 | 时间线：FSEvents 监听、快照、回滚 |
| 之后 | 单源编译到多格式、漂移检测、更多 agent（Gemini CLI、Cursor 等） |

## 7. 竞品与参考（只作调研，不复用代码）

- nvwalj/ai-memory-reader（GPL-3.0）：跨 agent 阅读/编辑，无层级解析，不含 opencode。
- markes76/claude-code-gui：Claude Code 四层 CLAUDE.md 编辑，Electron，仅 CC。
- bonnguyenitc/claude-memory-app、macmade/Memories：仅 Claude Code 记忆。
- Ameer-Jamal/agent-memory、manuelschipper/mdmanager：跨工具共享/同步，CLI 为主。

## 8. 许可证

PolyForm Noncommercial 1.0.0：源码公开，允许非商业使用与修改，禁止商用。注意它不是 OSI 定义的"开源"许可证。
