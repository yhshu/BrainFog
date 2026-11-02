import Foundation

/// One skill folder (`<name>/SKILL.md`) an agent can see.
public struct Skill: Identifiable, Sendable, Hashable {
    public var id: String { agent.rawValue + url.path }
    public var agent: AgentID
    public var name: String
    public var description: String
    /// The SKILL.md file.
    public var url: URL
    public var scope: Scope
    /// `.launch` when the name and description are listed at session start.
    public var timing: LoadTiming
    /// Tokens the name and description add to the starting context.
    public var tokens: Int
    public var note: String?

    public var folder: URL { url.deletingLastPathComponent() }

    /// The skill as a file entry, for the editor.
    public var entry: ContextEntry {
        ContextEntry(agent: agent, url: url, scope: scope, timing: timing,
                     tokens: tokens, note: note)
    }
}

/// Finds the skills each agent lists at session start. Sources:
/// Claude Code https://code.claude.com/docs/en/skills,
/// Codex https://learn.chatgpt.com/docs/build-skills,
/// OpenCode https://opencode.ai/docs/skills/,
/// Cursor https://cursor.com/docs/context/skills,
/// Gemini CLI https://geminicli.com/docs/cli/skills/,
/// Antigravity https://antigravity.google/docs/skills,
/// Copilot https://code.visualstudio.com/docs/copilot/customization/agent-skills.
public enum SkillResolver {
    /// - Parameter workingDirectory: the project folder, or nil for the
    ///   global layer only.
    public static func resolve(agent: AgentID, workingDirectory: URL?,
                               environment env: ResolverEnvironment = .init()) -> [Skill] {
        // Project folders from the repository root (or the folder itself) down.
        var projectDirs: [URL] = []
        let codexHome = env.codexHome
        let codexConfig = agent == .codex ? workingDirectory.map { CodexConfig(codexHome: codexHome, cwd: $0) } : nil
        if let cwd = workingDirectory?.standardizedFileURL {
            // Codex finds the root by its project_root_markers.
            let root = codexConfig.map { $0.hasRoot(above: cwd) ? $0.root(of: cwd) : cwd } ?? FileSupport.gitRoot(of: cwd)
            projectDirs = root.map { r in FileSupport.ancestors(of: cwd).filter { FileSupport.isWithin($0, r) } } ?? [cwd]
            projectDirs.removeAll { $0.path == env.home.path }
        }
        let copilotHome = env.copilotHome
        let configHome = env.variables["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? env.home.appendingPathComponent(".config")

        var found: [Skill] = []
        func scan(_ dir: URL, _ scope: Scope, note: String? = nil, recursive: Bool = false) {
            for skill in skills(in: dir, agent: agent, scope: scope, note: note, recursive: recursive)
            where !found.contains(where: { $0.url.path == skill.url.path }) {
                found.append(skill)
            }
        }
        switch agent {
        case .claudeCode:
            // Enterprise > personal > project when names collide.
            scan(env.claudeManagedDirectory.appendingPathComponent(".claude/skills"), .managed)
            scan(env.home.appendingPathComponent(".claude/skills"), .user)
            scan(env.home.appendingPathComponent(".claude/skills/synced"), .user, note: "synced from claude.ai")
            for dir in projectDirs { scan(dir.appendingPathComponent(".claude/skills"), .project) }
            var seen = Set<String>()
            for i in found.indices {
                if seen.contains(found[i].name) {
                    found[i].timing = .skipped("a higher-priority skill has the same name")
                }
                seen.insert(found[i].name)
            }
        case .codex:
            for dir in projectDirs.reversed() { scan(dir.appendingPathComponent(".agents/skills"), .project) }
            scan(env.home.appendingPathComponent(".agents/skills"), .user)
            scan(codexHome.appendingPathComponent("skills"), .user, note: "older location, still read")
            scan(URL(fileURLWithPath: "/etc/codex/skills"), .managed)
            scan(codexHome.appendingPathComponent("skills/.system"), .bundled, note: "ships with Codex")
            // Same-named skills are both offered; [[skills.config]] turns one off.
            let config = codexConfig ?? CodexConfig(file: codexHome.appendingPathComponent("config.toml"))
            for i in found.indices where config.skillDisabled(name: found[i].name, file: found[i].url) {
                found[i].timing = .skipped("turned off by [[skills.config]] in config.toml")
            }
        case .openCode:
            let claudeSkills = !env.flag("OPENCODE_DISABLE_CLAUDE_CODE") && !env.flag("OPENCODE_DISABLE_CLAUDE_CODE_SKILLS")
            for dir in projectDirs.reversed() {
                for sub in [".opencode/skills", ".claude/skills", ".agents/skills"] where claudeSkills || sub != ".claude/skills" {
                    scan(dir.appendingPathComponent(sub), .project)
                }
            }
            scan(configHome.appendingPathComponent("opencode/skills"), .user)
            if claudeSkills {
                scan(env.home.appendingPathComponent(".claude/skills"), .user, note: "shared with Claude Code")
            }
            scan(env.home.appendingPathComponent(".agents/skills"), .user, note: "shared with Codex")
            // Names must be unique across all locations.
            var seen = Set<String>()
            for i in found.indices {
                if seen.contains(found[i].name) { found[i].timing = .skipped("duplicate name; OpenCode requires unique names") }
                seen.insert(found[i].name)
            }
        case .cursor:
            // Cursor walks each skills root for every SKILL.md; folders in
            // between only group skills.
            for dir in projectDirs.reversed() {
                scan(dir.appendingPathComponent(".agents/skills"), .project, recursive: true)
                scan(dir.appendingPathComponent(".cursor/skills"), .project, recursive: true)
                scan(dir.appendingPathComponent(".claude/skills"), .project, note: "shared with Claude Code", recursive: true)
                scan(dir.appendingPathComponent(".codex/skills"), .project, note: "shared with Codex", recursive: true)
            }
            scan(env.home.appendingPathComponent(".agents/skills"), .user, recursive: true)
            scan(env.home.appendingPathComponent(".cursor/skills"), .user, recursive: true)
            scan(env.home.appendingPathComponent(".claude/skills"), .user, note: "shared with Claude Code", recursive: true)
            scan(env.home.appendingPathComponent(".codex/skills"), .user, note: "shared with Codex", recursive: true)
            scan(env.home.appendingPathComponent(".cursor/skills-cursor"), .bundled, note: "ships with Cursor")
        case .geminiCLI:
            // Highest precedence first: workspace (cwd only), user, extensions;
            // within a layer .agents beats .gemini.
            let gHome = GeminiResolver.home(env).appendingPathComponent(".gemini")
            if let cwd = projectDirs.last {
                scan(cwd.appendingPathComponent(".agents/skills"), .project, note: "shared with Codex and Antigravity")
                scan(cwd.appendingPathComponent(".gemini/skills"), .project, note: "Gemini CLI; Antigravity CLI asks to move it to .agents/skills")
            }
            scan(env.home.appendingPathComponent(".agents/skills"), .user, note: "Gemini CLI; shared with Codex")
            scan(gHome.appendingPathComponent("skills"), .user, note: "Gemini CLI and Antigravity CLI")
            for ext in ((try? FileManager.default.contentsOfDirectory(atPath: gHome.appendingPathComponent("extensions").path)) ?? []).sorted() {
                scan(gHome.appendingPathComponent("extensions/\(ext)/skills"), .extra, note: "from the \(ext) extension")
            }
            // Antigravity also reads parent folders up to the repository root.
            for dir in projectDirs.reversed().dropFirst() {
                scan(dir.appendingPathComponent(".agents/skills"), .project, note: "parent folder · Antigravity")
            }
            for dir in projectDirs.reversed() {
                scan(dir.appendingPathComponent(".agent/skills"), .project, note: "older Antigravity location, still read")
            }
            scan(gHome.appendingPathComponent("config/skills"), .user, note: "Antigravity")
            scan(gHome.appendingPathComponent("antigravity-cli/skills"), .user, note: "Antigravity CLI")
            scan(gHome.appendingPathComponent("antigravity/skills"), .user, note: "older Antigravity location, still read")
        case .copilot:
            for dir in projectDirs.reversed() {
                scan(dir.appendingPathComponent(".github/skills"), .project)
                scan(dir.appendingPathComponent(".claude/skills"), .project, note: "shared with Claude Code")
                scan(dir.appendingPathComponent(".agents/skills"), .project, note: "shared with Codex")
            }
            scan(copilotHome.appendingPathComponent("skills"), .user)
            scan(env.home.appendingPathComponent(".agents/skills"), .user, note: "shared with Codex")
            scan(env.home.appendingPathComponent(".claude/skills"), .user, note: "VS Code only; Copilot CLI doesn’t read it")
        case .devin:
            // read_config_from.claude also brings in Claude Code's skills.
            let claude = DevinSources(home: env.home, root: projectDirs.first ?? env.home).claude
            for dir in projectDirs.reversed() {
                scan(dir.appendingPathComponent(".devin/skills"), .project)
                scan(dir.appendingPathComponent(".agents/skills"), .project, note: "shared with Codex")
                scan(dir.appendingPathComponent(".windsurf/skills"), .project, note: "Windsurf location, still read")
                if claude { scan(dir.appendingPathComponent(".claude/skills"), .project, note: "imported from Claude Code") }
                scan(dir.appendingPathComponent(".github/skills"), .project, note: "imported from Copilot")
            }
            scan(env.home.appendingPathComponent(".config/devin/skills"), .user)
            scan(env.home.appendingPathComponent(".agents/skills"), .user, note: "shared with Codex")
            scan(env.home.appendingPathComponent(".codeium/windsurf/skills"), .user, note: "Windsurf location, still read")
            scan(copilotHome.appendingPathComponent("skills"), .user, note: "imported from Copilot")
        case .cline:
            // Cline reads these in reverse and the last one read wins a name
            // clash, so they are listed winner first. Only the workspace root
            // is searched, not the folders below it.
            let clineHome = env.variables["CLINE_DIR"].map { URL(fileURLWithPath: FileSupport.expandTilde($0, home: env.home)) }
                ?? env.home.appendingPathComponent(".cline")
            scan(env.home.appendingPathComponent(".agents/skills"), .user, note: "shared with Codex")
            scan(clineHome.appendingPathComponent("skills"), .user)
            if let root = projectDirs.first {
                scan(root.appendingPathComponent(".agents/skills"), .project, note: "shared with Codex")
                scan(root.appendingPathComponent(".claude/skills"), .project, note: "shared with Claude Code")
                scan(root.appendingPathComponent(".cline/skills"), .project)
                scan(root.appendingPathComponent(".clinerules/skills"), .project)
            }
        }
        // Where two folders hold the same skill name, the first one listed wins.
        if ![.claudeCode, .openCode, .codex].contains(agent) {
            var seen = Set<String>()
            for i in found.indices {
                if seen.contains(found[i].name), found[i].timing.isLoadedAtLaunch {
                    found[i].timing = .skipped("another skill has the same name")
                }
                seen.insert(found[i].name)
            }
        }
        return found
    }

    /// Where a new skill for `agent` goes.
    public static func newSkillFolder(named name: String, agent: AgentID, project: URL?,
                                      environment env: ResolverEnvironment = .init()) -> URL {
        let base: URL
        switch agent {
        case .claudeCode: base = (project ?? env.home).appendingPathComponent(".claude/skills")
        case .codex: base = (project ?? env.home).appendingPathComponent(".agents/skills")
        case .cursor: base = (project ?? env.home).appendingPathComponent(".cursor/skills")
        // .agents/skills is the one project folder Gemini CLI and Antigravity both read.
        case .geminiCLI: base = project?.appendingPathComponent(".agents/skills") ?? env.home.appendingPathComponent(".gemini/skills")
        case .copilot: base = project?.appendingPathComponent(".github/skills") ?? env.home.appendingPathComponent(".copilot/skills")
        case .devin: base = project?.appendingPathComponent(".devin/skills") ?? env.home.appendingPathComponent(".config/devin/skills")
        case .cline: base = (project ?? env.home).appendingPathComponent(".cline/skills")
        case .openCode:
            base = project?.appendingPathComponent(".opencode/skills")
                ?? (env.variables["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
                    ?? env.home.appendingPathComponent(".config")).appendingPathComponent("opencode/skills")
        }
        return base.appendingPathComponent(name)
    }

    public static func template(name: String) -> String {
        """
        ---
        name: \(name)
        description: Describe what this skill does and when to use it.
        ---

        Steps for the agent to follow.

        """
    }

    private static func skills(in dir: URL, agent: AgentID, scope: Scope, note: String?, recursive: Bool = false) -> [Skill] {
        let files: [URL] = recursive ? skillFiles(below: dir)
            : ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
                .map { dir.appendingPathComponent($0).appendingPathComponent("SKILL.md") }
        return files.compactMap { file in
            let folder = file.deletingLastPathComponent().lastPathComponent
            guard let text = FileSupport.read(file) else { return nil }
            let meta = frontmatter(text)
            let name = meta["name"].flatMap { $0.isEmpty ? nil : $0 } ?? folder
            let description = meta["description"] ?? ""
            return Skill(agent: agent, name: name, description: description,
                         url: file.standardizedFileURL, scope: scope, timing: .launch,
                         tokens: TokenEstimator.estimate(name + " " + description), note: note)
        }
    }

    /// Every `<folder>/…/SKILL.md` below `dir`, skipping hidden folders but
    /// not names like `build` that FileSupport.walk leaves out.
    private static func skillFiles(below dir: URL, depth: Int = 0) -> [URL] {
        guard depth < 6 else { return [] }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        return names.flatMap { name -> [URL] in
            let sub = dir.appendingPathComponent(name)
            guard FileSupport.isDirectory(sub) else { return [] }
            let file = sub.appendingPathComponent("SKILL.md")
            // A skill folder ends the search; its own subfolders are its files.
            return FileSupport.isFile(file) ? [file] : skillFiles(below: sub, depth: depth + 1)
        }
    }

    /// Top-level `key: value` pairs of the YAML frontmatter, including
    /// folded (`>`) and literal (`|`) blocks.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingPrefix("\u{FEFF}").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var result: [String: String] = [:]
        var key: String?
        var block: [String] = []
        func flush() {
            if let key, !block.isEmpty { result[key] = block.joined(separator: " ") }
            key = nil
            block = []
        }
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if key != nil, line.hasPrefix(" ") || line.hasPrefix("\t") {
                block.append(line.trimmingCharacters(in: .whitespaces))
                continue
            }
            flush()
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if [">", "|", ">-", "|-"].contains(v) { key = k; continue }
            result[k] = Frontmatter.unquote(v)
        }
        flush()
        return result
    }
}
