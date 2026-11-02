import Foundation

/// One set of global instructions for every agent. In a project, agents
/// share AGENTS.md; globally each keeps its own file, so they drift apart.
/// This makes one of those files the source and keeps the others in step:
/// Claude Code imports it, the rest get a generated copy that starts with
/// a marker naming the source. A copy whose text no longer matches is
/// drift, and syncing again fixes it.
public struct GlobalSyncReport: Sendable {
    public enum State: Sendable, Equatable {
        /// This file is the source.
        case source
        /// Imports or matches the source.
        case synced
        /// A generated copy that no longer matches the source: the source
        /// changed, or someone edited the copy.
        case drifted
        /// Has its own text, not tied to the source.
        case separate
        /// No file yet.
        case missing
        /// No file, and the agent isn't installed here, so none is written.
        case notInstalled
        /// Keeps global instructions outside files (Cursor's User Rules).
        case unsupported
    }

    public struct Target: Sendable, Identifiable {
        public var id: AgentID { agent }
        public var agent: AgentID
        public var file: URL?
        public var state: State
    }

    /// The file the copies were made from, if any sync has happened.
    public var source: URL?
    public var targets: [Target]

    /// Files that could be the source: every agent's global file that has text.
    public var candidates: [URL] {
        targets.compactMap { t in
            guard let file = t.file, t.agent != .claudeCode || t.state != .synced,
                  let text = FileSupport.read(file), !Self.body(of: text).isEmpty,
                  Self.marker(in: text) == nil else { return nil }
            return file
        }
    }

    // MARK: Reading the current state

    public static func analyze(environment env: ResolverEnvironment = .init()) -> GlobalSyncReport {
        let files = AgentID.ordered(environment: env).map { ($0, globalFile(for: $0, env: env)) }
        // The source is whatever the copies name.
        let source = files.lazy.compactMap { _, file in file.flatMap(FileSupport.read).flatMap(marker(in:)) }
            .first.map { URL(fileURLWithPath: FileSupport.expandTilde($0, home: env.home)).standardizedFileURL }
        let sourceText = source.flatMap(FileSupport.read).map(body(of:))

        let targets = files.map { agent, file -> Target in
            guard let file else { return Target(agent: agent, file: nil, state: .unsupported) }
            if file.standardizedFileURL == source { return Target(agent: agent, file: file, state: .source) }
            guard let text = FileSupport.read(file) else {
                return Target(agent: agent, file: file, state: agent.isInstalled(environment: env) ? .missing : .notInstalled)
            }
            if let source, links(file, to: source) { return Target(agent: agent, file: file, state: .synced) }
            if agent == .claudeCode, let source, lines(of: text).contains(importLine(source, env: env)) {
                return Target(agent: agent, file: file, state: .synced)
            }
            guard marker(in: text) != nil else { return Target(agent: agent, file: file, state: .separate) }
            return Target(agent: agent, file: file, state: body(of: text) == sourceText ? .synced : .drifted)
        }
        return GlobalSyncReport(source: source, targets: targets)
    }

    // MARK: Syncing

    /// Makes `source` the one set of global instructions: imports it into
    /// Claude Code's file and writes a marked copy for every other agent.
    /// Agents whose file already matches are left alone, and so are agents
    /// not installed here, so syncing doesn't scatter folders for them.
    public func sync(from source: URL, environment env: ResolverEnvironment = .init()) -> ChangeSet? {
        let source = source.standardizedFileURL
        guard let text = FileSupport.read(source) else { return nil }
        let content = Self.body(of: text)
        var edits: [FileEdit] = []
        var separate: [String] = []
        for target in targets {
            guard let file = target.file, target.state != .notInstalled,
                  file.standardizedFileURL != source, !Self.links(file, to: source) else { continue }
            let existing = FileSupport.read(file)
            if target.agent == .claudeCode {
                let line = Self.importLine(source, env: env)
                // An import of an earlier source (any agent's global file) is
                // replaced, so switching sources doesn't import both.
                let stale = Set((targets.compactMap(\.file) + [self.source].compactMap { $0 })
                    .map { Self.importLine($0, env: env) }).subtracting([line])
                guard let existing else { edits.append(FileEdit.append(line + "\n", to: file)); continue }
                var parts = existing.components(separatedBy: "\n")
                func bare(_ s: String) -> String { s.hasSuffix("\r") ? String(s.dropLast()) : s }
                let has = parts.contains { bare($0) == line }
                let old = parts.indices.filter { stale.contains(bare(parts[$0])) }
                if old.isEmpty {
                    if !has { edits.append(FileEdit.append(line + "\n", to: file)) }
                    continue
                }
                var drop = Set(old)
                if !has {
                    parts[old[0]] = line + (parts[old[0]].hasSuffix("\r") ? "\r" : "")
                    drop.remove(old[0])
                }
                parts = parts.indices.filter { !drop.contains($0) }.map { parts[$0] }
                edits.append(FileEdit(url: file, before: existing, after: parts.joined(separator: "\n")))
                continue
            }
            let copy = Self.header(source, env: env) + content
            if existing == copy { continue }
            if existing.map({ Self.marker(in: $0) == nil && !Self.body(of: $0).isEmpty }) == true {
                separate.append(target.agent.displayName)
            }
            edits.append(FileEdit(url: file, before: existing, after: copy))
        }
        guard !edits.isEmpty else { return nil }
        var detail = "\(Self.display(source, env)) becomes the global instructions for every agent. Claude Code imports it; the others get a copy marked as generated, which BrainFog checks for drift."
        if !separate.isEmpty {
            detail += " The global files of \(separate.joined(separator: ", ")) have their own text, which is replaced; it stays in History."
        }
        if targets.contains(where: { $0.state == .unsupported }) {
            detail += " Cursor keeps its global rules in its settings, so paste them there yourself."
        }
        return ChangeSet(title: "Use \(source.lastPathComponent) for every agent?", detail: detail, edits: edits)
    }

