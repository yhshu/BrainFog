import Foundation
import Testing
@testable import BrainFogCore

struct PackTests {
    /// Exports a project with a rule, a skill, Claude memory and a server
    /// holding a key, then imports it into an empty second project.
    @Test func roundTripsIntoAnotherProjectWithoutCredentials() throws {
        let box = try Sandbox()
        let env = box.env()
        try box.write("CLAUDE.md", "Use tabs. Key sk-ant-abcdefghijklmnopqrstuvwxyz0123\n", in: box.project)
        try box.write(".claude/rules/api.md", "Version every endpoint.\n", in: box.project)
        try box.write(".claude/skills/release/SKILL.md", "---\nname: release\ndescription: Ship it\n---\nSteps\n", in: box.project)
        try box.write(".claude/skills/release/scripts/tag.sh", "git tag\n", in: box.project)
        let key = ClaudeCodeResolver.projectKey(for: box.project)
        try box.write(".claude/projects/\(key)/memory/MEMORY.md", "- prefers small PRs\n")
        try box.write(".mcp.json", #"{"mcpServers":{"api":{"command":"api-mcp","env":{"API_TOKEN":"sk-live-0123456789abcdef"}}}}"#,
                      in: box.project)

        var ctx = ClaudeCodeResolver().resolve(workingDirectory: box.project, environment: env)
        ctx.skills = SkillResolver.resolve(agent: .claudeCode, workingDirectory: box.project, environment: env)
        let servers = MCPResolver.resolve(agent: .claudeCode, project: box.project, environment: env)
        let pack = try AgentPack.decode(AgentPack.export(project: box.project, contexts: [ctx], servers: servers,
                                                         environment: env).encoded())

        #expect(pack.files.map(\.path).sorted() == [".claude/rules/api.md", ".claude/skills/release/SKILL.md",
                                                     ".claude/skills/release/scripts/tag.sh", "CLAUDE.md", "MEMORY.md"])
        #expect(pack.files.first { $0.path == "MEMORY.md" }?.base == .claudeMemory)
        #expect(pack.files.first { $0.path == "CLAUDE.md" }?.text.contains("sk-ant") == false)
        #expect(pack.servers.first?.env["API_TOKEN"] == "${API_TOKEN}")
        #expect(pack.stripped.count == 2)

        let other = box.home.appendingPathComponent("code/other")
        try FileManager.default.createDirectory(at: other.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try pack.importChange(project: other, environment: env).apply(history: box.history)
        #expect(FileSupport.read(other.appendingPathComponent(".claude/skills/release/scripts/tag.sh")) == "git tag\n")
        let memory = box.home.appendingPathComponent(".claude/projects/\(ClaudeCodeResolver.projectKey(for: other))/memory/MEMORY.md")
        #expect(FileSupport.read(memory) == "- prefers small PRs\n")
        let imported = MCPResolver.resolve(agent: .claudeCode, project: other, environment: env)
        #expect(imported.map(\.name) == ["api"])

        // A second import has nothing left to write.
        #expect(pack.importChange(project: other, environment: env).edits.isEmpty)
    }
}
