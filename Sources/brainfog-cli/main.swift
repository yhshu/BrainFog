import Foundation
import BrainFogCore

// Prints what each agent loads when started in a directory, its MCP
// servers, whether every agent reads AGENTS.md, and any health issues.
// Usage: brainfog-cli [directory]
let dir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
    .standardizedFileURL
let home = FileManager.default.homeDirectoryForCurrentUser.path

func show(_ url: URL) -> String {
    url.isFileURL ? url.path.replacingOccurrences(of: home, with: "~") : url.absoluteString
}

let contexts = Resolvers.resolveAll(workingDirectory: dir)
var allServers: [MCPServer] = []
for ctx in contexts {
    print("\n\(ctx.agent.displayName) — ≈\(ctx.launchTokens) tokens at launch")
    for e in ctx.entries {
        let timing: String
        switch e.timing {
        case .launch: timing = "launch"
        case .onDemand(let why): timing = "on demand: \(why)"
        case .skipped(let why): timing = "skipped: \(why)"
        }
        print("  \(e.scope.displayName.padding(toLength: 12, withPad: " ", startingAt: 0)) \(show(e.url))  [\(timing)]\(e.truncated ? " ✂︎" : "")  \(e.tokens)t")
    }
    let servers = MCPResolver.resolve(agent: ctx.agent, project: dir)
    allServers += servers
    for s in servers {
        print("  MCP \(s.name) (\(s.scope.displayName.lowercased()))\(s.enabled ? "" : " [off]")  \(s.summary)  ← \(show(s.file))")
    }
    for d in ctx.diagnostics { print("  ! \(d.severity.rawValue): \(d.message)") }
}

let sharing = SharingReport.analyze(project: dir, contexts: contexts)
print("\nAGENTS.md \(sharing.exists ? "is read by" : "does not exist;") "
      + sharing.statuses.filter(\.reads).map(\.agent.displayName).joined(separator: ", "))
for s in sharing.statuses where !s.reads {
    print("  ✗ \(s.agent.displayName): \(s.detail)\(s.fix.map { " → fix: \($0.title)" } ?? "")")
}

let issues = HealthCheck.run(project: dir, contexts: contexts, servers: allServers) + HealthCheck.unreadable(project: dir)
if !issues.isEmpty { print("\nHealth") }
for issue in issues {
    print("  \(issue.severity.rawValue): \(issue.title)\(issue.fix.map { " → fix: \($0.title)" } ?? "")")
}
