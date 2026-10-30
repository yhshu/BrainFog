import Foundation

/// Models OpenCode's rule loading. The docs leave the merge order and
/// multi-level behaviour open; where this resolver infers, entries say so.
/// See docs/DESIGN.md §3.
public struct OpenCodeResolver: ContextResolver {
    public let agent = AgentID.openCode

    public init() {}

    public func resolve(workingDirectory: URL, environment env: ResolverEnvironment) -> ResolvedContext {
        let cwd = workingDirectory.standardizedFileURL
        let projectRoot = FileSupport.gitRoot(of: cwd)
        let configHome = env.variables["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? env.home.appendingPathComponent(".config")
        let globalDir = configHome.appendingPathComponent("opencode")
        let noClaude = env.flag("OPENCODE_DISABLE_CLAUDE_CODE")
        let noClaudePrompt = noClaude || env.flag("OPENCODE_DISABLE_CLAUDE_CODE_PROMPT")
        var list = EntryList(agent: agent)

        // Global: OpenCode's own AGENTS.md, else Claude Code's global file.
        let globalAgents = globalDir.appendingPathComponent("AGENTS.md")
        let claudeGlobal = env.home.appendingPathComponent(".claude/CLAUDE.md")
        if FileSupport.isFile(globalAgents) {
            list.add(globalAgents, scope: .user)
            list.add(claudeGlobal, scope: .user, timing: .skipped("~/.config/opencode/AGENTS.md takes precedence"))
        } else {
            list.add(claudeGlobal, scope: .user,
                     timing: noClaudePrompt ? .skipped("OPENCODE_DISABLE_CLAUDE_CODE(_PROMPT) is set") : .launch,
                     note: "fallback to the Claude Code global file")
        }

        // Project: walk up from cwd (to the git root when there is one);
        // the first AGENTS.md, or failing that CLAUDE.md, wins.
        let chain = FileSupport.ancestors(of: cwd).reversed().filter { dir in
            projectRoot.map { FileSupport.isWithin(dir, $0) } ?? true
        }
        var found = false
        for dir in chain {
            let agents = dir.appendingPathComponent("AGENTS.md")
            let claude = dir.appendingPathComponent("CLAUDE.md")
            let note = dir.path == cwd.path ? nil : "parent directory (first match; inferred)"
            if found {
                list.add(agents, scope: .project, timing: .skipped("a closer directory matched first"))
                continue
            }
            if FileSupport.isFile(agents) {
                list.add(agents, scope: .project, note: note)
                list.add(claude, scope: .project, timing: .skipped("AGENTS.md in the same directory wins"))
                found = true
            } else if FileSupport.isFile(claude) {
                list.add(claude, scope: .project,
                         timing: noClaude ? .skipped("OPENCODE_DISABLE_CLAUDE_CODE is set") : .launch,
                         note: note ?? "no AGENTS.md, falling back to CLAUDE.md")
                found = !noClaude
            }
        }

        // `instructions` from global and project config files.
        var configs = ["opencode.json", "opencode.jsonc"].map { globalDir.appendingPathComponent($0) }
        for dir in chain.reversed() {
            configs += ["opencode.json", "opencode.jsonc"].map { dir.appendingPathComponent($0) }
        }
        if let custom = env.variables["OPENCODE_CONFIG"] {
            configs.append(URL(fileURLWithPath: FileSupport.expandTilde(custom, home: env.home)))
        }
        for config in configs {
            guard let text = FileSupport.read(config), let json = JSONC.object(from: text),
                  let items = json["instructions"] as? [String] else { continue }
            let base = config.deletingLastPathComponent()
            for item in items {
                if item.hasPrefix("http://") || item.hasPrefix("https://"), let url = URL(string: item) {
                    list.addRemote(url, scope: .extra, timing: .launch, note: "remote instructions, 5 s timeout")
                    continue
                }
                let pattern = FileSupport.expandTilde(item, home: env.home)
                let matches = Glob.expand(pattern, base: base)
                if matches.isEmpty {
                    list.diagnostics.append(.init(.warning, "\(item) in instructions matches no files", url: config))
                }
                for url in matches {
                    list.add(url, scope: .extra, note: "from instructions in \(config.lastPathComponent)")
                }
            }
        }

        return list.finish(workingDirectory: cwd, projectRoot: projectRoot)
    }
}