    /// Drift as health issues, each fixed by syncing again, or by restoring
    /// the source from a copy when it was deleted.
    public func issues(environment env: ResolverEnvironment = .init()) -> [HealthIssue] {
        guard let source else { return [] }
        let drifted = targets.filter { $0.state == .drifted }
        guard !drifted.isEmpty else { return [] }
        let names = drifted.map(\.agent.displayName).joined(separator: ", ")
        // The source is gone, so syncing can't help; bring it back from a copy.
        if FileSupport.read(source) == nil {
            guard let copy = drifted.lazy.compactMap({ t in t.file.flatMap(FileSupport.read).map { (t.agent, Self.body(of: $0)) } }).first
            else { return [] }
            return [HealthIssue(
                severity: .warning, title: "Global instructions source is missing",
                detail: "\(Self.display(source, env)) no longer exists, but \(names) still \(drifted.count == 1 ? "has a copy" : "have copies") of it. Restoring it from a copy lets syncing keep them in step again.",
                url: source, agents: drifted.map(\.agent),
                fix: ChangeSet(title: "Restore \(source.lastPathComponent)?",
                               detail: "\(Self.display(source, env)) is written again with the text of \(copy.0.displayName)’s copy.",
                               edits: [FileEdit(url: source, before: nil, after: copy.1)]))]
        }
        return [HealthIssue(
            severity: .warning, title: "Global instructions out of sync for \(names)",
            detail: "These copies of \(Self.display(source, env)) no longer match it: it changed, or a copy was edited. Syncing writes the source’s text again; edits made to a copy are kept in History.",
            url: drifted.first?.file, agents: drifted.map(\.agent), fix: sync(from: source, environment: env))]
    }

    // MARK: Files and markers

    /// Where each agent reads its global instructions from.
    static func globalFile(for agent: AgentID, env: ResolverEnvironment) -> URL? {
        func dir(_ variable: String, default path: String) -> URL {
            env.variables[variable].map { URL(fileURLWithPath: FileSupport.expandTilde($0, home: env.home)) }
                ?? env.home.appendingPathComponent(path)
        }
        return switch agent {
        case .claudeCode: env.home.appendingPathComponent(".claude/CLAUDE.md")
        case .codex: dir("CODEX_HOME", default: ".codex").appendingPathComponent("AGENTS.md")
        case .openCode:
            (env.variables["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? env.home.appendingPathComponent(".config"))
                .appendingPathComponent("opencode/AGENTS.md")
        case .cursor: nil
        case .geminiCLI: GeminiResolver.home(env).appendingPathComponent(".gemini/GEMINI.md")
        case .copilot: dir("COPILOT_HOME", default: ".copilot").appendingPathComponent("copilot-instructions.md")
        case .devin: env.home.appendingPathComponent(".config/devin/AGENTS.md")
        case .cline: env.home.appendingPathComponent(".agents/AGENTS.md")
        }
    }

    private static let prefix = "<!-- Synced by BrainFog from "

    static func header(_ source: URL, env: ResolverEnvironment) -> String {
        prefix + display(source, env) + ". Edit that file; this copy is replaced on the next sync. -->\n\n"
    }

    /// The source path a generated copy names.
    static func marker(in text: String) -> String? {
        guard text.hasPrefix(prefix), let end = text.range(of: ". Edit that file;") else { return nil }
        return String(text[text.index(text.startIndex, offsetBy: prefix.count)..<end.lowerBound])
    }

    /// The text without a marker line.
    static func body(of text: String) -> String {
        guard marker(in: text) != nil, let close = text.range(of: "-->\n") else { return text }
        var rest = text[close.upperBound...]
        if rest.hasPrefix("\n") { rest = rest.dropFirst() }
        return String(rest)
    }

    /// Lines of `text`, whatever the line endings.
    static func lines(of text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    }

    /// True when `file` is a symlink that leads to `source`.
    static func links(_ file: URL, to source: URL) -> Bool {
        file.resolvingSymlinksInPath().path == source.resolvingSymlinksInPath().path
    }

    static func importLine(_ source: URL, env: ResolverEnvironment) -> String {
        "@" + display(source, env)
    }

    static func display(_ url: URL, _ env: ResolverEnvironment) -> String {
        let home = env.home.path + "/"
        return url.path.hasPrefix(home) ? "~/" + url.path.dropFirst(home.count) : url.path
    }
}
