import Foundation

/// Models Claude Code's loading under each Project instructions setting
/// (https://code.claude.com/docs/en/memory). The CLI, the IDE extensions and
/// the desktop app's Code tab read the same files. See docs/DESIGN.md §3.
public struct ClaudeCodeResolver: ContextResolver {
    public let agent = AgentID.claudeCode
    public static let memoryLineLimit = 200
    public static let memoryByteLimit = 25 * 1024
    public static let maxImportHops = 4
    /// A CLAUDE.md larger than this is skipped whole.
    public static let maxFileBytes = 4 * 1024 * 1024

    public init() {}

    /// `~/.claude/projects/<key>`: every character outside [A-Za-z0-9-]
    /// becomes `-`.
    public static func projectKey(for directory: URL) -> String {
        String(directory.standardizedFileURL.path.map { c in
            c.isASCII && (c.isLetter || c.isNumber || c == "-") ? c : "-"
        })
    }

    public func resolve(workingDirectory: URL, environment env: ResolverEnvironment) -> ResolvedContext {
        let cwd = workingDirectory.standardizedFileURL
        let claudeHome = env.home.appendingPathComponent(".claude")
        let projectRoot = FileSupport.gitRoot(of: cwd)
        let settings = ClaudeSettings(home: env.home, projectRoot: projectRoot ?? cwd, managed: env.claudeManagedDirectory)
        let mode = settings.instructionFiles
        var list = EntryList(agent: agent)

        func add(_ url: URL, _ scope: Scope, _ timing: LoadTiming = .launch, note: String? = nil) {
            var timing = timing
            if scope != .managed, settings.isExcluded(url) {
                timing = .skipped("excluded by claudeMdExcludes")
            } else if mode == .managedOnly, scope != .managed, timing.isLoadedAtLaunch {
                timing = .skipped("Project instructions is set to managed-only")
            } else if FileSupport.size(url) > Self.maxFileBytes {
                timing = .skipped("over 4 MiB, so Claude Code loads none of it")
            }
            guard let text = list.add(url, scope: scope, timing: timing, note: note) else { return }
            if case .skipped = timing { return }
            addImports(of: url, text: text, timing: timing, hops: 1, home: env.home, into: &list)
        }

        // 1. Managed policy, then user scope.
        add(env.claudeManagedDirectory.appendingPathComponent("CLAUDE.md"), .managed)
        let userFile = claudeHome.appendingPathComponent("CLAUDE.md")
        add(userFile, .user)
        addRules(in: claudeHome.appendingPathComponent("rules"), base: cwd, mode: mode, into: &list)

        // 2. Ancestors, root first. By default CLAUDE.md files win over AGENTS.md.
        let ancestors = FileSupport.ancestors(of: cwd)
        let agentsNames = ["AGENTS.md", ".claude/AGENTS.md"]
        let claudeFiles = Self.claudeFiles(above: cwd, home: env.home)
        let readsAgents = mode == .claudeOrAgents && claudeFiles.isEmpty
        let skipAgents: String? = switch mode {
        case .claudeOrAgents: "a CLAUDE.md exists, so AGENTS.md is not read by default"
        case .claudeAndAgents: nil
        case .claudeOnly: "Project instructions is set to claude-md"
        case .managedOnly: "Project instructions is set to managed-only"
        }

        for dir in ancestors {
            let above = dir.path != cwd.path
            let where_ = above ? "parent directory" : nil
            if readsAgents {
                for name in agentsNames {
                    add(dir.appendingPathComponent(name), .project, note: where_ ?? "no CLAUDE.md found, so AGENTS.md is read instead")
                }
            } else {
                add(dir.appendingPathComponent("CLAUDE.md"), .project, note: where_)
                if dir.path != env.home.path {
                    add(dir.appendingPathComponent(".claude/CLAUDE.md"), .project, note: where_)
                }
                add(dir.appendingPathComponent("CLAUDE.local.md"), .local, note: where_)
                // A CLAUDE.md linked to AGENTS.md is already listed as itself.
                let linked = Set(["CLAUDE.md", ".claude/CLAUDE.md"].map {
                    dir.appendingPathComponent($0).resolvingSymlinksInPath().path
                })
                for name in agentsNames where !linked.contains(dir.appendingPathComponent(name).resolvingSymlinksInPath().path) {
                    if let skipAgents {
                        list.add(dir.appendingPathComponent(name), scope: .project, timing: .skipped(skipAgents))
                    } else {
                        add(dir.appendingPathComponent(name), .project, note: where_)
                    }
                }
            }
            if dir.path != env.home.path {
                addRules(in: dir.appendingPathComponent(".claude/rules"), base: dir, mode: mode, into: &list)
            }
        }

        if mode == .claudeOrAgents, !readsAgents, claudeFiles.allSatisfy({ $0.lastPathComponent == "CLAUDE.local.md" }),
           ancestors.contains(where: { FileSupport.isFile($0.appendingPathComponent("AGENTS.md")) }) {
            list.diagnostics.append(.init(.warning,
                "Only a CLAUDE.local.md exists, so Claude Code skips AGENTS.md. Add @AGENTS.md to CLAUDE.local.md, or set Project instructions to claude-md-and-agents-md."))
        }

        // 3. Auto memory.
        addAutoMemory(cwd: cwd, projectRoot: projectRoot, claudeHome: claudeHome,
                      settings: settings, env: env, into: &list)

        return list.finish(workingDirectory: cwd, projectRoot: projectRoot)
    }

