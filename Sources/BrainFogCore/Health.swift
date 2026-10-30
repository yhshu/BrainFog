import Foundation

/// A problem across the agents' files, with a fix when there is an obvious one.
public struct HealthIssue: Identifiable, Sendable {
    public var id: String { title + (url?.path ?? "") }
    public var severity: Diagnostic.Severity
    public var title: String
    public var detail: String
    public var url: URL?
    public var agents: [AgentID]
    public var fix: ChangeSet?
}

public enum HealthCheck {
    /// Starting context above this many tokens gets a warning.
    public static let largeContext = 20_000

    public static func run(project: URL?, contexts: [ResolvedContext], servers: [MCPServer] = []) -> [HealthIssue] {
        var issues: [HealthIssue] = []
        let files = Dictionary(grouping: contexts.flatMap(\.entries).filter { $0.url.isFileURL },
                               by: { $0.url.standardizedFileURL })

        // Credentials pasted into instructions reach every model call.
        for (url, entries) in files where entries.contains(where: { if case .skipped = $0.timing { false } else { true } }) {
            guard let text = FileSupport.read(url), let hit = secret(in: text) else { continue }
            issues.append(HealthIssue(
                severity: .error, title: "Possible credential in \(url.lastPathComponent)",
                detail: "Line \(hit) looks like an API key or token. Instruction files are sent to the model and are often committed; move it to an environment variable.",
                url: url, agents: agents(entries), fix: nil))
        }

        // Empty files cost nothing but look like they should do something.
        for (url, entries) in files where FileSupport.size(url) == 0 && entries.contains(where: { $0.timing.isLoadedAtLaunch }) {
            issues.append(HealthIssue(severity: .info, title: "\(url.lastPathComponent) is empty",
                                      detail: "It is read every session but has no instructions.",
                                      url: url, agents: agents(entries), fix: nil))
        }

        for ctx in contexts where ctx.launchTokens > largeContext {
            issues.append(HealthIssue(
                severity: .warning, title: "\(ctx.agent.displayName) starts with about \(ctx.launchTokens.formatted()) tokens",
                detail: "Long instructions crowd out the work and are followed less reliably. Move rarely needed parts into rules that load on demand, or into skills.",
                url: nil, agents: [ctx.agent], fix: nil))
        }

        if let project { issues += localFilesNotIgnored(project: project) }

        for server in servers where server.scope == .project && !server.secretKeys.isEmpty {
            issues.append(HealthIssue(
                severity: .warning, title: "MCP server “\(server.name)” has credentials in \(server.file.lastPathComponent)",
                detail: "\(server.secretKeys.joined(separator: ", ")) \(server.secretKeys.count == 1 ? "is" : "are") written into a project file that is usually committed. Use an environment variable reference instead.",
                url: server.file, agents: [server.agent], fix: nil))
        }

        return issues.sorted { $0.severity > $1.severity }
    }

    /// Personal files that would be committed by accident.
    static func localFilesNotIgnored(project: URL) -> [HealthIssue] {
        let root = FileSupport.gitRoot(of: project) ?? project
        guard FileSupport.exists(root.appendingPathComponent(".git")) else { return [] }
        let gitignore = root.appendingPathComponent(".gitignore")
        let ignored = (FileSupport.read(gitignore) ?? "").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var issues: [HealthIssue] = []
        for name in ["CLAUDE.local.md", ".claude/settings.local.json", "AGENTS.local.md", ".devin/mcp_config.local.json"] {
            let url = project.appendingPathComponent(name)
            guard FileSupport.isFile(url) else { continue }
            let rel = String(url.path.dropFirst(root.path.count + 1))
            let patterns = [name, rel, "/" + rel, "**/" + name, (name as NSString).lastPathComponent]
            if ignored.contains(where: { patterns.contains($0) }) { continue }
            issues.append(HealthIssue(
                severity: .warning, title: "\(name) isn’t in .gitignore",
                detail: "It holds your personal settings for this project and is meant to stay out of the repository.",
                url: url, agents: name.contains("AGENTS") || name.contains("devin") ? [.devin] : [.claudeCode],
                fix: ChangeSet(title: "Add \(rel) to .gitignore", detail: "Git will stop offering to commit \(rel).",
                               edits: [FileEdit.append(rel + "\n", to: gitignore)])))
        }
        return issues
    }

    /// 1-based line number of the first thing that looks like a credential.
    static func secret(in text: String) -> Int? {
        let re = try! NSRegularExpression(pattern:
            #"(sk-[A-Za-z0-9_-]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[bp]-[A-Za-z0-9-]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|glpat-[A-Za-z0-9_-]{20,})"#)
        for (n, line) in text.components(separatedBy: "\n").enumerated()
        where re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
            return n + 1
        }
        return nil
    }

    private static func agents(_ entries: [ContextEntry]) -> [AgentID] {
        AgentID.allCases.filter { a in entries.contains { $0.agent == a } }
    }
}

/// Line-by-line differences, for previewing a change.
public enum LineDiff {
    public enum Line: Sendable, Hashable {
        case same(String), added(String), removed(String)
    }

    public static func diff(_ a: String, _ b: String) -> [Line] {
        let x = a.isEmpty ? [] : a.components(separatedBy: "\n")
        let y = b.isEmpty ? [] : b.components(separatedBy: "\n")
        // Longest common subsequence; instruction files are small.
        guard x.count * y.count <= 4_000_000 else {
            return x.map { .removed($0) } + y.map { .added($0) }
        }
        var lcs = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in stride(from: x.count - 1, through: 0, by: -1) {
            for j in stride(from: y.count - 1, through: 0, by: -1) {
                lcs[i][j] = x[i] == y[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [Line] = []
        var i = 0, j = 0
        while i < x.count || j < y.count {
            if i < x.count, j < y.count, x[i] == y[j] { out.append(.same(x[i])); i += 1; j += 1 }
            else if i < x.count, j == y.count || lcs[i + 1][j] >= lcs[i][j + 1] { out.append(.removed(x[i])); i += 1 }
            else { out.append(.added(y[j])); j += 1 }
        }
        return out
    }
}
