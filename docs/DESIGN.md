# BrainFog Design

A native macOS app that answers: **started in this folder, what does each AI coding agent read, in what order, at what token cost, and what is shadowed, cut off or ignored?** Editing, copying between agents, shared AGENTS.md, global sync, health checks, history and `.agentpack` export all serve that view.

## Principles

- **Resolvers are pure**: (cwd, home, environment, filesystem) → `ResolvedContext`, tested in temporary folders. Undocumented rules are labelled as inferred.
- **Show before writing**: every change is a diff, checked against the file's current text, applied all or nothing, and kept in History. Only switching an MCP server off skips the preview. Codex's memory database is read-only.
- **Launch-time files only**: files in subfolders load once an agent works there, so BrainFog doesn't walk the project for them. The subfolder rules below describe the agents, not what BrainFog lists.
- **Uninstalled agents** sort last, show as one line, and are skipped by sync.
- **Unsaved edits are never dropped**; a file deleted elsewhere stays open so it can be saved back.
- **Tests never touch real files**: `ResolverEnvironment` takes a temporary home; `BRAINFOG_HOME` points the whole app at one.
- **Agent order**: installed first, then Claude Code, Codex, Cursor, Copilot, Gemini, OpenCode, Cline, Devin.

## Loading rules

Desktop and IDE clients read the same files as each CLI unless noted.

### Claude Code
1. Managed `/Library/Application Support/ClaudeCode/CLAUDE.md` first; can't be excluded.
2. User `~/.claude/CLAUDE.md`, `~/.claude/rules/**/*.md`.
3. From `/` down to cwd, at each level `CLAUDE.md`, `.claude/CLAUDE.md`, `CLAUDE.local.md`; closer files come later.
4. If no level has any of those, `AGENTS.md` and `.claude/AGENTS.md` are read instead. User, managed and rules files don't count.
5. `.claude/rules/**/*.md` without `paths` load at launch; with `paths`, on demand.
6. Subdirectory CLAUDE.md (or AGENTS.md when it has none) and `<subdir>/.claude/skills` load on demand.
7. `@path` imports, relative to the file, at most 4 hops.
8. Auto memory `~/.claude/projects/<git root, non-[A-Za-z0-9-] → ->/memory/MEMORY.md`: first 200 lines or 25 KB at launch. `autoMemoryDirectory`, `autoMemoryEnabled`.
9. `claudeMdExcludes` (absolute-path globs, not managed) merge across user, project, local and managed settings (`managed-settings.json`, then `managed-settings.d/*.json`).
10. `.mcp.json` servers need approval: `enabledMcpjsonServers` / `disabledMcpjsonServers` in `.claude/settings(.local).json`, or `enableAllProjectMcpServers`.
11. `pluginConfigs["cc-plugin-agents-md@builtin"].options.instructionFiles` (or `agents-md@builtin`), user and managed settings only: `claude-md-or-agents-md` (default, rule 4), `claude-md-and-agents-md` (CLAUDE first per folder), `claude-md`, `managed-only` (managed CLAUDE.md and auto memory at launch).
12. A CLAUDE.md over 4 MiB is skipped. The desktop app also reads `~/Library/Application Support/Claude/claude_desktop_config.json` for MCP.

### Codex
1. `CODEX_HOME` (default `~/.codex`): first non-empty of `AGENTS.override.md`, `AGENTS.md`.
2. From the project root (nearest `project_root_markers` folder, default `.git`; none → cwd only) down to cwd: first existing of `AGENTS.override.md`, `AGENTS.md`, `project_doc_fallback_filenames`. Empty files contribute nothing.
3. Root first; stops at `project_doc_max_bytes` (32 KiB).
4. `projects."<path>".trust_level = "untrusted"` (cwd's, else the git root's) loads no project AGENTS.md. Each `.codex/config.toml` from root to cwd applies only when trusted (its folder, else project root, else git root), closest winning, and can't set `project_root_markers`.
5. Skills: `.agents/skills` from cwd up to the root, `~/.agents/skills`, `/etc/codex/skills`; `[[skills.config]] enabled = false` turns one off. `memories.use_memories = false` hides memories.
6. Memories in `~/.codex/memories/` and `memories_1.sqlite` (read-only).

