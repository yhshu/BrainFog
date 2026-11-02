import Foundation

/// Models Gemini CLI's hierarchical memory (GEMINI.md), from its source
/// (packages/core/src/utils/memoryDiscovery.ts), and then what Antigravity,
/// Google's agentic IDE, and Antigravity CLI (`agy`) add on top: they share
/// ~/.gemini but also read AGENTS.md and rule folders
/// (https://antigravity.google/docs/rules). See docs/DESIGN.md §3.
public struct GeminiResolver: ContextResolver {
    public let agent = AgentID.geminiCLI
    public static let maxImportDepth = 5
    /// The note on an AGENTS.md only Antigravity reads.
    static let antigravityOnlyAgentsNote = "read by Antigravity; Gemini CLI reads it only when context.fileName names it"
    /// Antigravity's limit for one rule file.
    public static let antigravityRuleBytes = 24_000

    public init() {}

    public func resolve(workingDirectory: URL, environment env: ResolverEnvironment) -> ResolvedContext {
        let cwd = workingDirectory.standardizedFileURL
        let geminiHome = Self.home(env).appendingPathComponent(".gemini")
        let settings = GeminiSettings(geminiHome: geminiHome, cwd: cwd, env: env)
        let boundary = settings.boundary(above: cwd)
        let names = settings.fileNames
        var list = EntryList(agent: agent)

        func add(_ url: URL, _ scope: Scope, _ timing: LoadTiming = .launch, note: String? = nil) {
            guard let text = list.add(url, scope: scope, timing: timing, note: note) else { return }
            if case .skipped = timing { return }
            addImports(of: url, text: text, timing: timing, depth: 1, root: boundary ?? cwd, home: env.home, into: &list)
        }

        // 1. Global, then this project's private memory; both go into the system instruction.
        for name in names {
            add(geminiHome.appendingPathComponent(name), .user, note: name == "GEMINI.md" ? "global notes the agent saves go here" : nil)
        }
        // Keyed by the folder Gemini was started in, not the repository root.
        let memory = Self.privateMemoryDirectory(for: cwd, geminiHome: geminiHome)
        let index = memory.appendingPathComponent("MEMORY.md")
        if FileSupport.isFile(index) {
            add(index, .autoMemory, note: "private notes for this project")
            for url in FileSupport.walk(memory, maxDepth: 1) where url.pathExtension == "md" && url.lastPathComponent != "MEMORY.md" {
                list.add(url, scope: .autoMemory, timing: .onDemand("read when the agent follows MEMORY.md"))
            }
        } else {
            for name in names { add(memory.appendingPathComponent(name), .autoMemory, note: "private notes for this project") }
        }

        // 2. Extensions' context.
        for dir in [geminiHome.appendingPathComponent("extensions")] {
            let folders = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for folder in folders.sorted() where !folder.hasPrefix(".") {
                let ext = dir.appendingPathComponent(folder)
                let manifest = FileSupport.read(ext.appendingPathComponent("gemini-extension.json")).flatMap(JSONC.object(from:))
                let fileNames: [String] = (manifest?["contextFileName"] as? [String])
                    ?? (manifest?["contextFileName"] as? String).map { [$0] } ?? ["GEMINI.md"]
                for name in fileNames {
                    add(ext.appendingPathComponent(name), .extra, note: "from the \(folder) extension")
                }
            }
        }

        // 3. From the boundary (the git root) down to cwd. Gemini sorts the
        // paths as strings, which is root first in all but odd cases.
        let levels = boundary.map { b in FileSupport.ancestors(of: cwd).filter { FileSupport.isWithin($0, b) } } ?? [cwd]
        let project = levels.flatMap { dir in names.map { dir.appendingPathComponent($0).standardizedFileURL } }
            .filter { FileSupport.isFile($0) }
            .sorted { $0.path < $1.path }
        for url in project {
            add(url, .project, note: url.deletingLastPathComponent().path == cwd.path ? nil : "parent directory")
        }
        if boundary == nil {
            list.diagnostics.append(.init(.info, "No .git above this folder, so Gemini CLI reads only this folder’s \(names.joined(separator: ", "))."))
        }

        if names != ["GEMINI.md"] {
            list.diagnostics.append(.init(.info, "context.fileName is set, so Gemini CLI looks for \(names.joined(separator: ", "))."))
        }

        addAntigravity(cwd: cwd, geminiHome: geminiHome, cliNames: names, into: &list)
        return list.finish(workingDirectory: cwd, projectRoot: boundary)
    }

