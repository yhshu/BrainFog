# BrainFog Design Document

> A native macOS app for seeing, managing, and migrating the layered memory and context of AI coding agents (Claude Code / Codex / OpenCode / Cursor).

## 1. The problem

Every agent has its own set of "memory": human-written instruction files (CLAUDE.md / AGENTS.md), memory the agent writes itself (Claude auto memory, Codex memories), rules, skills, and MCP connectors. These are layered **global → project → directory**, and the rules differ across all three agents. Existing tools (see §7) are all readers that "list files per agent"; they cannot answer the real question:

> **When I launch a given agent in this directory, what exactly does it see? In what order? How many tokens does it take? Where do things conflict?**

## 2. Core differentiators

| # | Capability | Description |
|---|---|---|
| 1 | **Context Lens (effective-context resolver)** | Pick any directory and simulate loading according to each agent's real rules: files, order, at startup vs. on demand, tokens, truncation, and shadowing (e.g. Claude does not read AGENTS.md when CLAUDE.md exists). |
| 2 | **Layered browsing and editing** | An agent × layer matrix (managed / user / project / local / directory / auto memory / rules), with in-place editing, detection of external modifications, and conflict warnings. |
| 3 | **`.agentpack` import/export** | Bundles memory, instructions, rules, skills, and MCP configuration; secrets are stripped automatically on export; before import, a per-file diff preview is shown and paths are remapped for the target agent. |
| 4 | **Timeline and rollback** | Watches (FSEvents) agent writes and takes content-addressed snapshots automatically; "what did Claude record about this project yesterday", with one-click rollback. |
| 5 | **Health checks** (across all of the above) | MEMORY.md over 200 lines/25KB, Codex over 32KiB, empty files, broken `@import`s, CLAUDE.local.md unintentionally shadowing AGENTS.md, and so on. |

Future directions (after MVP): compiling a single source to multiple formats (CLAUDE.md ⇄ AGENTS.md ⇄ OpenCode instructions), drift detection, cross-machine sync.

## 3. Per-agent loading rules (basis for the resolvers; checked against official docs, 2026-10)

### Claude Code (default `claude-md-or-agents-md` mode)
1. Managed: `/Library/Application Support/ClaudeCode/CLAUDE.md` (loaded first; cannot be excluded).
2. User: `~/.claude/CLAUDE.md`, `~/.claude/rules/**/*.md`.
3. Ancestor directories: from the filesystem root down to cwd, at each level `CLAUDE.md`, `.claude/CLAUDE.md`, then `CLAUDE.local.md` (within a level, local comes last). Everything is concatenated; closer files come later.
4. If cwd and its ancestors contain **no** `CLAUDE.md` / `.claude/CLAUDE.md` / `CLAUDE.local.md` at all, then `AGENTS.md` and `.claude/AGENTS.md` are read at each level instead (v2.1.277+). User / managed / rules do not take part in this check.
5. `.claude/rules/**/*.md`: files without `paths` frontmatter load at startup; files with `paths` load on demand when a matching file is read or written.
6. CLAUDE.md in subdirectories: on demand (when Claude reads or writes files in that subdirectory).
7. `@path` imports: resolved relative to the containing file, at most 4 hops.
8. Auto memory: `~/.claude/projects/<encoded git root path>/memory/MEMORY.md`; at startup only the first 200 lines or 25KB are loaded; topic files are read on demand. `autoMemoryDirectory` changes the location, and `autoMemoryEnabled` turns it off. Encoding: characters in the path other than `[A-Za-z0-9-]` are replaced with `-`.
9. `claudeMdExcludes`: excludes by absolute-path glob (except managed).

### Codex
1. Under `CODEX_HOME` (default `~/.codex`), `AGENTS.override.md`, otherwise `AGENTS.md`; the first non-empty one is used.
2. Walk from the project root (usually the git root; if none is found, only cwd is considered) down to cwd, checking `AGENTS.override.md`, `AGENTS.md`, then `project_doc_fallback_filenames` at each level, taking at most one file per level.
3. Concatenated with the root first and cwd last; empty files are skipped; loading stops once the total reaches `project_doc_max_bytes` (default 32 KiB).
4. Memories: generated state, stored in `~/.codex/memories/`; intermediate pipeline data lives in `~/.codex/memories_1.sqlite` (`stage1_outputs` holds per-thread raw memories). **BrainFog treats this database as read-only**: it belongs to Codex, and the official docs advise against editing it by hand.