### OpenCode
1. Project: the first of `AGENTS.md`, `CLAUDE.md`, `CONTEXT.md` found anywhere from cwd up to the git root; every copy of that name loads, closest first.
2. Global `~/.config/opencode/AGENTS.md`, else `~/.claude/CLAUDE.md`.
3. `OPENCODE_DISABLE_CLAUDE_CODE` (all `.claude` fallbacks), `…_PROMPT` (CLAUDE.md), `…_SKILLS` (`.claude/skills`), `OPENCODE_DISABLE_PROJECT_CONFIG` (project config).
4. `instructions` (paths, globs, URLs): absolute entries glob their last component; relative ones are globbed in every folder from cwd up to the git root (only `~/.config/opencode` without project config).
5. Config order, later winning: global, `OPENCODE_CONFIG`, project files root → cwd, `.opencode/`, `OPENCODE_CONFIG_DIR`, managed `/Library/Application Support/opencode/`. `instructions` and MCP come from all.

### Cursor
1. Workspace only; no walk up.
2. `.cursor/rules/**/*.mdc`: `alwaysApply` → always; `globs` → matching files; only `description` → agent decides; none → @-mention.
3. Subfolder `.cursor/rules` and `AGENTS.md` apply in that folder.
4. Root `AGENTS.md` always; the CLI also reads root `CLAUDE.md`. `.cursorrules` is legacy but read.
5. User and Team Rules aren't files.
6. Skills: `.agents`, `.cursor`, `.claude`, `.codex` skills folders at project and user level, searched recursively; `~/.cursor/skills-cursor` is built in.

### Gemini (Gemini CLI and Antigravity share `~/.gemini`)
Gemini CLI:
1. Names: `context.fileName` entries, then `GEMINI.md`, all checked everywhere. `GEMINI_CLI_HOME` replaces home.
2. Global `~/.gemini/<names>`. Project memory `~/.gemini/tmp/<slug>/memory/MEMORY.md` (else `<names>` there); slug from `~/.gemini/projects.json`, else the start folder's name.
3. Walk up from cwd to the nearest `context.memoryBoundaryMarkers` (default `.git`); none → cwd only.
4. Files below cwd load when a tool touches them.
5. `@path` imports, 5 levels, inside the project root. Extensions add `contextFileName`.
6. MCP `mcpServers` in settings.json (`url` + `type`), filtered by `mcp.allowed` / `mcp.excluded`; `~/.gemini/mcp-server-enablement.json` records `{"<name>": {"enabled": false}}`.

Antigravity:
7. Always on: `~/.gemini/{GEMINI,AGENTS}.md`, `~/.gemini/config/{AGENTS,GEMINI}.md`; from workspace up to repo root, `AGENTS.md`, `GEMINI.md`, `.agents/AGENTS.md`, `.agents/GEMINI.md`.
8. Rules `~/.gemini/config/rules/*.md`, `.agents/rules/*.md` (or `.agent/rules`): `trigger` is `always_on|model_decision|glob|manual`, none → dropped; 24,000 bytes each.
9. MCP `~/.gemini/config/mcp_config.json`, `.agents/mcp_config.json` (`serverUrl` or `url`; `disabled`), legacy `~/.gemini/antigravity/mcp_config.json`.
10. Skills `.agents/skills` up to the repo root (or `.agent/skills`), `~/.gemini/config/skills`, `~/.gemini/skills`, `~/.gemini/antigravity-cli/skills`, `~/.gemini/antigravity/skills`.

