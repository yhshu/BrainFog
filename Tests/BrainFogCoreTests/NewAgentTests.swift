import Foundation
import Testing
@testable import BrainFogCore

@Suite struct GeminiTests {
    @Test func globalProjectAndSubdirectoriesOnDemand() throws {
        let s = try Sandbox()
        try s.write(".gemini/GEMINI.md", "global")
        try s.write("GEMINI.md", "root @./docs/style.md", in: s.project)
        try s.write("docs/style.md", "style", in: s.project)
        try s.write("pkg/GEMINI.md", "pkg", in: s.project)
        try s.write("code/GEMINI.md", "above the git root")
        let ctx = GeminiResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(s.names(ctx) == ["~/.gemini/GEMINI.md", "~/code/app/GEMINI.md", "~/code/app/docs/style.md"])
        #expect(!ctx.entries.contains { $0.url.path.hasSuffix("pkg/GEMINI.md") })
        #expect(!ctx.entries.contains { $0.url.path.hasSuffix("code/GEMINI.md") })
    }

    @Test func contextFileNameAddsNames() throws {
        let s = try Sandbox()
        try s.write(".gemini/settings.json", #"{ "context": { "fileName": "AGENTS.md" } }"#)
        try s.write("AGENTS.md", "shared", in: s.project)
        try s.write("GEMINI.md", "gemini", in: s.project)
        let ctx = GeminiResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(s.names(ctx) == ["~/code/app/AGENTS.md", "~/code/app/GEMINI.md"])
    }

    @Test func privateProjectMemory() throws {
        let s = try Sandbox()
        try s.write(".gemini/tmp/app/memory/MEMORY.md", "notes")
        try s.write(".gemini/tmp/app/memory/topic.md", "t")
        let ctx = GeminiResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(s.names(ctx) == ["~/.gemini/tmp/app/memory/MEMORY.md"])
        #expect(ctx.entries.contains { $0.url.lastPathComponent == "topic.md" && !$0.timing.isLoadedAtLaunch })
    }
}

@Suite struct CopilotTests {
    @Test func standardLocationsAndPathSpecificInstructions() throws {
        let s = try Sandbox()
        try s.write(".github/copilot-instructions.md", "repo", in: s.project)
        try s.write(".github/instructions/all.instructions.md", "---\napplyTo: \"**\"\n---\nall", in: s.project)
        try s.write(".github/instructions/ts.instructions.md", "---\napplyTo: \"**/*.ts\"\n---\nts", in: s.project)
        try s.write("AGENTS.md", "shared", in: s.project)
        try s.write("CLAUDE.md", "claude", in: s.project)
        try s.write("pkg/AGENTS.md", "nested", in: s.project)
        let ctx = CopilotResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(s.names(ctx) == ["~/code/app/.github/copilot-instructions.md", "~/code/app/AGENTS.md",
                                 "~/code/app/CLAUDE.md", "~/code/app/.github/instructions/all.instructions.md"])
        let ts = try #require(ctx.entries.first { $0.url.lastPathComponent == "ts.instructions.md" })
        #expect(ts.timing == .onDemand("when working on files matching **/*.ts"))
        #expect(!ctx.entries.contains { $0.url.path.hasSuffix("pkg/AGENTS.md") })
    }
}

@Suite struct DevinTests {
    @Test func alwaysOnFilesRulesAndImports() throws {
        let s = try Sandbox()
        try s.write(".config/devin/AGENTS.md", "global")
        try s.write(".devin/rules/always.md", "---\ntrigger: always_on\n---\nx", in: s.project)
        try s.write(".devin/rules/ts.md", "---\ntrigger: glob\nglobs: \"**/*.ts\"\n---\nx", in: s.project)
        try s.write(".windsurf/rules/old.md", "---\ntrigger: always_on\n---\nx", in: s.project)
        try s.write(".cursor/rules/style.mdc", "---\nalwaysApply: true\n---\nx", in: s.project)
        try s.write("AGENTS.md", "root", in: s.project)
        try s.write("CLAUDE.md", "claude", in: s.project)
        try s.write("api/AGENTS.md", "api", in: s.project)
        let ctx = DevinResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(s.names(ctx) == ["~/.config/devin/AGENTS.md", "~/code/app/AGENTS.md", "~/code/app/CLAUDE.md",
                                 "~/code/app/.devin/rules/always.md", "~/code/app/.windsurf/rules/old.md",
                                 "~/code/app/.cursor/rules/style.mdc"])
        #expect(!ctx.entries.contains { $0.url.path.hasSuffix("api/AGENTS.md") })
    }

