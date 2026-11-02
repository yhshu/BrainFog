import Foundation
import Testing
@testable import BrainFogCore

/// Loading rules brought in line with each agent's docs as of 2026-11,
/// covering the desktop and IDE clients as well as the CLIs.
@Suite struct HarnessUpdateTests {
    // MARK: Claude Code

    @Test func projectInstructionsFromUserSettings() throws {
        let s = try Sandbox()
        try s.write("CLAUDE.md", "claude", in: s.project)
        try s.write("AGENTS.md", "agents", in: s.project)
        try s.write(".claude/settings.json", #"{ "pluginConfigs": { "cc-plugin-agents-md@builtin": { "options": { "instructionFiles": "claude-md-and-agents-md" } } } }"#)
        let both = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(s.names(both).filter { !$0.contains("memory") } == ["~/code/app/CLAUDE.md", "~/code/app/AGENTS.md"])

        // The older plugin ID still counts; project settings don't.
        try s.write(".claude/settings.json", #"{ "pluginConfigs": { "agents-md@builtin": { "options": { "instructionFiles": "claude-md" } } } }"#)
        try s.write(".claude/settings.json", #"{ "pluginConfigs": { "cc-plugin-agents-md@builtin": { "options": { "instructionFiles": "claude-md-and-agents-md" } } } }"#, in: s.project)
        try FileManager.default.removeItem(at: s.project.appendingPathComponent("CLAUDE.md"))
        let claudeOnly = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        let agents = try #require(claudeOnly.entries.first { $0.url.lastPathComponent == "AGENTS.md" })
        #expect(agents.timing == .skipped("Project instructions is set to claude-md"))
    }

    @Test func managedOnlyAndManagedExcludes() throws {
        let s = try Sandbox()
        let managed = s.root.appendingPathComponent("managed")
        try s.write("CLAUDE.md", "policy", in: managed)
        try s.write("managed-settings.d/10-mode.json", #"{ "pluginConfigs": { "cc-plugin-agents-md@builtin": { "options": { "instructionFiles": "managed-only" } } } }"#, in: managed)
        try s.write(".claude/CLAUDE.md", "user")
        try s.write("CLAUDE.md", "project", in: s.project)
        try s.write(".claude/rules/scoped.md", "---\npaths: [\"src/**\"]\n---\nscoped", in: s.project)
        try s.write(".claude/rules/always.md", "always", in: s.project)
        let ctx = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(s.names(ctx).filter { !$0.contains("memory") }.map { $0.hasSuffix("managed/CLAUDE.md") } == [true])
        #expect(ctx.entries.first { $0.url.lastPathComponent == "scoped.md" }?.timing
            == .onDemand("when Claude reads or edits files matching src/**"))
        #expect(ctx.entries.first { $0.url.lastPathComponent == "always.md" }?.timing
            == .skipped("Project instructions is set to managed-only"))

        try s.write("managed-settings.json", #"{ "claudeMdExcludes": ["**/code/app/CLAUDE.md"] }"#, in: managed)
        try FileManager.default.removeItem(at: managed.appendingPathComponent("managed-settings.d"))
        let excluded = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(excluded.entries.first { $0.url.path.hasSuffix("app/CLAUDE.md") }?.timing == .skipped("excluded by claudeMdExcludes"))
    }

    @Test func oversizedClaudeMdIsSkipped() throws {
        let s = try Sandbox()
        try s.write("CLAUDE.md", String(repeating: "x", count: ClaudeCodeResolver.maxFileBytes + 1), in: s.project)
        let ctx = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(ctx.entries.first { $0.url.lastPathComponent == "CLAUDE.md" }?.timing
            == .skipped("over 4 MiB, so Claude Code loads none of it"))
    }

    @Test func skillsInSubfoldersAreNotListed() throws {
        let s = try Sandbox()
        try s.write(".claude/skills/deploy/SKILL.md", "---\nname: deploy\n---\n", in: s.project)
        try s.write("apps/web/.claude/skills/deploy/SKILL.md", "---\nname: deploy\n---\n", in: s.project)
        let skills = SkillResolver.resolve(agent: .claudeCode, workingDirectory: s.project, environment: s.env())
        #expect(skills.map(\.timing) == [.launch])
    }

    @Test func claudeDesktopConfigIsReadOnly() throws {
        let s = try Sandbox()
        try s.write("Library/Application Support/Claude/claude_desktop_config.json", #"{ "mcpServers": { "fs": { "command": "fs" } } }"#)
        let servers = MCPResolver.resolve(agent: .claudeCode, project: s.project, environment: s.env())
        #expect(servers.map(\.name) == ["fs"])
        #expect(servers.first?.editable == false)
    }

    // MARK: Codex

    @Test func codexRootMarkersAndTrustedProjectConfig() throws {
        let s = try Sandbox()
        try s.write("pkg/AGENTS.md", "pkg", in: s.project)
        try s.write("AGENTS.md", "root", in: s.project)
        let pkg = s.project.appendingPathComponent("pkg")
        // No markers: cwd is the project root.
        try s.write(".codex/config.toml", "project_root_markers = []\n")
        let alone = CodexResolver().resolve(workingDirectory: pkg, environment: s.env())
        #expect(s.names(alone) == ["~/code/app/pkg/AGENTS.md"])

        // A trusted project's own config adds a fallback name.
        try s.write(".codex/config.toml", "[projects.\"\(s.project.path)\"]\ntrust_level = \"trusted\"\n")
        try s.write(".codex/config.toml", "project_doc_fallback_filenames = [\"NOTES.md\"]\n", in: s.project)
        try s.write("NOTES.md", "notes", in: s.project)
        try FileManager.default.removeItem(at: s.project.appendingPathComponent("AGENTS.md"))
        let trusted = CodexResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(s.names(trusted) == ["~/code/app/NOTES.md"])
        #expect(MCPResolver.locations(for: .codex, project: s.project, env: s.env()).last?.note == "used because the project is trusted")
    }

    @Test func codexMemoriesSwitchAndSkills() throws {
        let s = try Sandbox()
        try s.write(".codex/memories/a.md", "m")
        try s.write(".codex/config.toml", """
            [features]
            memories = true
            [memories]
            use_memories = false
            [[skills.config]]
            name = "off"
            enabled = false
            """)
        try s.write(".agents/skills/off/SKILL.md", "---\nname: off\n---\n", in: s.project)
        try s.write(".agents/skills/dup/SKILL.md", "---\nname: dup\n---\n", in: s.project)
        try s.write(".agents/skills/dup/SKILL.md", "---\nname: dup\n---\n")
        let ctx = CodexResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(ctx.entries.first { $0.url.lastPathComponent == "a.md" }?.timing == .skipped("memories.use_memories is off"))
        let skills = SkillResolver.resolve(agent: .codex, workingDirectory: s.project, environment: s.env())
        #expect(skills.filter { $0.name == "dup" }.allSatisfy { $0.timing == .launch })
        #expect(skills.first { $0.name == "off" }?.timing == .skipped("turned off by [[skills.config]] in config.toml"))
    }

    // MARK: Cursor

    @Test func cursorSkillsAreNestedAndGrouped() throws {
        let s = try Sandbox()
        try s.write(".cursor/skills/group/lint/SKILL.md", "---\nname: lint\n---\n", in: s.project)
        try s.write("web/.agents/skills/build/SKILL.md", "---\nname: build\n---\n", in: s.project)
        let skills = SkillResolver.resolve(agent: .cursor, workingDirectory: s.project, environment: s.env())
        #expect(skills.first { $0.name == "lint" }?.timing == .launch)
        #expect(skills.first { $0.name == "build" } == nil)
    }

    // MARK: Copilot

    @Test func copilotCliWalksUpForMcpFiles() throws {
        let s = try Sandbox()
        let pkg = s.project.appendingPathComponent("pkg")
        try s.write(".mcp.json", #"{ "db": { "command": "near" } }"#, in: pkg)
        try s.write(".github/mcp.json", #"{ "mcpServers": { "db": { "command": "far" }, "api": { "url": "https://x" } } }"#, in: s.project)
        try s.write(".vscode/mcp.json", #"{ "servers": { "db": { "command": "vscode" } } }"#, in: pkg)
        let servers = MCPResolver.resolve(agent: .copilot, project: pkg, environment: s.env())
        #expect(servers.map(\.command) == ["near", nil, "far", "vscode"])
        #expect(servers[0].note == "written without an mcpServers wrapper; edit it by hand")
        #expect(servers[2].note?.hasPrefix("replaced in Copilot CLI") == true)
        #expect(servers[3].note == "VS Code only; Copilot CLI doesn’t read it")
    }

    // MARK: Gemini and Antigravity

    @Test func antigravityRulesAndAgentsMd() throws {
        let s = try Sandbox()
        #expect(AgentID.geminiCLI.displayName == "Gemini")
        try s.write("AGENTS.md", "shared", in: s.project)
        try s.write(".agents/rules/always.md", "---\ntrigger: always_on\n---\nx", in: s.project)
        try s.write(".agents/rules/ts.md", "---\ntrigger: glob\nglobs: \"*.ts\"\n---\nx", in: s.project)
        try s.write(".agents/rules/bare.md", "no frontmatter", in: s.project)
        try s.write(".agent/rules/old.md", "---\ntrigger: always_on\n---\nx", in: s.project)
        try s.write(".gemini/config/rules/mine.md", "---\ntrigger: model_decision\ndescription: Swift work\n---\nx")
        let ctx = GeminiResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(s.names(ctx) == ["~/code/app/AGENTS.md", "~/code/app/.agents/rules/always.md", "~/code/app/.agent/rules/old.md"])
        #expect(ctx.entries.first { $0.url.lastPathComponent == "AGENTS.md" }?.note == GeminiResolver.antigravityOnlyAgentsNote)
        #expect(ctx.entries.first { $0.url.lastPathComponent == "ts.md" }?.timing == .onDemand("when files matching *.ts are in context"))
        #expect(ctx.entries.first { $0.url.lastPathComponent == "mine.md" }?.timing == .onDemand("when Antigravity judges it relevant: Swift work"))
        #expect(ctx.entries.first { $0.url.lastPathComponent == "bare.md" }?.timing.isLoadedAtLaunch == false)

        // Gemini CLI still needs the import, so the fix stays on offer.
        let report = SharingReport.analyze(project: s.project, contexts: [ctx], environment: s.env())
        #expect(report.statuses.first?.reads == false)
        #expect(report.statuses.first?.fix != nil)
    }

    @Test func antigravityMcpAndGeminiEnablement() throws {
        let s = try Sandbox()
        try s.write(".gemini/settings.json", #"{ "mcpServers": { "a": { "command": "a" }, "b": { "command": "b" }, "c": { "command": "c" } }, "mcp": { "allowed": ["a", "B"] } }"#)
        try s.write(".gemini/mcp-server-enablement.json", #"{ "b": { "enabled": false } }"#)
        try s.write(".gemini/config/mcp_config.json", #"{ "mcpServers": { "remote": { "serverUrl": "https://x", "disabled": true } } }"#)
        try s.write(".agents/mcp_config.json", #"{ "mcpServers": { "local": { "command": "l" } } }"#, in: s.project)
        let servers = MCPResolver.resolve(agent: .geminiCLI, project: s.project, environment: s.env())
        #expect(servers.map(\.name) == ["a", "b", "c", "remote", "local"])
        #expect(servers.map(\.enabled) == [true, false, false, false, true])
        #expect(servers[1].note?.contains("gemini mcp enable b") == true)
        #expect(servers[2].note == "not in mcp.allowed, so Gemini CLI doesn’t connect to it")
        #expect(servers[3].url == "https://x")
        #expect(servers[3].canSwitch)
    }

    @Test func antigravitySkillsAndInstallDetection() throws {
        let s = try Sandbox()
        #expect(!AgentID.geminiCLI.isInstalled(environment: s.env()))
        try FileManager.default.createDirectory(at: s.home.appendingPathComponent(".antigravity"), withIntermediateDirectories: true)
        #expect(AgentID.geminiCLI.isInstalled(environment: s.env()))

        try s.write(".gemini/config/skills/one/SKILL.md", "---\nname: one\n---\n")
        try s.write(".gemini/antigravity-cli/skills/two/SKILL.md", "---\nname: two\n---\n")
        try s.write(".agents/skills/three/SKILL.md", "---\nname: three\n---\n", in: s.project)
        let pkg = s.project.appendingPathComponent("pkg")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        let skills = SkillResolver.resolve(agent: .geminiCLI, workingDirectory: pkg, environment: s.env())
        #expect(Set(skills.map(\.name)) == ["one", "two", "three"])
        #expect(SkillResolver.newSkillFolder(named: "x", agent: .geminiCLI, project: s.project, environment: s.env()).path
            .hasSuffix("code/app/.agents/skills/x"))

    }

    // MARK: OpenCode

    @Test func openCodeMcpFollowsConfigPrecedence() throws {
        let s = try Sandbox()
        let pkg = s.project.appendingPathComponent("pkg")
        try s.write("opencode.json", #"{ "mcp": { "root": { "type": "local", "command": ["r"] } } }"#, in: s.project)
        try s.write(".opencode/opencode.json", #"{ "mcp": { "dot": { "type": "local", "command": ["d"] } } }"#, in: pkg)
        try s.write("custom.json", #"{ "mcp": { "env": { "type": "local", "command": ["e"] } }, "instructions": ["rules.md"] }"#, in: s.root)
        // Relative instructions are looked for from cwd up to the git root,
        // not next to the config file that lists them.
        try s.write("rules.md", "rules", in: s.project)
        let env = s.env(["OPENCODE_CONFIG": s.root.appendingPathComponent("custom.json").path])
        let servers = MCPResolver.resolve(agent: .openCode, project: pkg, environment: env)
        #expect(servers.map(\.name) == ["env", "root", "dot"])
        #expect(servers.allSatisfy { !$0.editable })
        let ctx = OpenCodeResolver().resolve(workingDirectory: pkg, environment: env)
        #expect(ctx.entries.contains { $0.url.lastPathComponent == "rules.md" && $0.scope == .extra })
    }

    // MARK: Devin

    @Test func devinLoadsOnlyRootFilesAtStart() throws {
        let s = try Sandbox()
        let pkg = s.project.appendingPathComponent("pkg")
        try s.write("AGENTS.md", "root", in: s.project)
        try s.write("AGENTS.md", "pkg", in: pkg)
        try s.write(".mcp.json", #"{ "mcpServers": { "cc": { "command": "cc" } } }"#, in: s.project)
        let ctx = DevinResolver().resolve(workingDirectory: pkg, environment: s.env())
        #expect(s.names(ctx) == ["~/code/app/AGENTS.md"])
        #expect(ctx.entries.first { $0.url.path.hasSuffix("pkg/AGENTS.md") }?.timing == .onDemand("when Devin works on files in pkg/"))
        let servers = MCPResolver.resolve(agent: .devin, project: s.project, environment: s.env())
        #expect(servers.map(\.note) == ["imported from Claude Code"])

        try s.write(".devin/config.json", #"{ "read_config_from": { "claude": false } }"#, in: s.project)
        #expect(MCPResolver.resolve(agent: .devin, project: s.project, environment: s.env()).isEmpty)
    }
}
