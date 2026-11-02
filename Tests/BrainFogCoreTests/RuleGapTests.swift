import Foundation
import Testing
@testable import BrainFogCore

/// The gaps DESIGN.md §6 listed, checked against codex-rs and OpenCode's
/// `session/instruction.ts`.
@Suite struct RuleGapTests {
    // MARK: Codex

    @Test func codexUntrustedProjectLoadsNoProjectAgentsMd() throws {
        let s = try Sandbox()
        try s.write(".codex/AGENTS.md", "user")
        try s.write("AGENTS.md", "project", in: s.project)
        try s.write(".codex/config.toml", "[projects.\"\(s.project.path)\"]\ntrust_level = \"untrusted\"\n")
        let ctx = CodexResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(s.names(ctx) == ["~/.codex/AGENTS.md"])
        #expect(ctx.entries.first { $0.url.lastPathComponent == "AGENTS.md" && $0.scope == .project }?.timing
            == .skipped("the project is marked untrusted in Codex"))
    }

    @Test func codexUnsetTrustStillLoadsProjectAgentsMd() throws {
        let s = try Sandbox()
        try s.write("AGENTS.md", "project", in: s.project)
        let ctx = CodexResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(s.names(ctx) == ["~/code/app/AGENTS.md"])
    }

    @Test func codexUntrustedFolderUnderTrustedRootKeepsItsConfigOff() throws {
        let s = try Sandbox()
        let pkg = s.project.appendingPathComponent("pkg")
        try s.write(".codex/config.toml", """
            [projects."\(s.project.path)"]
            trust_level = "trusted"
            [projects."\(pkg.path)"]
            trust_level = "untrusted"
            """)
        try s.write(".codex/config.toml", "project_doc_fallback_filenames = [\"NOTES.md\"]\n", in: pkg)
        try s.write("NOTES.md", "notes", in: pkg)
        let ctx = CodexResolver().resolve(workingDirectory: pkg, environment: s.env())
        // cwd's own entry wins, so neither its config nor its notes apply.
        #expect(s.names(ctx).isEmpty)
    }

    @Test func codexProjectConfigCannotMoveTheRoot() throws {
        let s = try Sandbox()
        let pkg = s.project.appendingPathComponent("pkg")
        try s.write("AGENTS.md", "root", in: s.project)
        try s.write("AGENTS.md", "pkg", in: pkg)
        try s.write(".codex/config.toml", "[projects.\"\(s.project.path)\"]\ntrust_level = \"trusted\"\n")
        try s.write(".codex/config.toml", "project_root_markers = []\n", in: s.project)
        let ctx = CodexResolver().resolve(workingDirectory: pkg, environment: s.env())
        #expect(s.names(ctx) == ["~/code/app/AGENTS.md", "~/code/app/pkg/AGENTS.md"])
    }

    @Test func codexMcpListsParentProjectConfigsReadOnly() throws {
        let s = try Sandbox()
        let pkg = s.project.appendingPathComponent("pkg")
        try s.write(".codex/config.toml", "[mcp_servers.up]\ncommand = \"u\"\n", in: s.project)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        let locations = MCPResolver.locations(for: .codex, project: pkg, env: s.env())
        let parent = locations.first { $0.file.path == s.project.appendingPathComponent(".codex/config.toml").path }
        #expect(parent?.writable == false)
        #expect(locations.last?.file.path == pkg.appendingPathComponent(".codex/config.toml").path)
        #expect(locations.last?.writable == true)
    }

    // MARK: OpenCode

    @Test func openCodeRelativeInstructionsSearchFromCwdUp() throws {
        let s = try Sandbox()
        let pkg = s.project.appendingPathComponent("pkg")
        try s.write(".config/opencode/opencode.json", #"{ "instructions": ["CONTRIBUTING.md", "docs/*.md"] }"#)
        // Next to the global config: OpenCode never reads this one.
        try s.write(".config/opencode/CONTRIBUTING.md", "wrong")
        try s.write("CONTRIBUTING.md", "root", in: s.project)
        try s.write("docs/a.md", "a", in: pkg)
        try s.write("docs/deep/b.md", "b", in: pkg)
        let ctx = OpenCodeResolver().resolve(workingDirectory: pkg, environment: s.env())
        let extra = ctx.entries.filter { $0.scope == .extra }.map { $0.url.path.replacingOccurrences(of: s.home.path + "/", with: "~/") }
        #expect(Set(extra) == ["~/code/app/CONTRIBUTING.md", "~/code/app/pkg/docs/a.md"])
    }

    @Test func openCodeInstructionsUseTheGlobalFolderWithoutProjectConfig() throws {
        let s = try Sandbox()
        try s.write(".config/opencode/opencode.json", #"{ "instructions": ["CONTRIBUTING.md"] }"#)
        try s.write(".config/opencode/CONTRIBUTING.md", "global")
        try s.write("CONTRIBUTING.md", "root", in: s.project)
        let ctx = OpenCodeResolver().resolve(workingDirectory: s.project,
                                             environment: s.env(["OPENCODE_DISABLE_PROJECT_CONFIG": "1"]))
        let extra = ctx.entries.filter { $0.scope == .extra }.map(\.url.lastPathComponent)
        #expect(extra == ["CONTRIBUTING.md"])
        #expect(ctx.entries.first { $0.scope == .extra }?.url.path.contains(".config/opencode") == true)
    }

    @Test func globWithoutDoubleStarStaysAtItsDepth() throws {
        let s = try Sandbox()
        try s.write("a.md", "a", in: s.project)
        try s.write("sub/b.md", "b", in: s.project)
        #expect(Glob.expand("*.md", base: s.project).map(\.lastPathComponent) == ["a.md"])
        #expect(Set(Glob.expand("**/*.md", base: s.project).map(\.lastPathComponent)) == ["a.md", "b.md"])
    }

    // MARK: Devin

    @Test func devinImportsOtherToolsServersReadOnlyBehindTheirSwitches() throws {
        let s = try Sandbox()
        try s.write(".cursor/mcp.json", #"{ "mcpServers": { "cur": { "command": "c" } } }"#, in: s.project)
        try s.write("opencode.json", #"{ "mcp": { "oc": { "type": "local", "command": ["o"] } } }"#, in: s.project)
        try s.write(".claude/settings.json", #"{ "mcpServers": { "cs": { "command": "s" } } }"#)
        try s.write(".codeium/windsurf/mcp_config.json", #"{ "mcpServers": { "ws": { "command": "w" } } }"#)
        let all = MCPResolver.resolve(agent: .devin, project: s.project, environment: s.env())
        #expect(Set(all.map(\.name)) == ["cur", "oc", "cs", "ws"])
        #expect(all.allSatisfy { !$0.editable && !$0.canSwitch })

        try s.write(".devin/config.json", #"{ "read_config_from": { "cursor": false, "windsurf": false, "opencode": false } }"#, in: s.project)
        let some = MCPResolver.resolve(agent: .devin, project: s.project, environment: s.env())
        #expect(some.map(\.name) == ["cs"])
    }
}