    @Test func readConfigFromTurnsSourcesOff() throws {
        let s = try Sandbox()
        try s.write(".devin/config.json", #"{ "read_config_from": { "claude": false, "cursor": false } }"#, in: s.project)
        try s.write("CLAUDE.md", "claude", in: s.project)
        try s.write(".cursor/rules/style.mdc", "---\nalwaysApply: true\n---\nx", in: s.project)
        let ctx = DevinResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(s.names(ctx).isEmpty)
    }
}

@Suite struct ClineTests {
    @Test func searchOrderNamesAndLegacyFiles() throws {
        let s = try Sandbox()
        try s.write("Documents/Cline/Rules/style.md", "global style")
        try s.write(".clinerules/style.md", "project style", in: s.project)
        try s.write(".clinerules/api.md", "---\npaths:\n  - \"src/api/**\"\n---\napi", in: s.project)
        try s.write(".clinerules/off.md", "---\ndisabled: true\n---\nx", in: s.project)
        try s.write(".clinerules/workflows/release.md", "steps", in: s.project)
        try s.write(".cursorrules", "cursor", in: s.project)
        try s.write("AGENTS.md", "shared", in: s.project)
        let ctx = ClineResolver().resolve(workingDirectory: s.project, environment: s.env())
        // Sorted by name; the global style.md, found later, replaces the project one.
        #expect(s.names(ctx) == ["~/code/app/.clinerules/api.md", "~/Documents/Cline/Rules/style.md",
                                 "~/code/app/AGENTS.md"])
        #expect(!ctx.entries.contains { $0.url.lastPathComponent == "release.md" })
        let cursor = try #require(ctx.entries.first { $0.url.lastPathComponent == ".cursorrules" })
        #expect(!cursor.timing.isLoadedAtLaunch)
    }
}

