import Foundation

/// Models Devin Local, the agent in Devin Desktop (formerly Windsurf) and
/// Devin CLI. Windsurf's Cascade can no longer start conversations, so its
/// rules engine is not modelled. Closed source; this follows
/// docs.devin.ai. See docs/DESIGN.md §3.
public struct DevinResolver: ContextResolver {
    public let agent = AgentID.devin

    public init() {}

    /// Instruction files read at every level from the workspace root to cwd.
    static let alwaysOnNames = ["AGENTS.md", "AGENTS.local.md", "AGENT.md", ".windsurfrules", "CLAUDE.md"]

    public func resolve(workingDirectory: URL, environment env: ResolverEnvironment) -> ResolvedContext {
        let cwd = workingDirectory.standardizedFileURL
        let projectRoot = FileSupport.gitRoot(of: cwd)
        let root = projectRoot ?? cwd
        let sources = DevinSources(home: env.home, root: root)
        var list = EntryList(agent: agent)

        // 1. Global.
        let devinConfig = env.home.appendingPathComponent(".config/devin")
        addFirst([devinConfig.appendingPathComponent("AGENTS.md"), devinConfig.appendingPathComponent("AGENT.md")],
                 scope: .user, list: &list)
        list.add(env.home.appendingPathComponent(".claude/CLAUDE.md"), scope: .user,
                 timing: sources.claude ? .launch : .skipped("reading Claude config is off (read_config_from)"),
                 note: "imported from Claude Code")
        list.add(env.home.appendingPathComponent(".devin/global_rules.md"), scope: .user)
        for url in FileSupport.walk(env.home.appendingPathComponent(".devin/rules"), maxDepth: 1) where url.pathExtension == "md" {
            addRule(url, scope: .user, nested: nil, list: &list)
        }

        // 2. Workspace root down to cwd.
        let levels = FileSupport.ancestors(of: cwd).filter { FileSupport.isWithin($0, root) }
        for dir in levels {
            let note = dir.path == cwd.path ? nil : "parent directory"
            addAlwaysOn(in: dir, timing: .launch, note: note, sources: sources, list: &list)
            addRuleFolders(in: dir, nested: nil, sources: sources, list: &list)
        }

        // 3. Subdirectories load when Devin touches files in them.
        let names = Set(Self.alwaysOnNames)
        for url in FileSupport.walk(cwd, maxDepth: 6, skipHidden: false, include: {
            names.contains($0.lastPathComponent) || $0.path.contains("/.devin/rules/") || $0.path.contains("/.windsurf/rules/")
        }) {
            let parts = url.pathComponents.dropFirst(cwd.pathComponents.count)
            guard parts.count > 1 else { continue }
            if let i = parts.firstIndex(where: { $0 == ".devin" || $0 == ".windsurf" }) {
                guard i > parts.startIndex, !parts[..<i].contains(where: { $0.hasPrefix(".") }),
                      parts.index(after: i) < parts.endIndex, parts[parts.index(after: i)] == "rules" else { continue }
                if parts[i] == ".windsurf" && !sources.windsurf { continue }
                addRule(url, scope: .rule, nested: parts[..<i].joined(separator: "/"), list: &list)
            } else if !parts.dropLast().contains(where: { $0.hasPrefix(".") }) {
                let folder = parts.dropLast().joined(separator: "/")
                guard sources.allows(url.lastPathComponent) else { continue }
                list.add(url, scope: .directory, timing: .onDemand("when Devin works on files in \(folder)/"))
            }
        }

        if !sources.disabled.isEmpty {
            list.diagnostics.append(.init(.info,
                "read_config_from turns off \(sources.disabled.sorted().joined(separator: ", ")) files."))
        }
        return list.finish(workingDirectory: cwd, projectRoot: projectRoot)
    }

    private func addAlwaysOn(in dir: URL, timing: LoadTiming, note: String?, sources: DevinSources, list: inout EntryList) {
        for name in Self.alwaysOnNames {
            let url = dir.appendingPathComponent(name)
            list.add(url, scope: name == "AGENTS.local.md" ? .local : .project,
                     timing: sources.allows(name) ? timing : .skipped("turned off in read_config_from"),
                     note: name == "CLAUDE.md" ? (note.map { $0 + " · imported from Claude Code" } ?? "imported from Claude Code") : note)
        }
    }