    /// Antigravity's files beyond Gemini CLI's. Its AGENTS.md and GEMINI.md
    /// are plain always-on text; only rule files carry a trigger.
    private func addAntigravity(cwd: URL, geminiHome: URL, cliNames: [String], into list: inout EntryList) {
        let cliReadsAgents = cliNames.contains("AGENTS.md")
        let agentsNote = cliReadsAgents ? "also read by Antigravity" : Self.antigravityOnlyAgentsNote
        let config = geminiHome.appendingPathComponent("config")
        list.add(geminiHome.appendingPathComponent("AGENTS.md"), scope: .user, note: agentsNote)
        for name in ["AGENTS.md", "GEMINI.md"] {
            list.add(config.appendingPathComponent(name), scope: .user, note: "read by Antigravity")
        }
        addAntigravityRules(in: config.appendingPathComponent("rules"), scope: .user, legacy: false, into: &list)

        // The workspace and each folder above it up to the repository root.
        let root = FileSupport.gitRoot(of: cwd) ?? cwd
        for dir in FileSupport.ancestors(of: cwd) where FileSupport.isWithin(dir, root) {
            let above = dir.path == cwd.path ? nil : "parent directory"
            list.add(dir.appendingPathComponent("AGENTS.md"), scope: .project,
                     note: [above, agentsNote].compactMap { $0 }.joined(separator: " · "))
            for name in [".agents/AGENTS.md", ".agents/GEMINI.md"] {
                list.add(dir.appendingPathComponent(name), scope: .project,
                         note: [above, "read by Antigravity"].compactMap { $0 }.joined(separator: " · "))
            }
            addAntigravityRules(in: dir.appendingPathComponent(".agents/rules"), scope: .rule, legacy: false, into: &list)
            addAntigravityRules(in: dir.appendingPathComponent(".agent/rules"), scope: .rule, legacy: true, into: &list)
        }

        // Workflows, which Antigravity is moving to skills, run only when invoked.
        for (dir, scope) in [(config.appendingPathComponent("workflows"), Scope.user),
                             (cwd.appendingPathComponent(".agents/workflows"), .rule)] {
            for url in FileSupport.walk(dir, maxDepth: 0) where url.pathExtension == "md" {
                list.add(url, scope: scope,
                         timing: .onDemand("when invoked as /\(url.deletingPathExtension().lastPathComponent) in Antigravity"),
                         note: "workflow")
            }
        }
    }

    /// Direct `.md` children of a rules folder; Antigravity reads nested ones
    /// only when rules.json lists them.
    private func addAntigravityRules(in dir: URL, scope: Scope, legacy: Bool, into list: inout EntryList) {
        for url in FileSupport.walk(dir, maxDepth: 0) where url.pathExtension == "md" {
            let yaml = Frontmatter.split(FileSupport.read(url) ?? "").yaml ?? ""
            let globs = (Frontmatter.list("globs", in: yaml) + Frontmatter.list("glob", in: yaml)).flatMap(Frontmatter.commaList)
            let timing: LoadTiming = switch Frontmatter.scalar("trigger", in: yaml) {
            case "always_on": .launch
            case "model_decision":
                .onDemand("when Antigravity judges it relevant: \(Frontmatter.scalar("description", in: yaml) ?? "no description")")
            case "glob": .onDemand("when files matching \(globs.isEmpty ? "its globs" : globs.joined(separator: ", ")) are in context")
            case "manual": .onDemand("only when @-mentioned in the Antigravity app; Antigravity CLI ignores manual rules")
            default: .skipped("it has no valid trigger in its frontmatter, so Antigravity drops it")
            }
            list.add(url, scope: scope, timing: timing, note: legacy ? "older .agent/rules location, still read" : "Antigravity rule")
            if timing.isLoadedAtLaunch, FileSupport.size(url) > Self.antigravityRuleBytes {
                list.diagnostics.append(.init(.warning,
                    "\(url.lastPathComponent) is over Antigravity’s \(Self.antigravityRuleBytes.formatted())-byte limit for a rule file.", url: url))
            }
        }
    }

    static func home(_ env: ResolverEnvironment) -> URL {
        env.variables["GEMINI_CLI_HOME"].map { URL(fileURLWithPath: FileSupport.expandTilde($0, home: env.home)) } ?? env.home
    }

    /// `~/.gemini/tmp/<slug>/memory`, where the slug is recorded in
    /// `~/.gemini/projects.json`, or else derived from the folder name.
    static func privateMemoryDirectory(for root: URL, geminiHome: URL) -> URL {
        var slug: String?
        if let text = FileSupport.read(geminiHome.appendingPathComponent("projects.json")),
           let json = JSONC.object(from: text) {
            let table = json["projects"] as? [String: Any] ?? json
            slug = table[root.path] as? String
        }
        let derived = root.lastPathComponent.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return geminiHome.appendingPathComponent("tmp/\(slug ?? (derived.isEmpty ? "project" : derived))/memory")
    }

    private func addImports(of file: URL, text: String, timing: LoadTiming, depth: Int, root: URL,
                            home: URL, into list: inout EntryList) {
        for path in ClaudeCodeResolver.importPaths(in: text) {
            let target = URL(fileURLWithPath: FileSupport.expandTilde(path, home: home),
                             relativeTo: file.deletingLastPathComponent()).standardizedFileURL
            guard FileSupport.isFile(target) else {
                list.diagnostics.append(.init(.warning, "Import target not found: @\(path)", url: file))
                continue
            }
            guard depth <= Self.maxImportDepth else {
                list.diagnostics.append(.init(.warning, "@\(path) is past the \(Self.maxImportDepth)-level import limit", url: file))
                continue
            }
            if FileSupport.isWithin(file, root), !FileSupport.isWithin(target, root) {
                list.diagnostics.append(.init(.warning, "@\(path) points outside the project, so Gemini CLI won’t import it", url: file))
                continue
            }
            if list.contains(target) {
                if timing.isLoadedAtLaunch, let sub = list.promote(target, importedBy: file) {
                    addImports(of: target, text: sub, timing: timing, depth: depth + 1, root: root, home: home, into: &list)
                }
                continue
            }
            guard let sub = list.add(target, scope: .imported, timing: timing, importedBy: file) else { continue }
            addImports(of: target, text: sub, timing: timing, depth: depth + 1, root: root, home: home, into: &list)
        }
    }
}

