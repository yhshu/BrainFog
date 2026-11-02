import Foundation

/// Models GitHub Copilot's custom instructions as Copilot CLI reads them,
/// which is also how VS Code's Copilot harness reads them. VS Code's older
/// Local harness differs in places; entries note where. See docs/DESIGN.md §3.
public struct CopilotResolver: ContextResolver {
    public let agent = AgentID.copilot

    public init() {}

    /// Checked at the repository root, cwd, and every folder between.
    static let standardNames = [".github/copilot-instructions.md", "AGENTS.md", "CLAUDE.md", ".claude/CLAUDE.md", "GEMINI.md"]

    public func resolve(workingDirectory: URL, environment env: ResolverEnvironment) -> ResolvedContext {
        let cwd = workingDirectory.standardizedFileURL
        let projectRoot = FileSupport.gitRoot(of: cwd)
        let root = projectRoot ?? cwd
        var list = EntryList(agent: agent)

        func add(_ url: URL, _ scope: Scope, _ timing: LoadTiming = .launch, note: String? = nil) {
            guard let text = list.add(url, scope: scope, timing: timing, note: note) else { return }
            if case .skipped = timing { return }
            // @references are followed only in these files, and only inside the repository.
            guard ["copilot-instructions.md", "AGENTS.md", "CLAUDE.md"].contains(url.lastPathComponent) else { return }
            addReferences(of: url, text: text, timing: timing, root: FileSupport.isWithin(url, root) ? root : url.deletingLastPathComponent(),
                          home: env.home, into: &list)
        }

        // 1. Personal instructions.
        let copilotHome = env.variables["COPILOT_HOME"].map {
            URL(fileURLWithPath: FileSupport.expandTilde($0, home: env.home))
        } ?? env.home.appendingPathComponent(".copilot")
        add(copilotHome.appendingPathComponent("copilot-instructions.md"), .user)
        for url in FileSupport.walk(copilotHome.appendingPathComponent("instructions"), maxDepth: 4)
        where url.lastPathComponent.hasSuffix(".instructions.md") {
            addInstructions(url, scope: .user, into: &list)
        }

        // 2. Repository root down to cwd.
        let levels = FileSupport.ancestors(of: cwd).filter { FileSupport.isWithin($0, root) }
        for dir in levels {
            let note = dir.path == cwd.path || dir.path == root.path ? nil : "folder between the repository root and here"
            for name in Self.standardNames {
                add(dir.appendingPathComponent(name), .project, note: note)
            }
        }

        // 3. Path-specific files, at the root and cwd but not in between.
        var dirs = [root, cwd].map { $0.appendingPathComponent(".github/instructions") }
        dirs += (env.variables["COPILOT_CUSTOM_INSTRUCTIONS_DIRS"] ?? "").split(separator: ",").map {
            URL(fileURLWithPath: FileSupport.expandTilde($0.trimmingCharacters(in: .whitespaces), home: env.home))
        }
        for dir in dirs {
            for url in FileSupport.walk(dir, skipHidden: false) where url.lastPathComponent.hasSuffix(".instructions.md") {
                addInstructions(url, scope: .rule, into: &list)
            }
            if !dir.path.hasSuffix(".github/instructions") {
                add(dir.appendingPathComponent("AGENTS.md"), .extra, note: "from COPILOT_CUSTOM_INSTRUCTIONS_DIRS")
            }
        }

        // 4. Below cwd: read when Copilot works on files there.
        let names = Set(["AGENTS.md", "CLAUDE.md", "GEMINI.md", "copilot-instructions.md"])
        for url in FileSupport.walk(cwd, maxDepth: 6, skipHidden: false, include: { names.contains($0.lastPathComponent) }) {
            var dir = url.deletingLastPathComponent()
            if url.lastPathComponent == "copilot-instructions.md" {
                guard dir.lastPathComponent == ".github" else { continue }
                dir = dir.deletingLastPathComponent()
            }
            guard dir.path != cwd.path else { continue }
            let folder = String(dir.path.dropFirst(cwd.path.count + 1))
            guard !folder.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            list.add(url, scope: .directory, timing: .onDemand("when Copilot works on files in \(folder)/"))
        }

        list.diagnostics.append(.init(.info,
            "Copilot Memory and organization instructions are stored on GitHub, not in files, so they are not shown here. VS Code’s Local agent also reads ~/.claude/CLAUDE.md and .claude/rules.",
            topic: .onDemand))
        return list.finish(workingDirectory: cwd, projectRoot: projectRoot)
    }

    private func addInstructions(_ url: URL, scope: Scope, into list: inout EntryList) {
        let yaml = Frontmatter.split(FileSupport.read(url) ?? "").yaml ?? ""
        let applyTo = Frontmatter.commaList(Frontmatter.scalar("applyTo", in: yaml) ?? "")
        let timing: LoadTiming
        if applyTo.contains("**") || applyTo.contains("**/*") {
            timing = .launch
        } else if !applyTo.isEmpty {
            timing = .onDemand("when working on files matching \(applyTo.joined(separator: ", "))")
        } else if let description = Frontmatter.scalar("description", in: yaml) {
            timing = .onDemand("in VS Code’s Local agent, when it judges it relevant: \(description)")
        } else {
            timing = .onDemand("only when attached by hand")
        }
        list.add(url, scope: scope, timing: timing)
    }

    /// `@relative/path` references, which must stay inside `root`.
    private func addReferences(of file: URL, text: String, timing: LoadTiming, root: URL,
                               home: URL, into list: inout EntryList, depth: Int = 1) {
        guard depth <= 5 else { return }
        for path in ClaudeCodeResolver.importPaths(in: text) where !path.hasPrefix("/") && !path.hasPrefix("~") {
            let target = URL(fileURLWithPath: path, relativeTo: file.deletingLastPathComponent()).standardizedFileURL
            guard FileSupport.isFile(target), FileSupport.isWithin(target, root) else { continue }
            if list.contains(target) {
                if timing.isLoadedAtLaunch, let sub = list.promote(target, importedBy: file) {
                    addReferences(of: target, text: sub, timing: timing, root: root, home: home, into: &list, depth: depth + 1)
                }
                continue
            }
            guard let sub = list.add(target, scope: .imported, timing: timing, importedBy: file) else { continue }
            addReferences(of: target, text: sub, timing: timing, root: root, home: home, into: &list, depth: depth + 1)
        }
    }
}
