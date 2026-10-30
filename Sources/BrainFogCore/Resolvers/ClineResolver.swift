import Foundation

/// Models Cline's rules as its SDK reads them, which Cline CLI and the
/// newer VS Code extension share (sdk/packages/shared/src/storage/paths.ts).
/// The older extension, still shipped to some users, reads a few more files
/// and honours `paths`; entries note where. See docs/DESIGN.md §3.
public struct ClineResolver: ContextResolver {
    public let agent = AgentID.cline

    public init() {}

    private struct Rule {
        var url: URL
        var name: String
        var scope: Scope
        var disabled: Bool
        var paths: [String]
    }

    public func resolve(workingDirectory: URL, environment env: ResolverEnvironment) -> ResolvedContext {
        let cwd = workingDirectory.standardizedFileURL
        let projectRoot = FileSupport.gitRoot(of: cwd)
        let root = projectRoot ?? cwd
        let clineHome = env.variables["CLINE_DIR"].map {
            URL(fileURLWithPath: FileSupport.expandTilde($0, home: env.home))
        } ?? env.home.appendingPathComponent(".cline")
        var list = EntryList(agent: agent)

        // Search order; a later rule with the same name replaces an earlier one.
        var rules: [Rule] = []
        func file(_ url: URL, name: String? = nil, scope: Scope) {
            guard FileSupport.isFile(url) else { return }
            let yaml = Frontmatter.split(FileSupport.read(url) ?? "").yaml ?? ""
            let disabled = Frontmatter.scalar("disabled", in: yaml) == "true" || Frontmatter.scalar("enabled", in: yaml) == "false"
            rules.append(Rule(url: url.standardizedFileURL,
                              name: Frontmatter.scalar("name", in: yaml) ?? name ?? url.deletingPathExtension().lastPathComponent,
                              scope: scope, disabled: disabled, paths: Frontmatter.list("paths", in: yaml)))
        }
        func folder(_ dir: URL, scope: Scope) {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            for n in names where !n.hasPrefix(".") && ["md", "markdown", "txt"].contains((n as NSString).pathExtension) {
                let url = dir.appendingPathComponent(n)
                file(url, name: n == "AGENTS.md" ? (scope == .user ? "Global AGENTS.md" : "Workspace AGENTS.md") : nil, scope: scope)
            }
        }

        file(root.appendingPathComponent("AGENTS.md"), name: "Workspace AGENTS.md", scope: .project)
        let clinerules = root.appendingPathComponent(".clinerules")
        if FileSupport.isDirectory(clinerules) { folder(clinerules, scope: .rule) } else { file(clinerules, scope: .project) }
        folder(root.appendingPathComponent(".cline/rules"), scope: .rule)
        file(env.home.appendingPathComponent(".agents/AGENTS.md"), name: "Global AGENTS.md", scope: .user)
        folder(clineHome.appendingPathComponent("rules"), scope: .user)
        folder(env.home.appendingPathComponent("Cline/Rules"), scope: .user)
        folder(env.home.appendingPathComponent("Documents/Cline/Rules"), scope: .user)

        var winner: [String: Int] = [:]
        for (i, rule) in rules.enumerated() { winner[rule.name.lowercased()] = i }
        // The prompt lists enabled rules sorted by name.
        let order = rules.indices.sorted { rules[$0].name.localizedCompare(rules[$1].name) == .orderedAscending }
        for i in order {
            let rule = rules[i]
            let timing: LoadTiming
            if rule.disabled {
                timing = .skipped("switched off in its frontmatter")
            } else if winner[rule.name.lowercased()] != i {
                timing = .skipped("a later rule named “\(rule.name)” replaces it")
            } else {
                timing = .launch
            }
            let note = rule.paths.isEmpty ? nil
                : "always on; only the older Cline extension limits it to \(rule.paths.joined(separator: ", "))"
            list.add(rule.url, scope: rule.scope, timing: timing, note: note)
        }

        // Files only the older VS Code extension reads.
        let legacy: LoadTiming = .skipped("only the older Cline extension reads this")
        list.add(cwd.appendingPathComponent(".cursorrules"), scope: .project, timing: legacy)
        for url in FileSupport.walk(cwd.appendingPathComponent(".cursor/rules"), maxDepth: 3) where url.pathExtension == "mdc" {
            list.add(url, scope: .rule, timing: legacy)
        }
        list.add(cwd.appendingPathComponent(".windsurfrules"), scope: .project, timing: legacy)
        if FileSupport.isDirectory(clinerules) {
            for url in FileSupport.walk(clinerules, maxDepth: 3) where url.deletingLastPathComponent().path != clinerules.path {
                let rel = url.path.dropFirst(clinerules.path.count + 1)
                if rel.hasPrefix("workflows/") || rel.hasPrefix("skills/") || rel.hasPrefix("hooks/") { continue }
                list.add(url, scope: .rule, timing: .skipped("in a subfolder; only the older Cline extension reads subfolders"))
            }
        }

        list.diagnostics.append(.init(.info,
            "Cline ships two engines and picks one per user. This shows the newer one (also Cline CLI); the older one also reads .cursorrules, .cursor/rules and .windsurfrules, and honours paths: in rules."))
        return list.finish(workingDirectory: cwd, projectRoot: projectRoot)
    }
}