/// The Gemini CLI settings that change which files load. Later files win:
/// system defaults, user, project, system overrides.
struct GeminiSettings {
    var fileNames = ["GEMINI.md"]
    var boundaryMarkers = [".git"]

    init(geminiHome: URL, cwd: URL, env: ResolverEnvironment) {
        let system = URL(fileURLWithPath: "/Library/Application Support/GeminiCli")
        let files = [
            env.variables["GEMINI_CLI_SYSTEM_DEFAULTS_PATH"].map(URL.init(fileURLWithPath:))
                ?? system.appendingPathComponent("system-defaults.json"),
            geminiHome.appendingPathComponent("settings.json"),
            cwd.appendingPathComponent(".gemini/settings.json"),
            env.variables["GEMINI_CLI_SYSTEM_SETTINGS_PATH"].map(URL.init(fileURLWithPath:))
                ?? system.appendingPathComponent("settings.json"),
        ]
        var extra: [String] = []
        for file in files {
            guard let text = FileSupport.read(file), let json = JSONC.object(from: text) else { continue }
            let context = json["context"] as? [String: Any] ?? [:]
            // Older settings kept the name at the top level.
            let name = context["fileName"] ?? json["contextFileName"]
            if let one = name as? String { extra = [one] }
            if let many = name as? [String] { extra = many }
            if let markers = context["memoryBoundaryMarkers"] as? [String] { boundaryMarkers = markers }
        }
        // Extra names come first; GEMINI.md is always kept.
        fileNames = extra.filter { $0 != "GEMINI.md" } + ["GEMINI.md"]
    }

    /// The nearest folder at or above `cwd` holding a boundary marker, or
    /// nil when there is none (or the markers are switched off).
    func boundary(above cwd: URL) -> URL? {
        guard !boundaryMarkers.isEmpty else { return nil }
        for dir in FileSupport.ancestors(of: cwd).reversed() {
            if dir.lastPathComponent == ".gemini" { return nil }
            if boundaryMarkers.contains(where: { FileSupport.exists(dir.appendingPathComponent($0)) }) { return dir }
        }
        return nil
    }
}

/// Gemini CLI's say over which configured servers connect: `mcp.allowed`
/// and `mcp.excluded` in its settings, then what `gemini mcp disable` (or
/// /mcp disable) wrote to ~/.gemini/mcp-server-enablement.json. Names
/// match ignoring case. From packages/cli/src/config/mcp/mcpServerEnablement.ts
/// and https://geminicli.com/docs/tools/mcp-server/.
struct GeminiMCPPolicy {
    var allowed: Set<String>?
    var excluded = Set<String>()
    var disabled = Set<String>()

    init(env: ResolverEnvironment, project: URL?) {
        let geminiHome = GeminiResolver.home(env).appendingPathComponent(".gemini")
        var files = [geminiHome.appendingPathComponent("settings.json")]
        if let project { files.append(project.appendingPathComponent(".gemini/settings.json")) }
        files.append(env.variables["GEMINI_CLI_SYSTEM_SETTINGS_PATH"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: "/Library/Application Support/GeminiCli/settings.json"))
        for file in files {
            guard let text = FileSupport.read(file), let json = JSONC.object(from: text),
                  let mcp = json["mcp"] as? [String: Any] else { continue }
            if let list = mcp["allowed"] as? [String] { allowed = Set(list.map(Self.key)) }
            if let list = mcp["excluded"] as? [String] { excluded.formUnion(list.map(Self.key)) }
        }
        // `{ "<name>": { "enabled": false } }`; enabling again deletes the entry.
        if let text = FileSupport.read(geminiHome.appendingPathComponent("mcp-server-enablement.json")),
           let json = JSONC.object(from: text) {
            for (name, value) in json where (value as? [String: Any])?["enabled"] as? Bool == false {
                disabled.insert(Self.key(name))
            }
        }
    }

    static func key(_ name: String) -> String { name.trimmingCharacters(in: .whitespaces).lowercased() }

    /// Why Gemini CLI won't connect to `name`, or nil when nothing stops it.
    func offReason(_ name: String) -> String? {
        let k = Self.key(name)
        if let allowed, !allowed.contains(k) { return "not in mcp.allowed, so Gemini CLI doesn’t connect to it" }
        if excluded.contains(k) { return "listed in mcp.excluded, so Gemini CLI doesn’t connect to it" }
        if disabled.contains(k) { return "turned off with /mcp disable; turn it back on with `gemini mcp enable \(name)`" }
        return nil
    }
}
