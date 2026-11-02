# BrainFog Design

A native macOS app that shows what each AI coding agent (Claude Code, Codex, Cursor, GitHub Copilot, Gemini CLI, OpenCode, Cline, Devin Desktop) actually loads into its context, and lets you edit, share and move those files safely.

## 1. Purpose

Every agent layers its own instruction files, rules, memory, skills and MCP servers (global → project → directory), each by different rules. BrainFog answers one question: **started in this folder, what does this agent read, in what order, at what token cost, and what is shadowed, cut off or ignored?** Everything else (editing, copying between agents, keeping one shared AGENTS.md or global file, health checks, history, `.agentpack` export) serves that view.

## 2. Principles

- **Resolvers are pure**: (cwd, home, environment, filesystem) → `ResolvedContext`, unit-tested in temporary folders. Rules that aren't documented are labelled as inferred.
- **Write little, show first**: BrainFog writes only what the user asks for. Every change is shown as a diff, checked against the file's current content, applied all or nothing, and kept in History. The one exception is switching an MCP server off, which only takes something away. Codex's memory database is read-only.
- **Nothing for agents that aren't installed**: they sort last, show as a single line, and syncing skips them.
- **Unsaved edits are never dropped silently**; a file deleted elsewhere stays open so it can be saved back.
- **Tests never touch the user's files**: `ResolverEnvironment` takes a temporary home, and `BRAINFOG_HOME` points the whole app at one.
- **Agent order**: installed agents first, then roughly by how widely each is used with instruction files (Claude Code, Codex, Cursor, Copilot, Gemini CLI, OpenCode, Cline, Devin).

## 3. Per-agent loading rules (checked against official docs, 2026-11)

### Claude Code (default `claude-md-or-agents-md` mode)
1. Managed: `/Library/Application Support/ClaudeCode/CLAUDE.md` (loaded first; cannot be excluded).
2. User: `~/.claude/CLAUDE.md`, `~/.claude/rules/**/*.md`.
3. Ancestor directories: from the filesystem root down to cwd, at each level `CLAUDE.md`, `.claude/CLAUDE.md`, then `CLAUDE.local.md` (within a level, local comes last). Everything is concatenated; closer files come later.
4. If cwd and its ancestors contain **no** `CLAUDE.md` / `.claude/CLAUDE.md` / `CLAUDE.local.md` at all, then `AGENTS.md` and `.claude/AGENTS.md` are read at each level instead (v2.1.277+). User / managed / rules do not take part in this check.
5. `.claude/rules/**/*.md`: files without `paths` frontmatter load at startup; files with `paths` load on demand when a matching file is read or written.
6. CLAUDE.md in subdirectories: on demand (when Claude reads or writes files in that subdirectory). A subdirectory's AGENTS.md loads the same way when that folder has no CLAUDE.md, `.claude/CLAUDE.md` or `CLAUDE.local.md`.
7. `@path` imports: resolved relative to the containing file, at most 4 hops.
8. Auto memory: `~/.claude/projects/<encoded git root path>/memory/MEMORY.md`; at startup only the first 200 lines or 25KB are loaded; topic files are read on demand. `autoMemoryDirectory` changes the location, and `autoMemoryEnabled` turns it off. Encoding: characters in the path other than `[A-Za-z0-9-]` are replaced with `-`.
9. `claudeMdExcludes`: excludes by absolute-path glob (except managed).
10. MCP servers in a project's `.mcp.json` need the user's approval. `enabledMcpjsonServers` and `disabledMcpjsonServers` in `.claude/settings.json` or `.claude/settings.local.json` record the answer; a server in neither list is asked about when a session starts, unless `enableAllProjectMcpServers` is true.

### Codex
1. Under `CODEX_HOME` (default `~/.codex`), `AGENTS.override.md`, otherwise `AGENTS.md`; the first non-empty one is used.
2. Walk from the project root (usually the git root; if none is found, only cwd is considered) down to cwd, checking `AGENTS.override.md`, `AGENTS.md`, then `project_doc_fallback_filenames` at each level. The first name that exists is the level's file; if it is empty the level contributes nothing.
3. Concatenated with the root first and cwd last; empty files are skipped; loading stops once the total reaches `project_doc_max_bytes` (default 32 KiB).
4. Memories: generated state, stored in `~/.codex/memories/`; intermediate pipeline data lives in `~/.codex/memories_1.sqlite` (`stage1_outputs` holds per-thread raw memories). **BrainFog treats this database as read-only**: it belongs to Codex, and the official docs advise against editing it by hand.

