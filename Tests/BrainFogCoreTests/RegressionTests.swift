import Foundation
import Testing
@testable import BrainFogCore

/// Bugs found in the 2026-11 review.
struct RegressionTests {
    @Test func foldedDescriptionReadsInFullInTheForm() {
        let text = "---\nname: x\ndescription: >\n  Ships a\n  release.\n---\nBody\n"
        let field = RuleFormat.Field(key: "description", label: "", kind: .text, help: "")
        #expect(RuleFormat.value(of: field, in: text) == "Ships a release.")
    }

    @Test func editingACopilotServerKeepsItsToolList() throws {
        let s = try Sandbox()
        try s.write(".copilot/mcp-config.json", #"{"mcpServers":{"gh":{"type":"local","command":"gh-mcp","args":["a"],"tools":["get_issue"]}}}"#)
        let gh = try #require(MCPResolver.resolve(agent: .copilot, project: nil, environment: s.env()).first)
        var changed = gh
        changed.args = ["b"]
        try MCPEdit.replace(gh, with: changed, environment: s.env()).apply(history: s.history)
        let text = try #require(FileSupport.read(s.home.appendingPathComponent(".copilot/mcp-config.json")))
        #expect(text.contains("get_issue") && !text.contains("\"*\""))
    }

    @Test func aServerThatWasOffStaysOffThroughAPack() throws {
        let s = try Sandbox()
        try s.write(".cursor/mcp.json", "{}\n")
        try s.write(".devin/mcp_config.json", #"{"mcpServers":{"db":{"command":"db-mcp","disabled":true}}}"#, in: s.project)
        let servers = MCPResolver.resolve(agent: .devin, project: s.project, environment: s.env())
        #expect(servers.first?.enabled == false)
        let pack = try AgentPack.decode(AgentPack.export(project: s.project, contexts: [], servers: servers,
                                                         environment: s.env()).encoded())
        let other = s.home.appendingPathComponent("code/other")
        try FileManager.default.createDirectory(at: other.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try pack.importChange(project: other, environment: s.env()).apply(history: s.history)
        let imported = MCPResolver.resolve(agent: .devin, project: other, environment: s.env())
        #expect(imported.map(\.name) == ["db"] && imported.first?.enabled == false)
    }

    @Test func geminiPrivateMemoryIsKeyedByTheStartFolder() throws {
        let s = try Sandbox()
        let sub = s.project.appendingPathComponent("web")
        try s.write(".gemini/tmp/web/memory/MEMORY.md", "web notes")
        try s.write(".gemini/tmp/app/memory/MEMORY.md", "root notes")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let ctx = GeminiResolver().resolve(workingDirectory: sub, environment: s.env())
        #expect(ctx.entries.contains { $0.scope == .autoMemory && $0.url.path.contains("/tmp/web/") })
        #expect(!ctx.entries.contains { $0.url.path.contains("/tmp/app/") })
    }

    @Test func clineGlobalAgentsSkillWinsAndOnlyTheRootIsSearched() throws {
        let s = try Sandbox()
        let skill = "---\nname: ship\ndescription: d\n---\n"
        try s.write(".agents/skills/ship/SKILL.md", skill)
        try s.write(".cline/skills/ship/SKILL.md", skill)
        try s.write(".clinerules/skills/ship/SKILL.md", skill, in: s.project)
        try s.write("pkg/.cline/skills/deep/SKILL.md", "---\nname: deep\ndescription: d\n---\n", in: s.project)
        let found = SkillResolver.resolve(agent: .cline, workingDirectory: s.project.appendingPathComponent("pkg"), environment: s.env())
        let active = found.filter { $0.timing.isLoadedAtLaunch }
        #expect(active.map(\.name) == ["ship"])
        #expect(active.first?.url.path.contains("/.agents/") == true)
    }

    @Test func devinAgentTriggerIsDecidedByTheAgent() throws {
        let s = try Sandbox()
        try s.write(".devin/rules/a.md", "---\ntrigger: agent\ndescription: API work\n---\nRule\n", in: s.project)
        let ctx = DevinResolver().resolve(workingDirectory: s.project, environment: s.env())
        let rule = try #require(ctx.entries.first { $0.url.lastPathComponent == "a.md" })
        guard case .onDemand(let why) = rule.timing else { Issue.record("not on demand"); return }
        #expect(why.contains("relevant"))
    }
}