### GitHub Copilot
1. User `~/.copilot/copilot-instructions.md`, `~/.copilot/instructions/**/*.instructions.md` (`COPILOT_HOME`).
2. Repo root through cwd (plus worked-on folders, lazily): `.github/copilot-instructions.md`, `AGENTS.md`, `CLAUDE.md`, `.claude/CLAUDE.md`, `GEMINI.md`, all concatenated.
3. `.github/instructions/**/*.instructions.md` at root and cwd; `applyTo` (`**` = always). `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` adds folders.
4. `@relative` references inside the repo.
5. VS Code's harness follows `chat.*` settings, has nested AGENTS.md off, and also reads `~/.claude/CLAUDE.md` and `.claude/rules`.
6. CLI MCP: `.mcp.json`, `.github/mcp.json` from cwd up to the repo root (closer wins; inferred), then `~/.copilot/mcp-config.json`. VS Code: `.vscode/mcp.json` and user `mcp.json` (`servers`).

### Devin (Devin Desktop and Devin CLI; Devin Local agent only)
1. Global `~/.config/devin/AGENTS.md` (or `AGENT.md`), `~/.claude/CLAUDE.md`, `~/.devin/global_rules.md`, `~/.devin/rules/*.md`.
2. Workspace root at start, deeper folders lazily: `AGENTS.md`, `AGENTS.local.md`, `AGENT.md`, `.windsurfrules`, `CLAUDE.md`; `.devin/global_rules.md` (over `.windsurf/`); `.devin/rules/*.md`, `.windsurf/rules/*.md` with `trigger` `always_on|glob|model_decision|agent|manual`.
3. `.cursor/rules/*.md|mdc` with Cursor frontmatter. `read_config_from` (`~/.config/devin/config.json`, `.devin/config.json`) turns off the claude, cursor, windsurf and agents_standard imports.
4. MCP `~/.config/devin/mcp_config.json`, `.devin/mcp_config(.local).json` (`url` + `transport`), plus read-only imports behind `read_config_from`: windsurf `~/.codeium/windsurf/mcp_config.json`; claude `.mcp.json`, `.claude/settings(.local).json`, `~/.claude.json`, `~/.claude/settings(.local).json`, `~/.claude/mcp_servers.json`; cursor `.cursor/mcp.json`; opencode `opencode.json`, `~/.config/opencode/opencode.json`.

### Cline (SDK engine, also used by Cline CLI)
1. Order: `<root>/AGENTS.md`, `<root>/.clinerules` (file, or folder non-recursively), `<root>/.cline/rules/`, `~/.agents/AGENTS.md`, `~/.cline/rules/`, `~/Cline/Rules`, `~/Documents/Cline/Rules`; `.md`, `.markdown`, `.txt`.
2. Name is frontmatter `name` or the file name; a later same-named rule replaces an earlier one; `disabled: true` / `enabled: false` turns one off; sorted by name.
3. `paths` is ignored. The older engine honours it, reads subfolders, `.cursorrules`, `.cursor/rules/*.mdc` and `.windsurfrules`.
4. Skills, first wins: `~/.agents/skills`, `~/.cline/skills`, then root `.agents`, `.claude`, `.cline`, `.clinerules` skills folders.
5. MCP `~/.cline/data/settings/cline_mcp_settings.json` (`CLINE_DATA_DIR`, `CLINE_MCP_SETTINGS_PATH`); older engine in VS Code globalStorage `saoudrizwan.claude-dev`. No `type` → SSE.

## Code

- `BrainFogCore` (Foundation only): `Model`, `Resolvers/` (one per agent), `Skills`, `MCP` (discovery, JSONC/TOML edits that keep comments), `Creating`, `Copying`, `Sharing`, `GlobalSync`, `Health`, `RuleFormat`, `History`, `Pack`, `ProjectDiscovery`.
- `BrainFog` (SwiftUI, macOS 26): sidebar, lens (Instructions & Memory, Skills, MCP Servers, Timeline), editor, change preview, FSEvents.
- `brainfog-cli`: prints the resolved context for a folder.

## Interface

macOS HIG: Liquid Glass only on system controls; content on grouped cards. Stable agent colours, installed app icons, project-relative paths. ⌘S save, ⌘R reload, Esc close editor, ⇧⌘I / ⇧⌘E import / export pack, ⇧⌘G show global items on project pages.

## Next

- Signing, notarization, updates.
- Keep resolvers in step with the agents' docs.

## License

PolyForm Noncommercial 1.0.0 (source-available).
