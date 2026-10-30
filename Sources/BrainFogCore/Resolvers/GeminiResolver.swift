import Foundation

/// Models Gemini CLI's hierarchical memory (GEMINI.md), from its source
/// (packages/core/src/utils/memoryDiscovery.ts). See docs/DESIGN.md §3.
public struct GeminiResolver: ContextResolver {
    public let agent = AgentID.geminiCLI
    public static let maxImportDepth = 5

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
        let memory = Self.privateMemoryDirectory(for: boundary ?? cwd, geminiHome: geminiHome)
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

        // 4. Below cwd: picked up when a tool touches a file there.
        let wanted = Set(names)
        for url in FileSupport.walk(cwd, maxDepth: 8, include: { wanted.contains($0.lastPathComponent) })
        where url.deletingLastPathComponent().path != cwd.path {
            let folder = String(url.deletingLastPathComponent().path.dropFirst(cwd.path.count + 1))
            add(url, .directory, .onDemand("when a tool reads or edits files in \(folder)/"))
        }

        if names != ["GEMINI.md"] {
            list.diagnostics.append(.init(.info, "context.fileName is set, so Gemini CLI looks for \(names.joined(separator: ", "))."))
        }
        return list.finish(workingDirectory: cwd, projectRoot: boundary)
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
        return geminiHome.appendingPathComponent("tmp/\(slug ?? derived)/memory")
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
