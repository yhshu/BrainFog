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
                     bytes: FileSupport.size(url), tokens: tokens, note: note)
    }
}

/// Finds the skills each agent lists at session start. Sources:
/// Claude Code https://code.claude.com/docs/en/skills,
/// Codex https://learn.chatgpt.com/docs/build-skills,
/// OpenCode https://opencode.ai/docs/skills/,
/// Cursor https://cursor.com/docs/context/skills.
public enum SkillResolver {
    /// - Parameter workingDirectory: the project folder, or nil for the
    ///   global layer only.
    public static func resolve(agent: AgentID, workingDirectory: URL?,
                               environment env: ResolverEnvironment = .init()) -> [Skill] {
        // Project folders from the repository root (or the folder itself) down.
        var projectDirs: [URL] = []
        if let cwd = workingDirectory?.standardizedFileURL {
            let root = FileSupport.gitRoot(of: cwd)
            projectDirs = root.map { r in FileSupport.ancestors(of: cwd).filter { FileSupport.isWithin($0, r) } } ?? [cwd]
            projectDirs.removeAll { $0.path == env.home.path }
        }
        let codexHome = env.variables["CODEX_HOME"].map {
            URL(fileURLWithPath: FileSupport.expandTilde($0, home: env.home))
        } ?? env.home.appendingPathComponent(".codex")
        let configHome = env.variables["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? env.home.appendingPathComponent(".config")

        var found: [Skill] = []
        func scan(_ dir: URL, _ scope: Scope, note: String? = nil) {
            for skill in skills(in: dir, agent: agent, scope: scope, note: note)
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
        case .openCode:
            for dir in projectDirs.reversed() {
                for sub in [".opencode/skills", ".claude/skills", ".agents/skills"] {
                    scan(dir.appendingPathComponent(sub), .project)
                }
            }
            scan(configHome.appendingPathComponent("opencode/skills"), .user)
            scan(env.home.appendingPathComponent(".claude/skills"), .user, note: "shared with Claude Code")
            scan(env.home.appendingPathComponent(".agents/skills"), .user, note: "shared with Codex")
            // Names must be unique across all locations.
            var seen = Set<String>()
            for i in found.indices {
                if seen.contains(found[i].name) { found[i].timing = .skipped("duplicate name; OpenCode requires unique names") }
                seen.insert(found[i].name)
            }
        case .cursor:
            for dir in projectDirs.reversed() {
                scan(dir.appendingPathComponent(".agents/skills"), .project)
                scan(dir.appendingPathComponent(".cursor/skills"), .project)
                scan(dir.appendingPathComponent(".claude/skills"), .project, note: "shared with Claude Code")
                scan(dir.appendingPathComponent(".codex/skills"), .project, note: "shared with Codex")
            }
            scan(env.home.appendingPathComponent(".agents/skills"), .user)
            scan(env.home.appendingPathComponent(".cursor/skills"), .user)
            scan(env.home.appendingPathComponent(".claude/skills"), .user, note: "shared with Claude Code")
            scan(env.home.appendingPathComponent(".codex/skills"), .user, note: "shared with Codex")
            scan(env.home.appendingPathComponent(".cursor/skills-cursor"), .bundled, note: "ships with Cursor")
        case .geminiCLI:
            // Highest precedence first: workspace (cwd only), user, extensions;
            // within a layer .agents beats .gemini.
            let gHome = GeminiResolver.home(env).appendingPathComponent(".gemini")
            if let cwd = projectDirs.last {
                scan(cwd.appendingPathComponent(".agents/skills"), .project, note: "shared with Codex")
                scan(cwd.appendingPathComponent(".gemini/skills"), .project)
            }
            scan(env.home.appendingPathComponent(".agents/skills"), .user, note: "shared with Codex")
            scan(gHome.appendingPathComponent("skills"), .user)
            for ext in ((try? FileManager.default.contentsOfDirectory(atPath: gHome.appendingPathComponent("extensions").path)) ?? []).sorted() {
                scan(gHome.appendingPathComponent("extensions/\(ext)/skills"), .extra, note: "from the \(ext) extension")
            }
        case .copilot:
            for dir in projectDirs.reversed() {
                scan(dir.appendingPathComponent(".github/skills"), .project)
                scan(dir.appendingPathComponent(".claude/skills"), .project, note: "shared with Claude Code")
                scan(dir.appendingPathComponent(".agents/skills"), .project, note: "shared with Codex")
            }
            scan(env.home.appendingPathComponent(".copilot/skills"), .user)
            scan(env.home.appendingPathComponent(".agents/skills"), .user, note: "shared with Codex")
            scan(env.home.appendingPathComponent(".claude/skills"), .user, note: "VS Code’s Local agent only")
        case .devin:
            for dir in projectDirs.reversed() {
                scan(dir.appendingPathComponent(".devin/skills"), .project)
                scan(dir.appendingPathComponent(".agents/skills"), .project, note: "shared with Codex")
                scan(dir.appendingPathComponent(".windsurf/skills"), .project, note: "Windsurf location, still read")
                scan(dir.appendingPathComponent(".claude/skills"), .project, note: "imported from Claude Code")
                scan(dir.appendingPathComponent(".github/skills"), .project, note: "imported from Copilot")
            }
            scan(env.home.appendingPathComponent(".config/devin/skills"), .user)
            scan(env.home.appendingPathComponent(".agents/skills"), .user, note: "shared with Codex")
            scan(env.home.appendingPathComponent(".codeium/windsurf/skills"), .user, note: "Windsurf location, still read")
            scan(env.home.appendingPathComponent(".copilot/skills"), .user, note: "imported from Copilot")
        case .cline:
            // On a name clash the global skill wins.
            let clineHome = env.variables["CLINE_DIR"].map { URL(fileURLWithPath: FileSupport.expandTilde($0, home: env.home)) }
                ?? env.home.appendingPathComponent(".cline")
            scan(clineHome.appendingPathComponent("skills"), .user)
            scan(env.home.appendingPathComponent(".agents/skills"), .user, note: "shared with Codex")
            for dir in projectDirs.reversed() {
                scan(dir.appendingPathComponent(".clinerules/skills"), .project)
                scan(dir.appendingPathComponent(".cline/skills"), .project)
                scan(dir.appendingPathComponent(".claude/skills"), .project, note: "shared with Claude Code")
                scan(dir.appendingPathComponent(".agents/skills"), .project, note: "shared with Codex")
            }
        }
        // Where two folders hold the same skill name, the first one listed wins.
        if agent != .claudeCode && agent != .openCode {
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
        case .geminiCLI: base = (project ?? env.home).appendingPathComponent(".gemini/skills")
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

    private static func skills(in dir: URL, agent: AgentID, scope: Scope, note: String?) -> [Skill] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().compactMap { folder in
            let file = dir.appendingPathComponent(folder).appendingPathComponent("SKILL.md")
            guard let text = FileSupport.read(file) else { return nil }
            let meta = frontmatter(text)
            let name = meta["name"] ?? folder
            let description = meta["description"] ?? ""
            return Skill(agent: agent, name: name, description: description,
                         url: file.standardizedFileURL, scope: scope, timing: .launch,
                         tokens: TokenEstimator.estimate(name + " " + description), note: note)
        }
    }

    /// Top-level `key: value` pairs of the YAML frontmatter, including
    /// folded (`>`) and literal (`|`) blocks.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
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
            var v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if [">", "|", ">-", "|-"].contains(v) { key = k; continue }
            if v.count >= 2, let q = v.first, q == "\"" || q == "'", v.last == q { v = String(v.dropFirst().dropLast()) }
            result[k] = v
        }
        flush()
        return result
    }
}