    private func addRuleFolders(in dir: URL, nested: String?, sources: DevinSources, list: inout EntryList) {
        // Only the .devin global_rules.md loads when both exist.
        let devinGlobal = dir.appendingPathComponent(".devin/global_rules.md")
        let windsurfGlobal = dir.appendingPathComponent(".windsurf/global_rules.md")
        list.add(devinGlobal, scope: .rule)
        if FileSupport.isFile(devinGlobal) {
            list.add(windsurfGlobal, scope: .rule, timing: .skipped(".devin/global_rules.md takes its place"))
        } else {
            list.add(windsurfGlobal, scope: .rule,
                     timing: sources.windsurf ? .launch : .skipped("turned off in read_config_from"),
                     note: "Windsurf location, still read")
        }
        for (folder, on) in [(".devin/rules", true), (".windsurf/rules", sources.windsurf)] where on {
            for url in FileSupport.walk(dir.appendingPathComponent(folder), maxDepth: 1, skipHidden: false) {
                addRule(url, scope: .rule, nested: nested, list: &list)
            }
        }
        if sources.cursor {
            for url in FileSupport.walk(dir.appendingPathComponent(".cursor/rules"), maxDepth: 3, skipHidden: false)
            where ["md", "mdc"].contains(url.pathExtension) {
                addCursorRule(url, list: &list)
            }
        }
    }

    private func addFirst(_ urls: [URL], scope: Scope, list: inout EntryList) {
        var found = false
        for url in urls where FileSupport.isFile(url) {
            list.add(url, scope: scope, timing: found ? .skipped("\(urls[0].lastPathComponent) is used instead") : .launch)
            found = true
        }
    }

    /// A `.devin/rules` file; `trigger` decides when it loads.
    private func addRule(_ url: URL, scope: Scope, nested: String?, list: inout EntryList) {
        guard url.pathExtension == "md" else { return }
        let yaml = Frontmatter.split(FileSupport.read(url) ?? "").yaml ?? ""
        let globs = Frontmatter.list("globs", in: yaml)
            .flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.isEmpty }
        var timing: LoadTiming = switch Frontmatter.scalar("trigger", in: yaml) ?? "manual" {
        case "always_on": .launch
        case "glob": .onDemand("when files matching \(globs.isEmpty ? "its globs" : globs.joined(separator: ", ")) are touched")
        case "model_decision": .onDemand("when Devin judges it relevant: \(Frontmatter.scalar("description", in: yaml) ?? "no description")")
        default: .onDemand("only when invoked by name")
        }
        if let nested, timing.isLoadedAtLaunch { timing = .onDemand("when Devin works on files in \(nested)/") }
        list.add(url, scope: scope, timing: timing,
                 note: url.path.contains("/.windsurf/") ? "Windsurf location, still read" : nil)
    }

    /// Cursor's rules, read with Cursor's own frontmatter.
    private func addCursorRule(_ url: URL, list: inout EntryList) {
        let yaml = Frontmatter.split(FileSupport.read(url) ?? "").yaml ?? ""
        let globs = Frontmatter.list("globs", in: yaml).filter { !$0.isEmpty }
        let timing: LoadTiming
        if Frontmatter.scalar("alwaysApply", in: yaml)?.lowercased() == "true" {
            timing = .launch
        } else if !globs.isEmpty {
            timing = .onDemand("when files matching \(globs.joined(separator: ", ")) are touched")
        } else if let description = Frontmatter.scalar("description", in: yaml) {
            timing = .onDemand("when Devin judges it relevant: \(description)")
        } else {
            timing = .onDemand("only when invoked by name")
        }
        list.add(url, scope: .rule, timing: timing, note: "imported from Cursor")
    }
}

/// `read_config_from` in `~/.config/devin/config.json` or
/// `.devin/config.json`: which other tools' files Devin reads. All on by default.
struct DevinSources {
    var claude = true, cursor = true, windsurf = true, agentsStandard = true

    init(home: URL, root: URL) {
        for file in [home.appendingPathComponent(".config/devin/config.json"),
                     root.appendingPathComponent(".devin/config.json")] {
            guard let text = FileSupport.read(file), let json = JSONC.object(from: text),
                  let from = json["read_config_from"] as? [String: Any] else { continue }
            if let v = from["claude"] as? Bool { claude = v }
            if let v = from["cursor"] as? Bool { cursor = v }
            if let v = from["windsurf"] as? Bool { windsurf = v }
            if let v = from["agents_standard"] as? Bool { agentsStandard = v }
        }
    }

    var disabled: [String] {
        [("Claude", claude), ("Cursor", cursor), ("Windsurf", windsurf), ("AGENTS.md", agentsStandard)]
            .filter { !$0.1 }.map(\.0)
    }

    func allows(_ name: String) -> Bool {
        name == "CLAUDE.md" ? claude : agentsStandard
    }
}