### OpenCode
From the docs and source (`session/instruction.ts`).
1. Project: try `AGENTS.md`, then `CLAUDE.md`, then the deprecated `CONTEXT.md`, each from cwd up to the git root. The first name found anywhere wins, and every copy of it loads, closest first, so a parent's AGENTS.md beats a closer CLAUDE.md.
2. Global: `~/.config/opencode/AGENTS.md`; if it does not exist, fall back to `~/.claude/CLAUDE.md`.
3. `OPENCODE_DISABLE_CLAUDE_CODE` turns off every `.claude` fallback (files and skills); `..._PROMPT` turns off CLAUDE.md, global and project; `..._SKILLS` turns off `.claude/skills`; `OPENCODE_DISABLE_PROJECT_CONFIG` turns off project rules.
4. `instructions` in `opencode.json(c)`: paths, globs, and remote URLs, merged with AGENTS.md.

### Cursor (closed source; from cursor.com/docs, 2026-10)
1. The workspace is the folder Cursor opened; there is no walk up to parent directories.
2. Project rules: `.cursor/rules/**/*.mdc` (plain `.md` there is ignored). Frontmatter decides loading: `alwaysApply: true` → every chat; `globs` → when a matching file is in context; only `description` → when the agent judges it relevant; none → only when @-mentioned.
3. `.cursor/rules` and `AGENTS.md` in subdirectories apply when working in that folder, combined with the root ones.
4. `AGENTS.md` at the root is always applied. The Cursor CLI also reads `CLAUDE.md` at the root; the editor does not document it.
5. `.cursorrules` (legacy) is still read but deprecated.
6. User Rules (Settings) and Team Rules (dashboard) are not files, so BrainFog can only mention them. Cursor's Memories feature was removed in 2.1, so there is no generated memory to show.
7. Skills: `.agents/skills`, `.cursor/skills`, plus `.claude/skills` and `.codex/skills`, at project and user level; Cursor's own skills ship in `~/.cursor/skills-cursor`.

### Gemini CLI (open source; from source at v0.67, 2026-10)
1. File names: `GEMINI.md`, plus any names in `context.fileName`, which are added in front of it rather than replacing it. Every name is checked at every location. `GEMINI_CLI_HOME` replaces home.
2. Global: `~/.gemini/<names>`. Private project memory: `~/.gemini/tmp/<slug>/memory/MEMORY.md`, falling back to `<names>` in that directory. The slug is for the folder Gemini started in (not the repo root): from `~/.gemini/projects.json`, or else that folder's name.
3. Project: walk up from cwd to the nearest `context.memoryBoundaryMarkers` folder (default `.git`). With no marker, only cwd is checked. Paths are sorted as strings.
4. No downward scan at launch. Files below cwd load just in time, when a tool reads or edits a path there.
5. `@path` imports, at most 5 levels deep, and they must stay inside the project root. Extensions add `contextFileName` from `gemini-extension.json`.
6. There is no `save_memory` tool any more; the agent edits these Markdown files directly. MCP: `mcpServers` in settings.json; remote servers use `url` plus `type`.

### GitHub Copilot (Copilot CLI and VS Code's Copilot harness)
1. User: `~/.copilot/copilot-instructions.md` and `~/.copilot/instructions/**/*.instructions.md` (`COPILOT_HOME`).
2. Standard locations: the repo root, cwd, and every folder between, plus folders of files the agent works on (lazy). At each, it checks `.github/copilot-instructions.md`, `AGENTS.md`, `CLAUDE.md`, `.claude/CLAUDE.md` and `GEMINI.md`, and concatenates them all.
3. `.github/instructions/**/*.instructions.md` at the root and cwd. `applyTo` globs decide when each applies (`**` means always). `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` adds more directories.
4. `@relative` references are followed in copilot-instructions.md, AGENTS.md and CLAUDE.md, but only inside the repo.
5. VS Code's Local harness differs. It follows the `chat.*` settings; nested AGENTS.md is off by default; it also reads `~/.claude/CLAUDE.md` and `.claude/rules`. Copilot Memory is stored on GitHub.
6. MCP: `~/.copilot/mcp-config.json`, then `.mcp.json` / `.github/mcp.json` in the project (key `mcpServers`, `type: local|http|sse`). VS Code also has `.vscode/mcp.json` (key `servers`).