### OpenCode
1. Search upward from cwd for `AGENTS.md`; if a level has none, look for `CLAUDE.md`; the first match is the project rules.
2. Global: `~/.config/opencode/AGENTS.md`; if it does not exist, fall back to `~/.claude/CLAUDE.md`.
3. `OPENCODE_DISABLE_CLAUDE_CODE=1` disables all `.claude` fallbacks; `OPENCODE_DISABLE_CLAUDE_CODE_PROMPT=1` disables only `~/.claude/CLAUDE.md`.
4. `instructions` in `opencode.json(c)`: paths, globs, and remote URLs, merged with AGENTS.md.
5. The official docs do not say whether multiple parent directory levels are all loaded, or in what merge order. The resolver implements "first match" and marks this as inferred in the UI.

### Cursor (closed source; from cursor.com/docs, 2026-10)
1. The workspace is the folder Cursor opened; there is no walk up to parent directories.
2. Project rules: `.cursor/rules/**/*.mdc` (plain `.md` there is ignored). Frontmatter decides loading: `alwaysApply: true` → every chat; `globs` → when a matching file is in context; only `description` → when the agent judges it relevant; none → only when @-mentioned.
3. `.cursor/rules` and `AGENTS.md` in subdirectories apply when working in that folder, combined with the root ones.
4. `AGENTS.md` at the root is always applied. The Cursor CLI also reads `CLAUDE.md` at the root; the editor does not document it.
5. `.cursorrules` (legacy) is still read but deprecated.
6. User Rules (Settings) and Team Rules (dashboard) are not files, so BrainFog can only mention them. Cursor's Memories feature was removed in 2.1, so there is no generated memory to show.
7. Skills: `.agents/skills`, `.cursor/skills`, plus `.claude/skills` and `.codex/skills`, at project and user level; Cursor's own skills ship in `~/.cursor/skills-cursor`.

## 4. Architecture

```
BrainFog (SwiftUI app, macOS 26+)
 ├─ BrainFogCore (pure Foundation, testable, no UI)
 │   ├─ Model        AgentID / Scope / ContextEntry / ResolvedContext / Diagnostic
 │   ├─ Resolvers    ClaudeCodeResolver / CodexResolver / OpenCodeResolver / CursorResolver
 │   ├─ Support      import parsing, frontmatter, glob, token estimation, path encoding, JSONC
 │   ├─ Stores       CodexMemoryStore (SQLite, read-only)          [MVP-1]
 │   ├─ Pack         .agentpack read/write, secret stripping, diff  [MVP-2]
 │   └─ Timeline     FSEvents watching, content-addressed snapshots, rollback  [MVP-3]
 └─ App              windows, sidebar, Context Lens, editor
```

Principles:
- **Resolvers are pure functions**: input (cwd, home, environment variables, filesystem) → output `ResolvedContext`; unit-tested with temporary directories.
- **Minimal intrusion into agent data**: only write files the user explicitly edits; compare mtime/content before writing and warn on conflict; every write is snapshotted to the timeline first.
- **Uncertain rules are explicitly labeled**; no pretending to be exact.

## 5. Design language

- macOS 26 Liquid Glass: `glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)`; the content area stays clear, and glass is used only for overlays and the controls layer.
- Each agent has a stable identifying color, applied to glass tint and layer labels.
- Keyboard first: ⌘S save, ⌘R rescan, ⌘1/2/3 switch agent.

## 6. Milestones

| Phase | Scope |
|---|---|
| MVP-0 (current) | Project skeleton, resolvers for all three agents + tests, first UI for Context Lens and global/project browsing and editing |
| MVP-1 | Read-only browsing of the Codex memory database, structured editing of Claude auto memory (frontmatter form), health check panel |
| MVP-2 | `.agentpack` format, secret stripping, import diff preview; skills and MCP connectors included |
| MVP-3 | Timeline: FSEvents watching, snapshots, rollback |
| Later | Single-source compilation to multiple formats, drift detection, more agents (Gemini CLI, etc.) |

## 7. Competitors and references (research only; no code reused)

- nvwalj/ai-memory-reader (GPL-3.0): cross-agent reading/editing, no layer resolution, no OpenCode.
- markes76/claude-code-gui: edits Claude Code's four CLAUDE.md layers, Electron, Claude Code only.
- bonnguyenitc/claude-memory-app, macmade/Memories: Claude Code memory only.
- Ameer-Jamal/agent-memory, manuelschipper/mdmanager: cross-tool sharing/sync, mainly CLI.

## 8. License

PolyForm Noncommercial 1.0.0: source-available, permits noncommercial use and modification, prohibits commercial use. Note that it is not an "open source" license as defined by the OSI.
