import Foundation

/// Models OpenCode's rule loading, from its docs and source
/// (`session/instruction.ts`). See docs/DESIGN.md §3.
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

        // Project: AGENTS.md, then CLAUDE.md, then the deprecated CONTEXT.md.
        // Each name is looked for from cwd up to the git root; the first name
        // found anywhere wins, and every copy of it is read, closest first.
        let chain = FileSupport.ancestors(of: cwd).reversed().filter { dir in
            projectRoot.map { FileSupport.isWithin(dir, $0) } ?? true
        }
        let projectOff = env.flag("OPENCODE_DISABLE_PROJECT_CONFIG")
        let names = ["AGENTS.md", "CLAUDE.md", "CONTEXT.md"].filter { $0 != "CLAUDE.md" || !noClaudePrompt }
        let winner = names.first { name in chain.contains { FileSupport.isFile($0.appendingPathComponent(name)) } }
        for dir in chain {
            let note = dir.path == cwd.path ? nil : "parent directory"
            for name in ["AGENTS.md", "CLAUDE.md", "CONTEXT.md"] {
                let url = dir.appendingPathComponent(name)
                let timing: LoadTiming = if projectOff {
                    .skipped("OPENCODE_DISABLE_PROJECT_CONFIG is set")
                } else if name == winner {
                    .launch
                } else if name == "CLAUDE.md" && noClaudePrompt {
                    .skipped("OPENCODE_DISABLE_CLAUDE_CODE(_PROMPT) is set")
                } else {
                    .skipped("\(winner ?? "") was found, which OpenCode reads instead")
                }
                list.add(url, scope: .project, timing: timing,
                         note: name == "CONTEXT.md" ? [note, "deprecated name"].compactMap { $0 }.joined(separator: ", ") : note)
            }
        }

        // `instructions` from every config file OpenCode merges. A relative
        // entry is globbed in each folder from cwd up to the git root,
        // whichever file it came from (`relative()` in session/instruction.ts),
        // or only in ~/.config/opencode when project config is off.
        let instructionDirs = projectOff ? [globalDir] : Array(chain)
        var seen = Set<String>()
        for config in Self.configFiles(project: cwd, env: env).map(\.url) {
            guard let text = FileSupport.read(config), let json = JSONC.object(from: text),
                  let items = json["instructions"] as? [String] else { continue }
            for item in items {
                if item.hasPrefix("http://") || item.hasPrefix("https://"), let url = URL(string: item) {
                    list.addRemote(url, scope: .extra, timing: .launch, note: "remote instructions, 5 s timeout")
                    continue
                }
                let pattern = FileSupport.expandTilde(item, home: env.home)
                // Absolute entries glob only their last component.
                let matches = pattern.hasPrefix("/")
                    ? Glob.expand(URL(fileURLWithPath: pattern).lastPathComponent,
                                  base: URL(fileURLWithPath: pattern).deletingLastPathComponent())
                    : instructionDirs.flatMap { Glob.expand(pattern, base: $0) }
                if matches.isEmpty {
                    list.diagnostics.append(.init(.warning, "\(item) in instructions matches no files", url: config))
                }
                // OpenCode keeps each path once.
                for url in matches where seen.insert(url.path).inserted {
                    list.add(url, scope: .extra, note: "from instructions in \(config.lastPathComponent)")
                }
            }
        }

        return list.finish(workingDirectory: cwd, projectRoot: projectRoot)
    }

    struct ConfigFile {
        var url: URL
        var scope: Scope
        var note: String?
        var writable: Bool
    }

    /// Config files in the order OpenCode merges them, later ones winning
    /// (https://opencode.ai/docs/config/). The TUI and the desktop app share
    /// them. The remote .well-known config and OPENCODE_CONFIG_CONTENT are
    /// not files, so they are left out.
    static func configFiles(project: URL?, env: ResolverEnvironment) -> [ConfigFile] {
        let names = ["opencode.json", "opencode.jsonc"]
        let configHome = env.variables["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? env.home.appendingPathComponent(".config")
        func path(_ s: String) -> URL { URL(fileURLWithPath: FileSupport.expandTilde(s, home: env.home)) }
        var out = names.map { ConfigFile(url: configHome.appendingPathComponent("opencode/\($0)"), scope: .user, writable: true) }
        if let custom = env.variables["OPENCODE_CONFIG"] {
            out.append(ConfigFile(url: path(custom), scope: .user, note: "from OPENCODE_CONFIG", writable: false))
        }
        if let project, !env.flag("OPENCODE_DISABLE_PROJECT_CONFIG") {
            // The git root down to the folder, so closer files win.
            let root = FileSupport.gitRoot(of: project) ?? project
            let chain = FileSupport.ancestors(of: project).filter { FileSupport.isWithin($0, root) }
            for dir in chain {
                let here = dir.path == project.path
                out += names.map { ConfigFile(url: dir.appendingPathComponent($0), scope: .project,
                                              note: here ? nil : "parent directory", writable: here) }
            }
            for dir in chain {
                out += names.map { ConfigFile(url: dir.appendingPathComponent(".opencode/\($0)"), scope: .project,
                                              note: "in .opencode", writable: false) }
            }
        }
        if let dir = env.variables["OPENCODE_CONFIG_DIR"] {
            out += names.map { ConfigFile(url: path(dir).appendingPathComponent($0), scope: .user,
                                          note: "from OPENCODE_CONFIG_DIR", writable: false) }
        }
        out += names.map { ConfigFile(url: URL(fileURLWithPath: "/Library/Application Support/opencode/\($0)"), scope: .managed,
                                      note: "managed by your organization", writable: false) }
        return out
    }
}
