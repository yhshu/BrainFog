import Foundation

/// Where a file copied to another agent should land so that agent loads it
/// at launch, and how it gets there.
public struct CopyPlan: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        /// Written as a file of its own.
        case newFile
        /// Added to the end of an existing (or new) instruction file.
        case append
    }

    public var destination: URL
    public var mode: Mode
    /// Other agents that also read `destination`.
    public var sharedWith: [AgentID]
    /// Frontmatter written ahead of the text of a new file; any the source
    /// had is dropped.
    public var header = ""

    /// - Parameters:
    ///   - project: the project folder, or nil for the global layer.
    ///   - from: the agent the source file belongs to, if known.
    /// Nil when the agent has no file for that layer (Cursor's global rules).
    public init?(source: URL, to agent: AgentID, project: URL?, from: AgentID?,
                environment env: ResolverEnvironment = .init()) {
        switch agent {
        case .claudeCode:
            // Rule files load at launch unless they declare `paths`, so a
            // copy never has to edit the user's CLAUDE.md.
            let rules = (project ?? env.home).appendingPathComponent(".claude/rules")
            var name = source.lastPathComponent
            if source.pathExtension.lowercased() != "md" { name += ".md" }
            if let from { name = "\(from.rawValue)-\(name)" }
            destination = Self.unused(rules.appendingPathComponent(name))
            mode = .newFile
            sharedWith = []
        case .codex:
            let dir = project ?? env.variables["CODEX_HOME"].map {
                URL(fileURLWithPath: FileSupport.expandTilde($0, home: env.home))
            } ?? env.home.appendingPathComponent(".codex")
            // AGENTS.override.md, when present and non-empty, replaces AGENTS.md.
            let override = dir.appendingPathComponent("AGENTS.override.md")
            let hasOverride = FileSupport.read(override).map {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } ?? false
            destination = hasOverride ? override : dir.appendingPathComponent("AGENTS.md")
            mode = .append
            sharedWith = project != nil && !hasOverride ? [.openCode, .cursor] : []
        case .openCode:
            let dir = project ?? (env.variables["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
                ?? env.home.appendingPathComponent(".config")).appendingPathComponent("opencode")
            destination = dir.appendingPathComponent("AGENTS.md")
            mode = .append
            sharedWith = project != nil ? [.codex, .cursor] : []
        case .cursor:
            // An always-applied rule, so a copy never has to edit AGENTS.md.
            guard let project else { return nil }
            var name = source.deletingPathExtension().lastPathComponent
            if let from { name = "\(from.rawValue)-\(name)" }
            destination = Self.unused(project.appendingPathComponent(".cursor/rules/\(name).mdc"))
            mode = .newFile
            sharedWith = []
            header = "---\ndescription: Copied from \(source.lastPathComponent)\nalwaysApply: true\n---\n\n"
        }
    }

    /// Carries the copy out. Never overwrites: new files get a free name and
    /// appends keep the existing text.
    public func apply(text: String, source: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        switch mode {
        case .newFile:
            let body = header.isEmpty ? text : Frontmatter.split(text).body
            try (header + body).write(to: destination, atomically: true, encoding: .utf8)
        case .append:
            var existing = FileSupport.read(destination) ?? ""
            if !existing.isEmpty && !existing.hasSuffix("\n") { existing += "\n" }
            let separator = existing.isEmpty ? "" : "\n"
            let body = text.hasSuffix("\n") ? text : text + "\n"
            try (existing + separator + "<!-- Copied from \(source.path) -->\n" + body)
                .write(to: destination, atomically: true, encoding: .utf8)
        }
    }

    private static func unused(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 2
        while true {
            let candidate = url.deletingLastPathComponent().appendingPathComponent("\(base)-\(n).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