@Suite struct MCPTests {
    @Test func readsEachFormat() throws {
        let s = try Sandbox()
        try s.write(".cursor/mcp.json", #"{ "mcpServers": { "gh": { "command": "npx", "args": ["-y", "gh-mcp"], "env": { "GITHUB_TOKEN": "ghp_abcdefghijklmnopqrstuvwxyz0123456789" } } } }"#, in: s.project)
        try s.write(".codex/config.toml", """
            model = "x"

            [mcp_servers.docs]
            url = "https://example.com/mcp"

            [mcp_servers."local.tool"]
            command = "tool"
            args = [
              "--a",
              "--b",
            ]

            [mcp_servers."local.tool".env]
            KEY = "v"
            """)
        try s.write("opencode.jsonc", """
            {
              // servers
              "mcp": { "fs": { "type": "local", "command": ["npx", "fs"], "enabled": false } }
            }
            """, in: s.project)
        let cursor = MCPResolver.resolve(agent: .cursor, project: s.project, environment: s.env())
        #expect(cursor.map(\.name) == ["gh"] && cursor[0].args == ["-y", "gh-mcp"])
        #expect(cursor[0].secretKeys == ["GITHUB_TOKEN"])

        let codex = MCPResolver.resolve(agent: .codex, project: nil, environment: s.env())
        #expect(codex.map(\.name) == ["docs", "local.tool"])
        #expect(codex[0].url == "https://example.com/mcp")
        #expect(codex[1].args == ["--a", "--b"] && codex[1].env == ["KEY": "v"])

        let open = MCPResolver.resolve(agent: .openCode, project: s.project, environment: s.env())
        #expect(open.first?.command == "npx" && open.first?.args == ["fs"] && open.first?.enabled == false)
    }

    @Test func copyKeepsCommentsAndOrder() throws {
        let s = try Sandbox()
        try s.write("opencode.jsonc", "{\n  // keep me\n  \"theme\": \"dark\",\n  \"mcp\": {\n    \"a\": { \"type\": \"remote\", \"url\": \"https://a\" }\n  }\n}\n", in: s.project)
        var server = MCPServer(agent: .cursor, name: "gh", scope: .project, file: s.project)
        server.command = "npx"
        server.args = ["gh-mcp"]
        let change = try MCPCopy.plan(server, to: .openCode, project: s.project, environment: s.env())
        try change.apply(history: s.history)
        let text = try #require(FileSupport.read(s.project.appendingPathComponent("opencode.jsonc")))
        #expect(text.contains("// keep me") && text.contains("\"theme\": \"dark\""))
        let names = MCPResolver.resolve(agent: .openCode, project: s.project, environment: s.env()).map(\.name)
        #expect(names == ["a", "gh"])
        let gh = MCPResolver.resolve(agent: .openCode, project: s.project, environment: s.env()).last
        #expect(gh?.command == "npx" && gh?.args == ["gh-mcp"])

        // A second copy of the same name is refused.
        #expect(throws: MCPCopy.Failure.self) {
            try MCPCopy.plan(server, to: .openCode, project: s.project, environment: s.env())
        }
    }

    @Test func copyToCodexAppendsATable() throws {
        let s = try Sandbox()
        try s.write(".codex/config.toml", "model = \"x\"\n")
        var server = MCPServer(agent: .cursor, name: "my.server", scope: .user, file: s.home)
        server.url = "https://example.com/mcp"
        server.headers = ["Authorization": "Bearer ${TOKEN}"]
        try MCPCopy.plan(server, to: .codex, project: nil, environment: s.env()).apply(history: s.history)
        let codex = MCPResolver.resolve(agent: .codex, project: nil, environment: s.env())
        #expect(codex.map(\.name) == ["my.server"])
        #expect(codex[0].url == "https://example.com/mcp" && codex[0].headers["Authorization"] == "Bearer ${TOKEN}")
    }

    @Test func createsMissingFilesAndKeys() throws {
        let s = try Sandbox()
        var server = MCPServer(agent: .claudeCode, name: "fs", scope: .project, file: s.project)
        server.command = "fs"
        try MCPCopy.plan(server, to: .cursor, project: s.project, environment: s.env()).apply(history: s.history)
        try s.write(".gemini/settings.json", "{\n  \"theme\": \"x\"\n}\n", in: s.project)
        try MCPCopy.plan(server, to: .geminiCLI, project: s.project, environment: s.env()).apply(history: s.history)
        #expect(MCPResolver.resolve(agent: .cursor, project: s.project, environment: s.env()).map(\.name) == ["fs"])
        #expect(MCPResolver.resolve(agent: .geminiCLI, project: s.project, environment: s.env()).map(\.name) == ["fs"])
        #expect(FileSupport.read(s.project.appendingPathComponent(".gemini/settings.json"))?.contains("\"theme\": \"x\"") == true)
    }

    @Test func claudeGlobalIsNeverWritten() throws {
        let s = try Sandbox()
        let server = MCPServer(agent: .cursor, name: "fs", scope: .user, file: s.home)
        #expect(throws: MCPCopy.Failure.self) {
            try MCPCopy.plan(server, to: .claudeCode, project: nil, environment: s.env())
        }
    }
}

