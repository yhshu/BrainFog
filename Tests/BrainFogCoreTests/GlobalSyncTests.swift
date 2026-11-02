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
        // Gemini is installed but has no global file yet; Copilot, OpenCode and Devin aren't installed.
        try box.write(".gemini/settings.json", "{}\n")

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
        #expect(states[.devin] == .notInstalled)
        // Nothing is written for an agent that isn't installed.
        #expect(!FileManager.default.fileExists(atPath: box.home.appendingPathComponent(".config/devin").path))
        #expect(!FileManager.default.fileExists(atPath: box.home.appendingPathComponent(".copilot").path))
        #expect(after.issues(environment: env).isEmpty)
        // The agents read the copy without the marker getting in the way.
        let codex = CodexResolver().resolve(workingDirectory: box.project, environment: env)
        #expect(codex.entries.contains { $0.url.lastPathComponent == "AGENTS.md" && $0.scope == .user })

        // The source changes: every copy has drifted, and one sync fixes them.
        try box.write(".agents/AGENTS.md", "Answer briefly. Cite files.\n")
        let drift = GlobalSyncReport.analyze(environment: env)
        #expect(drift.targets.filter { $0.state == .drifted }.map(\.agent) == [.codex, .geminiCLI])
        let issue = try #require(drift.issues(environment: env).first)
        try #require(issue.fix).apply(history: box.history)
        #expect(GlobalSyncReport.analyze(environment: env).targets.allSatisfy { $0.state != .drifted })
        #expect(GlobalSyncReport.analyze(environment: env).sync(from: source, environment: env) == nil)
    }

    @Test func installedAgentsComeFirstInOrder() throws {
        let box = try Sandbox()
        try box.write(".cursor/mcp.json", "{}\n")
        try box.write(".config/opencode/opencode.json", "{}\n")
        try box.write("Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/state.json", "{}\n")
        let env = box.env()
        #expect(AgentID.allCases.filter { $0.isInstalled(environment: env) } == [.cursor, .openCode, .cline])
        #expect(AgentID.ordered(environment: env) == [.cursor, .openCode, .cline, .claudeCode, .codex, .copilot, .geminiCLI, .devin])
        // CODEX_HOME moves Codex's folder.
        try box.write("elsewhere/config.toml", "")
        var moved = env
        moved.variables["CODEX_HOME"] = box.home.appendingPathComponent("elsewhere").path
        #expect(AgentID.codex.isInstalled(environment: moved))
        #expect(Resolvers.all.map(\.agent) == AgentID.allCases)
    }
}
