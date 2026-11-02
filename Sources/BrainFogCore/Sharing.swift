import Foundation

/// Whether every agent reads the project's shared AGENTS.md, and the
/// smallest change that makes one that doesn't.
public struct SharingReport: Sendable {
    public struct Status: Sendable, Identifiable {
        public var id: AgentID { agent }
        public var agent: AgentID
        public var reads: Bool
        /// How it reads the file, or why it doesn't.
        public var detail: String
        public var fix: ChangeSet?
    }

    /// `<project>/AGENTS.md`, which may not exist yet.
    public var file: URL
    public var exists: Bool
    public var statuses: [Status]
    /// Sets up AGENTS.md when there is none: moves an existing agent
    /// file's text into it, or starts an empty one.
    public var setup: ChangeSet?

    /// One change that fixes every agent that has a fix.
    public var fixAll: ChangeSet? {
        let fixes = statuses.compactMap(\.fix)
        guard fixes.count > 1 else { return nil }
        return ChangeSet(title: "Let every agent read AGENTS.md",
                         detail: fixes.map(\.detail).joined(separator: " "),
                         edits: fixes.flatMap(\.edits))
    }

    public static func analyze(project: URL, contexts: [ResolvedContext],
                               environment env: ResolverEnvironment = .init()) -> SharingReport {
        let project = project.standardizedFileURL
        let file = project.appendingPathComponent("AGENTS.md").standardizedFileURL
        let exists = FileSupport.isFile(file)
        var statuses: [Status] = []
        // A CLAUDE.md that links to AGENTS.md reads it under its own name.
        let real = file.resolvingSymlinksInPath()
        for ctx in contexts {
            let entry = ctx.entries.first { $0.url.standardizedFileURL == file }
                ?? ctx.entries.first { $0.url.resolvingSymlinksInPath() == real }
            var status = Status(agent: ctx.agent, reads: false, detail: "")
            switch entry?.timing {
            case .launch?:
                status.reads = true
                status.detail = entry?.importedBy.map { "through an import in \($0.lastPathComponent)" }
                    ?? (entry?.url.standardizedFileURL == file ? "every session" : "through \(entry?.url.lastPathComponent ?? ""), a link to it")
            case .onDemand(let why)?:
                status.reads = true
                status.detail = why
            case .skipped(let why)?:
                status.detail = why
            case nil:
                status.detail = exists ? "doesn’t read AGENTS.md" : "no AGENTS.md yet"
            }
            // Antigravity reads AGENTS.md itself; Gemini CLI still needs the import.
            if ctx.agent == .geminiCLI, status.reads, entry?.importedBy == nil,
               entry?.note?.hasSuffix(GeminiResolver.antigravityOnlyAgentsNote) == true {
                status.reads = false
                status.detail = "Antigravity reads it, but Gemini CLI doesn’t"
            }
            if exists, !status.reads {
                status.fix = fix(for: ctx.agent, project: project, env: env)
            }
            statuses.append(status)
        }
        return SharingReport(file: file, exists: exists, statuses: statuses,
                             setup: exists ? nil : setup(project: project, contexts: contexts))
    }

    /// Imports AGENTS.md from the file the agent reads instead, where the
    /// agent supports imports.
    static func fix(for agent: AgentID, project: URL, env: ResolverEnvironment) -> ChangeSet? {
        switch agent {
        case .claudeCode:
            // The first Claude file in the project folder; Claude resolves @paths
            // relative to the file that contains them.
            let candidates = [("CLAUDE.md", "@AGENTS.md"), (".claude/CLAUDE.md", "@../AGENTS.md"),
                              ("CLAUDE.local.md", "@AGENTS.md")]
            let (name, line) = candidates.first { FileSupport.isFile(project.appendingPathComponent($0.0)) }
                ?? ("CLAUDE.md", "@AGENTS.md")
            let target = project.appendingPathComponent(name)
            if FileSupport.read(target)?.contains(line) == true { return nil }
            return ChangeSet(title: "Import AGENTS.md into \(name)",
                             detail: "Claude Code reads \(name) instead of AGENTS.md; an @import line in it brings AGENTS.md in.",
                             edits: [FileEdit.append(line + "\n", to: target)])
        case .geminiCLI:
            let target = project.appendingPathComponent("GEMINI.md")
            if FileSupport.read(target)?.contains("@./AGENTS.md") == true { return nil }
            return ChangeSet(title: "Import AGENTS.md into GEMINI.md",
                             detail: "Gemini CLI reads GEMINI.md; an @import line in it brings AGENTS.md in.",
                             edits: [FileEdit.append("@./AGENTS.md\n", to: target)])
        default:
            return nil
        }
    }

    /// When AGENTS.md is missing: move the text of the agent file the most
    /// agents depend on into AGENTS.md, and leave an import behind.
    static func setup(project: URL, contexts: [ResolvedContext]) -> ChangeSet {
        let agents = project.appendingPathComponent("AGENTS.md")
        let sources: [(String, String)] = [("CLAUDE.md", "@AGENTS.md"), ("GEMINI.md", "@./AGENTS.md")]
        for (name, line) in sources {
            let source = project.appendingPathComponent(name)
            guard let text = FileSupport.read(source),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let kept = text.hasSuffix("\n") ? text : text + "\n"
            return ChangeSet(
                title: "Move \(name) into AGENTS.md",
                detail: "AGENTS.md gets the text of \(name), which most other agents then read too. \(name) keeps a single import line, so its agent still sees the same instructions.",
                edits: [FileEdit(url: agents, before: nil, after: kept),
                        FileEdit(url: source, before: text, after: line + "\n")])
        }
        var edits = [FileEdit(url: agents, before: nil, after: "# Project instructions\n\n")]
        // Gemini CLI won't find AGENTS.md on its own.
        if contexts.contains(where: { $0.agent == .geminiCLI }) {
            edits.append(FileEdit.append("@./AGENTS.md\n", to: project.appendingPathComponent("GEMINI.md")))
        }
        return ChangeSet(title: "Create a shared AGENTS.md",
                         detail: "One instruction file at the project root that every agent reads.",
                         edits: edits)
    }
}