### Devin Desktop (formerly Windsurf; Devin Local agent, from docs.devin.ai)
Windsurf was renamed Devin Desktop on 2026-06-02. Cascade can no longer start conversations, so only Devin Local is modelled.
1. Global: `~/.config/devin/AGENTS.md` (or `AGENT.md`), `~/.claude/CLAUDE.md`, `~/.devin/global_rules.md`, `~/.devin/rules/*.md`.
2. From the workspace root to cwd, these are always on: `AGENTS.md`, `AGENTS.local.md`, `AGENT.md`, `.windsurfrules`, `CLAUDE.md`. Also `.devin/global_rules.md` (wins over `.windsurf/global_rules.md`), plus `.devin/rules/*.md` and `.windsurf/rules/*.md`, whose `trigger` is `always_on|glob|model_decision|agent|manual` (`agent` is treated like `model_decision`).
3. Cursor rules (`.cursor/rules/*.md|mdc`) are read with Cursor's frontmatter. `read_config_from` in `~/.config/devin/config.json` or `.devin/config.json` turns the claude, cursor, windsurf and agents_standard imports off.
4. Subdirectory copies load lazily. No size limits are documented.
5. MCP: `~/.config/devin/mcp_config.json`, `.devin/mcp_config.json`, `.devin/mcp_config.local.json` (`mcpServers`; remote servers use `url` plus `transport`). Windsurf's `~/.codeium/windsurf/mcp_config.json` is imported.

### Cline (from source, 2026-10)
Cline ships two engines in one extension and picks one per user, which can't be told from disk. BrainFog models the SDK engine, which Cline CLI also uses, and notes where the older one differs.
1. Search order: `<root>/AGENTS.md`, `<root>/.clinerules` (a file, or a folder read non-recursively), `<root>/.cline/rules/`, `~/.agents/AGENTS.md`, `~/.cline/rules/`, `~/Cline/Rules`, `~/Documents/Cline/Rules`. Extensions are `.md`, `.markdown` and `.txt`.
2. Rule name is frontmatter `name` or the file name. A later rule with the same name replaces an earlier one. `disabled: true` or `enabled: false` turns a rule off. Rules are sorted by name.
3. `paths` is not evaluated by the SDK engine, so those rules are always on. The older engine honours `paths`, reads subfolders, and also reads `.cursorrules`, `.cursor/rules/*.mdc` and `.windsurfrules`.
4. Skills, winner first on a name clash: `~/.agents/skills`, `~/.cline/skills`, then at the workspace root only `.agents`, `.claude`, `.cline`, `.clinerules` skills folders.
5. MCP: `~/.cline/data/settings/cline_mcp_settings.json` (`CLINE_DATA_DIR`, `CLINE_MCP_SETTINGS_PATH`). The older engine uses VS Code globalStorage `saoudrizwan.claude-dev`. A remote server without a `type` is SSE.

## 4. Code layout

- `BrainFogCore` (Foundation only, tested): `Model`, one resolver per agent under `Resolvers/`, `Skills`, `MCP` (discovery and comment-preserving edits of JSON/JSONC/TOML), `Creating`, `Copying`, `Sharing` (AGENTS.md), `GlobalSync`, `Health`, `RuleFormat`, `History` (content-addressed versions, `ChangeSet`), `Pack`, `ProjectDiscovery`.
- `BrainFog` (SwiftUI, macOS 26+): sidebar, the lens with four modes (Instructions & Memory, Skills, MCP Servers, Timeline), editor, change preview; FSEvents watching.

## 5. Interface

Follows the macOS HIG: Liquid Glass only on system controls (toolbar, sidebar); content on plain grouped cards with concentric rows. Each agent has a stable colour, and uses its own installed app icon where there is one. Paths in a project are shown relative to it. Shortcuts: ⌘S save, ⌘R reload, Esc close the editor, ⇧⌘I / ⇧⌘E import and export a pack.

## 6. Next

- Signing, notarization and updates.
- Re-check each resolver against the agents' docs as they change (last full check: 2026-11). Known gaps from that check: Codex `project_root_markers` and untrusted projects; OpenCode's per-file nested AGENTS.md and `instructions` globbed from cwd up; Claude Code subfolder `.claude/rules`; Copilot `.mcp.json` in every folder up to the repo root; MCP servers Devin imports from other tools.
- Maybe: compiling one source into each agent's format; sync across machines.

## License

PolyForm Noncommercial 1.0.0 (source-available, not OSI open source).