    /// CLAUDE.md, .claude/CLAUDE.md and CLAUDE.local.md files from the root
    /// down to `cwd`, leaving out the user file. When there are none, Claude
    /// Code reads AGENTS.md instead.
    static func claudeFiles(above cwd: URL, home: URL) -> [URL] {
        let userFile = home.appendingPathComponent(".claude/CLAUDE.md").standardizedFileURL
        return FileSupport.ancestors(of: cwd).flatMap { dir in
            ["CLAUDE.md", ".claude/CLAUDE.md", "CLAUDE.local.md"].map { dir.appendingPathComponent($0).standardizedFileURL }
        }.filter { FileSupport.isFile($0) && $0.path != userFile.path }
    }

    private func addRules(in dir: URL, base: URL, mode: ClaudeSettings.InstructionFiles, into list: inout EntryList) {
        guard FileSupport.isDirectory(dir) else { return }
        for url in FileSupport.walk(dir, skipHidden: false) where url.pathExtension == "md" {
            let text = FileSupport.read(url) ?? ""
            let paths = Frontmatter.split(text).yaml.map { Frontmatter.list("paths", in: $0) } ?? []
            // managed-only keeps path-scoped rules, which still load on demand.
            let timing: LoadTiming = !paths.isEmpty
                ? .onDemand("when Claude reads or edits files matching \(paths.joined(separator: ", "))")
                : mode == .managedOnly ? .skipped("Project instructions is set to managed-only") : .launch
            list.add(url, scope: .rule, timing: timing)
        }
    }

    private func addAutoMemory(cwd: URL, projectRoot: URL?, claudeHome: URL,
                               settings: ClaudeSettings, env: ResolverEnvironment,
                               into list: inout EntryList) {
        let dir: URL
        if let custom = settings.autoMemoryDirectory {
            dir = URL(fileURLWithPath: FileSupport.expandTilde(custom, home: env.home))
        } else {
            dir = claudeHome.appendingPathComponent("projects")
                .appendingPathComponent(Self.projectKey(for: projectRoot ?? cwd))
                .appendingPathComponent("memory")
        }
        let enabled = settings.autoMemoryEnabled && !env.flag("CLAUDE_CODE_DISABLE_AUTO_MEMORY")
        let index = dir.appendingPathComponent("MEMORY.md")
        list.add(index, scope: .autoMemory,
                 timing: enabled ? .launch : .skipped("auto memory is off"),
                 note: "first \(Self.memoryLineLimit) lines or 25KB",
                 visible: Limits.head(lines: Self.memoryLineLimit, bytes: Self.memoryByteLimit))
        if let entry = list.entries.last, entry.url == index.standardizedFileURL, entry.truncated, enabled {
            list.diagnostics.append(.init(.warning,
                "MEMORY.md is over \(Self.memoryLineLimit) lines or 25KB; the rest is not loaded at launch.", url: index))
        }
        for url in FileSupport.walk(dir, maxDepth: 2)
        where url.pathExtension == "md" && url.lastPathComponent != "MEMORY.md" {
            list.add(url, scope: .autoMemory,
                     timing: enabled ? .onDemand("read when Claude follows the MEMORY.md index") : .skipped("auto memory is off"))
        }
    }

    // MARK: @imports

