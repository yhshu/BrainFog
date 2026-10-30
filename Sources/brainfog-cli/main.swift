import Foundation
import BrainFogCore

// Prints what each agent loads when started in a directory.
// Usage: brainfog-cli [directory]
let dir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let home = FileManager.default.homeDirectoryForCurrentUser.path

for ctx in Resolvers.resolveAll(workingDirectory: dir) {
    print("\n\(ctx.agent.displayName) — ≈\(ctx.launchTokens) tokens at launch")
    for e in ctx.entries {
        let path = e.url.isFileURL ? e.url.path.replacingOccurrences(of: home, with: "~") : e.url.absoluteString
        let timing: String
        switch e.timing {
        case .launch: timing = "launch"
        case .onDemand(let why): timing = "on demand: \(why)"
        case .skipped(let why): timing = "skipped: \(why)"
        }
        print("  \(e.scope.displayName.padding(toLength: 12, withPad: " ", startingAt: 0)) \(path)  [\(timing)]\(e.truncated ? " ✂︎" : "")  \(e.tokens)t")
    }
    for d in ctx.diagnostics { print("  ! \(d.severity.rawValue): \(d.message)") }
}