@Suite struct MCPEditTests {
    @Test func removeKeepsTheRestOfTheJson() throws {
        let s = try Sandbox()
        let original = """
            {
              // servers for this repo
              "mcpServers": {
                "a": { "command": "a" },
                "b": {
                  "command": "b",
                  "args": ["x,y", "}"]
                },
                "c": { "url": "https://c" }
              },
              "other": true
            }

            """
        try s.write(".cursor/mcp.json", original, in: s.project)
        func servers() -> [MCPServer] { MCPResolver.resolve(agent: .cursor, project: s.project, environment: s.env()) }
        let b = try #require(servers().first { $0.name == "b" })
        #expect(b.editable)
        try MCPEdit.remove(b, environment: s.env()).apply(history: s.history)
        #expect(servers().map(\.name) == ["a", "c"])
        let text = try #require(FileSupport.read(s.project.appendingPathComponent(".cursor/mcp.json")))
        #expect(text.contains("// servers for this repo") && text.contains("\"other\": true"))
        #expect(!text.contains("x,y"))

        // The last member takes the comma before it.
        try MCPEdit.remove(try #require(servers().first { $0.name == "c" }), environment: s.env()).apply(history: s.history)
        try MCPEdit.remove(try #require(servers().first { $0.name == "a" }), environment: s.env()).apply(history: s.history)
        #expect(servers().isEmpty)
        #expect(JSONC.object(from: FileSupport.read(s.project.appendingPathComponent(".cursor/mcp.json"))!)?["other"] as? Bool == true)
    }

    @Test func replaceRenamesAndChangesInPlace() throws {
        let s = try Sandbox()
        try s.write(".mcp.json", #"{ "mcpServers": { "fs": { "type": "stdio", "command": "fs", "args": [] } } }"#, in: s.project)
        let old = try #require(MCPResolver.resolve(agent: .claudeCode, project: s.project, environment: s.env()).first { $0.name == "fs" })
        var new = old
        new.name = "files"
        new.args = ["--root", "."]
        try MCPEdit.replace(old, with: new, environment: s.env()).apply(history: s.history)
        let after = MCPResolver.resolve(agent: .claudeCode, project: s.project, environment: s.env()).filter { $0.scope == .project }
        #expect(after.map(\.name) == ["files"] && after[0].args == ["--root", "."])
    }

    @Test func codexTablesAreRemovedWithTheirEnv() throws {
        let s = try Sandbox()
        try s.write(".codex/config.toml", """
            model = "x"

            [mcp_servers.a]
            command = "a"

            [mcp_servers.a.env]
            K = "v"

            [mcp_servers.b]
            url = "https://b"

            [profiles.fast]
            model = "y"

            """)
        let a = try #require(MCPResolver.resolve(agent: .codex, project: nil, environment: s.env()).first { $0.name == "a" })
        try MCPEdit.remove(a, environment: s.env()).apply(history: s.history)
        let text = try #require(FileSupport.read(s.home.appendingPathComponent(".codex/config.toml")))
        #expect(text == "model = \"x\"\n\n[mcp_servers.b]\nurl = \"https://b\"\n\n[profiles.fast]\nmodel = \"y\"\n")
    }

    @Test func claudeUserServersAreNotEditable() throws {
        let s = try Sandbox()
        try s.write(".claude.json", #"{ "mcpServers": { "x": { "command": "x" } } }"#)
        let x = try #require(MCPResolver.resolve(agent: .claudeCode, project: nil, environment: s.env()).first)
        #expect(!x.editable)
        #expect(throws: MCPEdit.Failure.self) { try MCPEdit.remove(x, environment: s.env()) }
    }

    @Test func addToAChosenFile() throws {
        let s = try Sandbox()
        var server = MCPServer(agent: .copilot, name: "docs", scope: .user, file: s.home)
        server.url = "https://docs"
        let files = MCPResolver.editableFiles(for: .copilot, project: s.project, environment: s.env())
        #expect(files.map(\.scope) == [.project, .user])
        try MCPEdit.add(server, to: .copilot, file: files[1].file, project: s.project, environment: s.env()).apply(history: s.history)
        let found = MCPResolver.resolve(agent: .copilot, project: s.project, environment: s.env())
        #expect(found.map(\.name) == ["docs"] && found[0].scope == .user && found[0].transport == "http")
    }
}

@Suite struct MCPSwitchTests {
    func servers(_ s: Sandbox, _ agent: AgentID, project: Bool = true) -> [MCPServer] {
        MCPResolver.resolve(agent: agent, project: project ? s.project : nil, environment: s.env())
    }

    @Test func codexEnabledKey() throws {
        let s = try Sandbox()
        try s.write(".codex/config.toml", "[mcp_servers.a]\ncommand = \"a\"\nstartup_timeout_sec = 30\n\n[mcp_servers.b]\nurl = \"https://b\"\n")
        let a = try #require(servers(s, .codex, project: false).first)
        try MCPEdit.setEnabled(a, false, environment: s.env()).apply(history: s.history)
        #expect(servers(s, .codex, project: false).map(\.enabled) == [false, true])
        try MCPEdit.setEnabled(try #require(servers(s, .codex, project: false).first), true, environment: s.env()).apply(history: s.history)
        #expect(FileSupport.read(s.home.appendingPathComponent(".codex/config.toml"))
                == "[mcp_servers.a]\ncommand = \"a\"\nstartup_timeout_sec = 30\n\n[mcp_servers.b]\nurl = \"https://b\"\n")
    }

    @Test func clineDisabledKeyKeepsOtherFields() throws {
        let s = try Sandbox()
        try s.write(".cline/data/settings/cline_mcp_settings.json",
                    #"{ "mcpServers": { "x": { "command": "x", "autoApprove": ["read"], "timeout": 60 } } }"#)
        let x = try #require(servers(s, .cline, project: false).first)
        try MCPEdit.setEnabled(x, false, environment: s.env()).apply(history: s.history)
        let off = try #require(servers(s, .cline, project: false).first)
        #expect(!off.enabled)
        // Editing keeps what the form doesn't show.
        var changed = off
        changed.args = ["--fast"]
        changed.enabled = true
        try MCPEdit.replace(off, with: changed, environment: s.env()).apply(history: s.history)
        let text = try #require(FileSupport.read(s.home.appendingPathComponent(".cline/data/settings/cline_mcp_settings.json")))
        let entry = try #require(JSONC.value(of: "x", at: ["mcpServers"], in: text) as? [String: Any])
        #expect(entry["autoApprove"] as? [String] == ["read"] && entry["timeout"] as? Int == 60)
        #expect(entry["disabled"] == nil && entry["args"] as? [String] == ["--fast"])
    }

    @Test func claudeProjectServersUseSettingsLocal() throws {
        let s = try Sandbox()
        try s.write(".mcp.json", #"{ "mcpServers": { "fs": { "command": "fs" } } }"#, in: s.project)
        try s.write(".claude/settings.local.json", "{\n  \"permissions\": { \"allow\": [] }\n}\n", in: s.project)
        let fs = try #require(servers(s, .claudeCode).first { $0.name == "fs" })
        #expect(fs.canSwitch && fs.enabled)
        let change = try MCPEdit.setEnabled(fs, false, environment: s.env())
        #expect(change.edits.map(\.url.lastPathComponent) == ["settings.local.json"])
        try change.apply(history: s.history)
        #expect(servers(s, .claudeCode).first { $0.name == "fs" }?.enabled == false)
        let text = try #require(FileSupport.read(s.project.appendingPathComponent(".claude/settings.local.json")))
        #expect(text.contains("\"permissions\""))
        try MCPEdit.setEnabled(try #require(servers(s, .claudeCode).first { $0.name == "fs" }), true, environment: s.env()).apply(history: s.history)
        #expect(servers(s, .claudeCode).first { $0.name == "fs" }?.enabled == true)
    }

    @Test func geminiUsesMcpExcluded() throws {
        let s = try Sandbox()
        try s.write(".gemini/settings.json", "{\n  \"theme\": \"x\",\n  \"mcpServers\": { \"g\": { \"command\": \"g\" } }\n}\n", in: s.project)
        let g = try #require(servers(s, .geminiCLI).first)
        try MCPEdit.setEnabled(g, false, environment: s.env()).apply(history: s.history)
        #expect(servers(s, .geminiCLI).first?.enabled == false)
        try MCPEdit.setEnabled(try #require(servers(s, .geminiCLI).first), true, environment: s.env()).apply(history: s.history)
        #expect(servers(s, .geminiCLI).first?.enabled == true)
        let text = try #require(FileSupport.read(s.project.appendingPathComponent(".gemini/settings.json")))
        #expect(!text.contains("excluded"))
    }

    @Test func openCodeEnabledKeyInPlace() throws {
        let s = try Sandbox()
        try s.write("opencode.json", #"{ "mcp": { "o": { "type": "local", "command": ["o"], "enabled": true } } }"#, in: s.project)
        try MCPEdit.setEnabled(try #require(servers(s, .openCode).first), false, environment: s.env()).apply(history: s.history)
        #expect(servers(s, .openCode).first?.enabled == false)
    }

    @Test func cursorCannotSwitch() throws {
        let s = try Sandbox()
        try s.write(".cursor/mcp.json", #"{ "mcpServers": { "c": { "command": "c" } } }"#, in: s.project)
        let c = try #require(servers(s, .cursor).first)
        #expect(!c.canSwitch)
        #expect(throws: MCPEdit.Failure.self) { try MCPEdit.setEnabled(c, false, environment: s.env()) }
    }

    @Test func codexEditKeepsUnknownKeysAndPlace() throws {
        let s = try Sandbox()
        try s.write(".codex/config.toml", "[mcp_servers.a]\ncommand = \"a\"\nargs = [\n  \"x\",\n]\ntool_timeout_sec = 5\n\n[mcp_servers.b]\nurl = \"https://b\"\n")
        let a = try #require(servers(s, .codex, project: false).first)
        var changed = a
        changed.args = ["y"]
        try MCPEdit.replace(a, with: changed, environment: s.env()).apply(history: s.history)
        #expect(FileSupport.read(s.home.appendingPathComponent(".codex/config.toml"))
                == "[mcp_servers.a]\ncommand = \"a\"\nargs = [\"y\"]\ntool_timeout_sec = 5\n\n[mcp_servers.b]\nurl = \"https://b\"\n")
    }
}

@Suite struct SharingTests {
    @Test func claudeImportsAgentsMdAfterFix() throws {
        let s = try Sandbox()
        try s.write("AGENTS.md", "shared", in: s.project)
        try s.write("CLAUDE.md", "claude", in: s.project)
        let contexts = Resolvers.all.map { $0.resolve(workingDirectory: s.project, environment: s.env()) }
        let report = SharingReport.analyze(project: s.project, contexts: contexts, environment: s.env())
        let claude = try #require(report.statuses.first { $0.agent == .claudeCode })
        #expect(!claude.reads)
        try #require(claude.fix).apply(history: s.history)

        let after = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(after.entries.contains { $0.url.lastPathComponent == "AGENTS.md" && $0.timing.isLoadedAtLaunch })
    }

    @Test func setupMovesClaudeMdIntoAgentsMd() throws {
        let s = try Sandbox()
        try s.write("CLAUDE.md", "be terse\n", in: s.project)
        let contexts = Resolvers.all.map { $0.resolve(workingDirectory: s.project, environment: s.env()) }
        let report = SharingReport.analyze(project: s.project, contexts: contexts, environment: s.env())
        try #require(report.setup).apply(history: s.history)
        #expect(FileSupport.read(s.project.appendingPathComponent("AGENTS.md")) == "be terse\n")
        #expect(FileSupport.read(s.project.appendingPathComponent("CLAUDE.md")) == "@AGENTS.md\n")
        let again = Resolvers.all.map { $0.resolve(workingDirectory: s.project, environment: s.env()) }
        let readers = SharingReport.analyze(project: s.project, contexts: again, environment: s.env())
            .statuses.filter(\.reads).map(\.agent)
        #expect(readers.contains(.claudeCode) && readers.contains(.codex) && readers.contains(.devin))
    }

    @Test func refusesWhenTheFileChangedSincePlanning() throws {
        let s = try Sandbox()
        try s.write("CLAUDE.md", "one\n", in: s.project)
        let edit = FileEdit.append("two\n", to: s.project.appendingPathComponent("CLAUDE.md"))
        try s.write("CLAUDE.md", "changed\n", in: s.project)
        #expect(throws: ChangeSet.ApplyError.self) {
            try ChangeSet(title: "", detail: "", edits: [edit]).apply(history: s.history)
        }
    }
}

@Suite struct HealthTests {
    @Test func localFileNotIgnoredHasAFix() throws {
        let s = try Sandbox()
        try s.write("CLAUDE.local.md", "mine", in: s.project)
        let issues = HealthCheck.localFilesNotIgnored(project: s.project)
        try #require(issues.first?.fix).apply(history: s.history)
        #expect(FileSupport.read(s.project.appendingPathComponent(".gitignore")) == "CLAUDE.local.md\n")
        #expect(HealthCheck.localFilesNotIgnored(project: s.project).isEmpty)
    }

    @Test func findsCredentials() {
        #expect(HealthCheck.secret(in: "fine\nkey: sk-ant-api03-abcdefghijklmnopqrstuvwx") == 2)
        #expect(HealthCheck.secret(in: "use $OPENAI_API_KEY") == nil)
    }
}

@Suite struct WritingTests {
    @Test func historyKeepsDistinctVersions() throws {
        let s = try Sandbox()
        let file = s.project.appendingPathComponent("AGENTS.md")
        try s.write("AGENTS.md", "v1", in: s.project)
        s.history.observe(file)
        s.history.observe(file)
        try FileWriter.write("v2", to: file, history: s.history)
        let versions = s.history.versions(of: file)
        #expect(versions.count == 2)
        #expect(versions.map(\.origin) == [.brainFog, .observed])
        #expect(s.history.text(of: versions[1]) == "v1")
    }

    @Test func frontmatterFieldsRoundTrip() throws {
        let cursor = RuleFormat.cursor
        var text = "Body\n"
        text = RuleFormat.setting(cursor.fields[0], to: "true", in: text)
        #expect(text == "---\nalwaysApply: true\n---\n\nBody\n")
        text = RuleFormat.setting(cursor.fields[1], to: "*.ts, src/**", in: text)
        #expect(RuleFormat.value(of: cursor.fields[1], in: text) == "*.ts, src/**")

        let claude = RuleFormat.claude
        var rule = "---\npaths:\n  - \"a/**\"\ndescription: x\n---\nBody"
        rule = RuleFormat.setting(claude.fields[0], to: "b/**, c/*.ts", in: rule)
        #expect(rule == "---\npaths:\n  - \"b/**\"\n  - \"c/*.ts\"\ndescription: x\n---\nBody")
        rule = RuleFormat.setting(claude.fields[0], to: "", in: rule)
        #expect(rule == "---\ndescription: x\n---\nBody")
    }

    @Test func detectsFormatsByLocation() {
        #expect(RuleFormat.detect(URL(fileURLWithPath: "/p/.cursor/rules/a.mdc"))?.name == "Cursor rule")
        #expect(RuleFormat.detect(URL(fileURLWithPath: "/p/.github/instructions/a.instructions.md"))?.name == "Copilot instructions")
        #expect(RuleFormat.detect(URL(fileURLWithPath: "/p/AGENTS.md")) == nil)
    }

    @Test func lineDiff() {
        #expect(LineDiff.diff("a\nb\nc", "a\nx\nc") == [.same("a"), .removed("b"), .added("x"), .same("c")])
    }
}