    private func addImports(of file: URL, text: String, timing: LoadTiming, hops: Int,
                            home: URL, into list: inout EntryList) {
        for path in Self.importPaths(in: text) {
            let expanded = FileSupport.expandTilde(path, home: home)
            let target = URL(fileURLWithPath: expanded, relativeTo: file.deletingLastPathComponent())
                .standardizedFileURL
            guard FileSupport.isFile(target) else {
                list.diagnostics.append(.init(.warning, "Import target not found: @\(path)", url: file))
                continue
            }
            guard hops <= Self.maxImportHops else {
                list.diagnostics.append(.init(.warning, "@\(path) exceeds the \(Self.maxImportHops)-hop import limit and is not loaded", url: file))
                continue
            }
            // Already listed, say as a path-scoped rule or a skipped AGENTS.md:
            // an import at launch loads it at launch all the same.
            if list.contains(target) {
                if timing.isLoadedAtLaunch, let sub = list.promote(target, importedBy: file) {
                    addImports(of: target, text: sub, timing: timing, hops: hops + 1, home: home, into: &list)
                }
                continue
            }
            guard let sub = list.add(target, scope: .imported, timing: timing, importedBy: file) else { continue }
            addImports(of: target, text: sub, timing: timing, hops: hops + 1, home: home, into: &list)
        }
    }

    /// `@path` tokens outside code. A token counts as a path when it starts
    /// with `~/`, `./`, `../` or `/`, or ends in a file extension.
    static func importPaths(in text: String) -> [String] {
        var paths: [String] = []
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            let stripped = line.replacingOccurrences(of: "`[^`]*`", with: "", options: .regularExpression)
            let re = try! NSRegularExpression(pattern: #"(?:^|\s)@([^\s`]+)"#)
            for m in re.matches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)) {
                guard let r = Range(m.range(at: 1), in: stripped) else { continue }
                // Trailing punctuation only: a leading ./ or ../ is part of the path.
                var token = String(stripped[r])
                while let last = token.last, ".,;:)]}".contains(last) { token.removeLast() }
                let pathLike = ["~/", "./", "../", "/"].contains { token.hasPrefix($0) }
                    || token.range(of: #"\.[A-Za-z0-9]{1,8}$"#, options: .regularExpression) != nil
                if pathLike { paths.append(token) }
            }
        }
        return paths
    }
}

/// The few Claude Code settings that change what loads.
struct ClaudeSettings {
    /// Project instructions: which of CLAUDE.md and AGENTS.md load.
    enum InstructionFiles: String {
        case claudeOrAgents = "claude-md-or-agents-md"
        case claudeAndAgents = "claude-md-and-agents-md"
        case claudeOnly = "claude-md"
        case managedOnly = "managed-only"
    }

    var autoMemoryEnabled = true
    var autoMemoryDirectory: String?
    var excludes: [String] = []
    var instructionFiles = InstructionFiles.claudeOrAgents

    init(home: URL, projectRoot: URL, managed: URL? = nil) {
        let user = home.appendingPathComponent(".claude/settings.json")
        // managed-settings.json, then managed-settings.d/*.json in name order.
        var managedFiles: [URL] = []
        if let managed {
            managedFiles.append(managed.appendingPathComponent("managed-settings.json"))
            let dropIns = managed.appendingPathComponent("managed-settings.d")
            managedFiles += ((try? FileManager.default.contentsOfDirectory(atPath: dropIns.path)) ?? [])
                .filter { !$0.hasPrefix(".") && $0.hasSuffix(".json") }.sorted()
                .map { dropIns.appendingPathComponent($0) }
        }
        let files = [user,
                     projectRoot.appendingPathComponent(".claude/settings.json"),
                     projectRoot.appendingPathComponent(".claude/settings.local.json")] + managedFiles
        for file in files {
            guard let text = FileSupport.read(file), let json = JSONC.object(from: text) else { continue }
            if let v = json["autoMemoryEnabled"] as? Bool { autoMemoryEnabled = v }
            if let v = json["autoMemoryDirectory"] as? String { autoMemoryDirectory = v }
            if let v = json["claudeMdExcludes"] as? [String] { excludes += v }
            // Read only from user and managed settings. Claude Code 2.1.285
            // and later accept both plugin IDs; the newer one wins here.
            guard file == user || managedFiles.contains(file),
                  let plugins = json["pluginConfigs"] as? [String: Any] else { continue }
            for id in ["agents-md@builtin", "cc-plugin-agents-md@builtin"] {
                let options = (plugins[id] as? [String: Any])?["options"] as? [String: Any]
                if let v = (options?["instructionFiles"] as? String).flatMap(InstructionFiles.init(rawValue:)) {
                    instructionFiles = v
                }
            }
        }
    }

    func isExcluded(_ url: URL) -> Bool {
        excludes.contains { Glob.matches($0, url.standardizedFileURL.path) }
    }
}
