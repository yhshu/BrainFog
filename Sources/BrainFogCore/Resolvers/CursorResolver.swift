import Foundation

/// Models Cursor's project rules and AGENTS.md. Cursor itself is closed
/// source; this follows its docs. User and team rules live in Cursor's
/// settings and dashboard, not in files, so they cannot be listed.
/// See docs/DESIGN.md §3.
public struct CursorResolver: ContextResolver {
    public let agent = AgentID.cursor

    public init() {}

    public func resolve(workingDirectory: URL, environment env: ResolverEnvironment) -> ResolvedContext {
        // Cursor works from the folder it opened, so that is the workspace root.
        let cwd = workingDirectory.standardizedFileURL
        let projectRoot = FileSupport.gitRoot(of: cwd)
        var list = EntryList(agent: agent)

        list.diagnostics.append(.init(.info,
            "User Rules (Cursor Settings → Rules) and Team Rules are stored by Cursor, not in files, so they are not shown here."))

        // 1. Project rules at the workspace root.
        addRules(in: cwd.appendingPathComponent(".cursor/rules"), nested: nil, into: &list)

        // 2. AGENTS.md at the root; CLAUDE.md only through the CLI.
        list.add(cwd.appendingPathComponent("AGENTS.md"), scope: .project)
        list.add(cwd.appendingPathComponent("CLAUDE.md"), scope: .project,
                 note: "read by the Cursor CLI (cursor-agent); the editor does not document it")

        // 3. Legacy single-file rules.
        let legacy = cwd.appendingPathComponent(".cursorrules")
        if list.add(legacy, scope: .project, note: "legacy format, still read") != nil {
            list.diagnostics.append(.init(.info,
                ".cursorrules is deprecated; Cursor recommends moving it to .cursor/rules.", url: legacy))
        }

        // 4. Nested rules and AGENTS.md apply when working in their folder.
        for url in FileSupport.walk(cwd, maxDepth: 6, skipHidden: false, include: {
            $0.lastPathComponent == "AGENTS.md" || $0.path.contains("/.cursor/rules/")
        }) {
            let parts = url.pathComponents.dropFirst(cwd.pathComponents.count)
            if parts.count > 1, parts.last == "AGENTS.md", !parts.contains(where: { $0.hasPrefix(".") }) {
                let folder = parts.dropLast().joined(separator: "/")
                list.add(url, scope: .directory, timing: .onDemand("when working in \(folder)/"))
                continue
            }
            // <folder>/.cursor/rules/…, with no other hidden folder on the way.
            guard let i = parts.firstIndex(of: ".cursor"), i > parts.startIndex,
                  parts.index(after: i) < parts.endIndex, parts[parts.index(after: i)] == "rules",
                  !parts[..<i].contains(where: { $0.hasPrefix(".") }) else { continue }
            addRule(url, nested: parts[..<i].joined(separator: "/"), into: &list)
        }

        return list.finish(workingDirectory: cwd, projectRoot: projectRoot)
    }

    private func addRules(in dir: URL, nested: String?, into list: inout EntryList) {
        guard FileSupport.isDirectory(dir) else { return }
        for url in FileSupport.walk(dir, skipHidden: false) { addRule(url, nested: nested, into: &list) }
    }

    /// One rule file. `nested` is the folder (relative to the workspace)
    /// whose `.cursor/rules` holds it, or nil for the root.
    private func addRule(_ url: URL, nested: String?, into list: inout EntryList) {
        switch url.pathExtension {
        case "mdc": break
        case "md":
            list.add(url, scope: .rule, timing: .skipped("Cursor only reads .mdc rule files"))
            return
        default: return
        }
        let yaml = Frontmatter.split(FileSupport.read(url) ?? "").yaml ?? ""
        let always = Frontmatter.scalar("alwaysApply", in: yaml)?.lowercased() == "true"
        let globs = Frontmatter.list("globs", in: yaml)
            .flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.isEmpty }
        let description = Frontmatter.scalar("description", in: yaml)

        var timing: LoadTiming
        if always {
            timing = .launch
        } else if !globs.isEmpty {
            timing = .onDemand("when files matching \(globs.joined(separator: ", ")) are in context")
        } else if let description {
            timing = .onDemand("when the agent judges it relevant: \(description)")
        } else {
            timing = .onDemand("only when @-mentioned in chat")
        }
        if let nested, case .launch = timing {
            timing = .onDemand("when working in \(nested)/")
        }
        list.add(url, scope: .rule, timing: timing)
    }
}
