import Foundation
import Testing
@testable import BrainFogCore

struct GlobalSyncTests {
    @Test func syncImportsIntoClaudeAndCopiesElsewhereThenSeesDrift() throws {
        let box = try Sandbox()
        let env = box.env()
        try box.write(".agents/AGENTS.md", "Answer briefly.\n")
        try box.write(".claude/CLAUDE.md", "Personal note.\n")
        try box.write(".codex/AGENTS.md", "Old codex rules.\n")

        let before = GlobalSyncReport.analyze(environment: env)
        #expect(before.source == nil)
        #expect(before.candidates.map(\.lastPathComponent).sorted() == ["AGENTS.md", "AGENTS.md", "CLAUDE.md"])

        let source = box.home.appendingPathComponent(".agents/AGENTS.md")
        try #require(before.sync(from: source, environment: env)).apply(history: box.history)

        // Claude keeps its own text and gains the import.
        #expect(FileSupport.read(box.home.appendingPathComponent(".claude/CLAUDE.md")) == "Personal note.\n\n@~/.agents/AGENTS.md\n")
        let after = GlobalSyncReport.analyze(environment: env)
        #expect(after.source == source.standardizedFileURL)
        let states = Dictionary(uniqueKeysWithValues: after.targets.map { ($0.agent, $0.state) })
        #expect(states[.cline] == .source)
        #expect(states[.claudeCode] == .synced)
        #expect(states[.codex] == .synced)
        #expect(states[.geminiCLI] == .synced)
        #expect(states[.cursor] == .unsupported)
        #expect(after.issues(environment: env).isEmpty)
        // The agents read the copy without the marker getting in the way.
        let codex = CodexResolver().resolve(workingDirectory: box.project, environment: env)
        #expect(codex.entries.contains { $0.url.lastPathComponent == "AGENTS.md" && $0.scope == .user })

        // The source changes: every copy has drifted, and one sync fixes them.
        try box.write(".agents/AGENTS.md", "Answer briefly. Cite files.\n")
        let drift = GlobalSyncReport.analyze(environment: env)
        #expect(drift.targets.filter { $0.state == .drifted }.count == 5)
        let issue = try #require(drift.issues(environment: env).first)
        try #require(issue.fix).apply(history: box.history)
        #expect(GlobalSyncReport.analyze(environment: env).targets.allSatisfy { $0.state != .drifted })
        #expect(GlobalSyncReport.analyze(environment: env).sync(from: source, environment: env) == nil)
    }
}
