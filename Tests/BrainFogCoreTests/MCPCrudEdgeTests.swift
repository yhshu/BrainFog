import Foundation
import Testing
@testable import BrainFogCore

/// Adding, copying, changing and removing MCP servers the way a user
/// clicking around the GUI might. Every test runs in a throwaway Sandbox.
@Suite struct MCPCrudEdgeTests {
    // MARK: Helpers

    private func cursorFile(_ s: Sandbox) -> URL { s.project.appendingPathComponent(".cursor/mcp.json") }
    private func codexFile(_ s: Sandbox) -> URL { s.home.appendingPathComponent(".codex/config.toml") }

    private func servers(_ s: Sandbox, _ agent: AgentID, project: Bool = true) -> [MCPServer] {
        MCPResolver.resolve(agent: agent, project: project ? s.project : nil, environment: s.env())
    }

    private func stdio(_ name: String, _ command: String = "npx", args: [String] = [],
                       env: [String: String] = [:], from agent: AgentID = .cursor, s: Sandbox) -> MCPServer {
        var server = MCPServer(agent: agent, name: name, scope: .user, file: s.home)
        server.command = command
        server.args = args
        server.env = env
        return server
    }

    private func text(_ url: URL) -> String { FileSupport.read(url) ?? "<missing>" }

    private func occurrences(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: Add / remove basics

    @Test func addingTheSameServerTwiceIsRefusedAndLeavesTheFileAlone() throws {
        let s = try Sandbox()
        let server = stdio("gh", s: s)
        try MCPEdit.add(server, to: .cursor, project: s.project, environment: s.env()).apply(history: s.history)
        let before = text(cursorFile(s))
        #expect(throws: MCPEdit.Failure.self) {
            try MCPEdit.add(server, to: .cursor, project: s.project, environment: s.env())
        }
        #expect(text(cursorFile(s)) == before)
        #expect(servers(s, .cursor).map(\.name) == ["gh"])
    }

    @Test func twoPlansMadeBeforeEitherIsAppliedDoNotBothWrite() throws {
        let s = try Sandbox()
        let first = try MCPEdit.add(stdio("a", s: s), to: .cursor, project: s.project, environment: s.env())
        let second = try MCPEdit.add(stdio("b", s: s), to: .cursor, project: s.project, environment: s.env())
        try first.apply(history: s.history)
        #expect(throws: ChangeSet.ApplyError.self) { try second.apply(history: s.history) }
        #expect(servers(s, .cursor).map(\.name) == ["a"])
    }

    @Test func addRemoveReAddLeavesAValidFile() throws {
        let s = try Sandbox()
        try s.write(".cursor/mcp.json", "{\n  \"theme\": \"dark\",\n  \"mcpServers\": {}\n}\n", in: s.project)
        let server = stdio("gh", args: ["-y", "gh-mcp"], s: s)
        for _ in 0..<3 {
            try MCPEdit.add(server, to: .cursor, project: s.project, environment: s.env()).apply(history: s.history)
            let added = try #require(servers(s, .cursor).first)
            #expect(added.name == "gh" && added.args == ["-y", "gh-mcp"])
            try MCPEdit.remove(added, environment: s.env()).apply(history: s.history)
            #expect(servers(s, .cursor).isEmpty)
        }
        let json = try #require(JSONC.object(from: text(cursorFile(s))))
        #expect((json["mcpServers"] as? [String: Any])?.isEmpty == true)
        #expect(json["theme"] as? String == "dark")
    }

    @Test func removingTheLastServerKeepsAnEmptyObjectAndEverythingElse() throws {
        let s = try Sandbox()
        let original = """
            {
              // my settings
              "theme": "dark",
              "mcpServers": {
                "only": { "command": "x", "args": ["a"] }
              },
              "trailing": [1, 2, 3]
            }

            """
        try s.write(".cursor/mcp.json", original, in: s.project)
        let only = try #require(servers(s, .cursor).first)
        try MCPEdit.remove(only, environment: s.env()).apply(history: s.history)
        let after = text(cursorFile(s))
        let json = try #require(JSONC.object(from: after))
        #expect((json["mcpServers"] as? [String: Any])?.isEmpty == true)
        #expect(after.contains("// my settings"))
        #expect(after.contains("  \"theme\": \"dark\",\n"))
        #expect(after.contains("  \"trailing\": [1, 2, 3]\n}\n"))
        #expect(!after.contains("\"only\""))
    }

    // MARK: Names

    @Test func oddNamesRoundTripThroughJson() throws {
        let s = try Sandbox()
        let names = ["my server", "数据库", "my.server", "say \"hi\"", "🚀 rocket", "a/b", "back\\slash", "it's"]
        for name in names {
            try MCPEdit.add(stdio(name, s: s), to: .cursor, project: s.project, environment: s.env()).apply(history: s.history)
        }
        #expect(Set(servers(s, .cursor).map(\.name)) == Set(names))
        for name in names {
            let server = try #require(servers(s, .cursor).first { $0.name == name }, "\(name)")
            try MCPEdit.remove(server, environment: s.env()).apply(history: s.history)
            #expect(!servers(s, .cursor).contains { $0.name == name }, "\(name)")
        }
        #expect(servers(s, .cursor).isEmpty)
        #expect(JSONC.object(from: text(cursorFile(s))) != nil)
    }

    @Test func oddNamesRoundTripThroughCodexToml() throws {
        let s = try Sandbox()
        try s.write(".codex/config.toml", "model = \"x\"\n")
        let names = ["my server", "数据库", "my.server", "🚀 rocket", "it's", "plain_name-1"]
        for name in names {
            try MCPEdit.add(stdio(name, s: s), to: .codex, project: nil, environment: s.env()).apply(history: s.history)
        }
        #expect(Set(servers(s, .codex, project: false).map(\.name)) == Set(names))
        for name in names {
            let server = try #require(servers(s, .codex, project: false).first { $0.name == name }, "\(name)")
            try MCPEdit.remove(server, environment: s.env()).apply(history: s.history)
        }
        #expect(servers(s, .codex, project: false).isEmpty)
        #expect(text(codexFile(s)).hasPrefix("model = \"x\"\n"))
    }

    @Test func codexNameWithADoubleQuoteRoundTrips() throws {
        let s = try Sandbox()
        try MCPEdit.add(stdio("say \"hi\"", s: s), to: .codex, project: nil, environment: s.env()).apply(history: s.history)
        #expect(servers(s, .codex, project: false).map(\.name) == ["say \"hi\""])
    }

    // MARK: Malformed and unusual JSON files

    @Test func malformedFileIsRefusedAndLeftAlone() throws {
        let s = try Sandbox()
        let broken = "{\n  \"mcpServers\": {\n    \"a\": { \"command\": \"a\" }\n"   // missing braces
        try s.write(".cursor/mcp.json", broken, in: s.project)
        #expect(throws: MCPEdit.Failure.self) {
            try MCPEdit.add(stdio("b", s: s), to: .cursor, project: s.project, environment: s.env())
        }
        #expect(text(cursorFile(s)) == broken)
    }

    @Test func emptyFileAcceptsANewServer() throws {
        let s = try Sandbox()
        try s.write(".cursor/mcp.json", "", in: s.project)
        try MCPEdit.add(stdio("gh", s: s), to: .cursor, project: s.project, environment: s.env()).apply(history: s.history)
        #expect(servers(s, .cursor).map(\.name) == ["gh"])
    }

    @Test func trailingCommasAreToleratedOnAddAndRemove() throws {
        let s = try Sandbox()
        try s.write(".cursor/mcp.json", """
            {
              "mcpServers": {
                "a": { "command": "a", "args": ["x",], },
                "b": { "command": "b", },
              },
            }

            """, in: s.project)
        #expect(servers(s, .cursor).map(\.name) == ["a", "b"])
        try MCPEdit.add(stdio("c", s: s), to: .cursor, project: s.project, environment: s.env()).apply(history: s.history)
        #expect(servers(s, .cursor).map(\.name) == ["a", "b", "c"])
        try MCPEdit.remove(try #require(servers(s, .cursor).first { $0.name == "b" }), environment: s.env()).apply(history: s.history)
        #expect(servers(s, .cursor).map(\.name) == ["a", "c"])
        #expect(servers(s, .cursor).first?.args == ["x"])
    }

    @Test func byteOrderMarkFileIsReadAndEditable() throws {
        let s = try Sandbox()
        try s.write(".cursor/mcp.json", "\u{FEFF}{\n  \"mcpServers\": {\n    \"a\": { \"command\": \"a\" }\n  }\n}\n", in: s.project)
        #expect(servers(s, .cursor).map(\.name) == ["a"])
        try MCPEdit.add(stdio("b", s: s), to: .cursor, project: s.project, environment: s.env()).apply(history: s.history)
        #expect(servers(s, .cursor).map(\.name) == ["a", "b"])
    }

    @Test func crlfFileWithACommentListsItsServers() throws {
        let s = try Sandbox()
        try s.write(".cursor/mcp.json",
                    "{\r\n  // servers\r\n  \"mcpServers\": {\r\n    \"a\": { \"command\": \"a\" }\r\n  }\r\n}\r\n", in: s.project)
        #expect(servers(s, .cursor).map(\.name) == ["a"])
    }

    @Test func crlfFileWithACommentAcceptsANewServerWithoutDuplicatingKeys() throws {
        let s = try Sandbox()
        try s.write(".cursor/mcp.json",
                    "{\r\n  // servers\r\n  \"mcpServers\": {\r\n    \"a\": { \"command\": \"a\" }\r\n  }\r\n}\r\n", in: s.project)
        let change = try MCPEdit.add(stdio("b", s: s), to: .cursor, project: s.project, environment: s.env())
        let after = try #require(change.edits.first?.after)
        #expect(occurrences("\"mcpServers\"", in: after) == 1)
        #expect(after.contains("// servers"))
        // Whatever reads it afterwards should see both servers.
        let json = JSONC.object(from: after.replacingOccurrences(of: "\r\n", with: "\n"))
        #expect(Set((json?["mcpServers"] as? [String: Any])?.keys.map { $0 } ?? []) == ["a", "b"])
    }

    @Test func crlfFileWithoutCommentsKeepsWindowsLineEndings() throws {
        let s = try Sandbox()
        try s.write(".cursor/mcp.json", "{\r\n  \"mcpServers\": {\r\n    \"a\": { \"command\": \"a\" }\r\n  }\r\n}\r\n", in: s.project)
        try MCPEdit.add(stdio("b", s: s), to: .cursor, project: s.project, environment: s.env()).apply(history: s.history)
        #expect(servers(s, .cursor).map(\.name) == ["a", "b"])
        let after = text(cursorFile(s))
        // No bare \n lines mixed into a CRLF file.
        #expect(occurrences("\n", in: after) == occurrences("\r\n", in: after))

        try MCPEdit.remove(try #require(servers(s, .cursor).first { $0.name == "a" }), environment: s.env()).apply(history: s.history)
        #expect(servers(s, .cursor).map(\.name) == ["b"])
        // The removed member's line goes with it rather than leaving a blank one.
        #expect(!text(cursorFile(s)).contains("\r\n    \r\n"))
    }

    @Test func nullServersObjectIsReplacedNotDuplicated() throws {
        let s = try Sandbox()
        try s.write(".cursor/mcp.json", "{\n  \"mcpServers\": null\n}\n", in: s.project)
        let change = try MCPEdit.add(stdio("gh", s: s), to: .cursor, project: s.project, environment: s.env())
        let after = try #require(change.edits.first?.after)
        #expect(occurrences("\"mcpServers\"", in: after) == 1)
        try change.apply(history: s.history)
        #expect(servers(s, .cursor).map(\.name) == ["gh"])
    }

    @Test func argumentsContainingSpacedColonsSurviveSerialisation() throws {
        let s = try Sandbox()
        let args = ["--format", "key\" : value", "a : b"]
        try MCPEdit.add(stdio("fmt", args: args, s: s), to: .cursor, project: s.project, environment: s.env()).apply(history: s.history)
        #expect(servers(s, .cursor).first?.args == args)
    }

    // MARK: JSONC comments

    @Test func openCodeCommentsSurviveAddReplaceAndRemove() throws {
        let s = try Sandbox()
        try s.write("opencode.jsonc", """
            {
              // top comment
              "$schema": "https://opencode.ai/config.json",
              /* block comment */
              "mcp": {
                // about fs
                "fs": { "type": "local", "command": ["npx", "fs"], "enabled": true }
              },
              "theme": "dark" // trailing
            }

            """, in: s.project)
        try MCPEdit.add(stdio("gh", args: ["gh-mcp"], s: s), to: .openCode, project: s.project, environment: s.env())
            .apply(history: s.history)
        let fs = try #require(servers(s, .openCode).first { $0.name == "fs" })
        var changed = fs
        changed.args = ["fs", "--root", "."]
        try MCPEdit.replace(fs, with: changed, environment: s.env()).apply(history: s.history)
        let gh = try #require(servers(s, .openCode).first { $0.name == "gh" })
        try MCPEdit.remove(gh, environment: s.env()).apply(history: s.history)

        let after = text(s.project.appendingPathComponent("opencode.jsonc"))
        for comment in ["// top comment", "/* block comment */", "// about fs", "// trailing"] {
            #expect(after.contains(comment), "\(comment)")
        }
        #expect(servers(s, .openCode).map(\.name) == ["fs"])
        #expect(servers(s, .openCode).first?.args == ["fs", "--root", "."])
    }

    // MARK: Copying between agents

    @Test func copyToAgentsWhoseFoldersDoNotExistCreatesThem() throws {
        let s = try Sandbox()
        var server = stdio("fs", args: ["--root", "."], env: ["DEBUG": "1"], s: s)
        server.agent = .claudeCode
        for agent in [AgentID.cursor, .geminiCLI, .devin, .copilot, .codex, .openCode, .cline] {
            try MCPCopy.plan(server, to: agent, project: s.project, environment: s.env()).apply(history: s.history)
            let copied = try #require(servers(s, agent).first { $0.name == "fs" }, "\(agent)")
            #expect(copied.command == "npx" && copied.args == ["--root", "."] && copied.env == ["DEBUG": "1"], "\(agent)")
        }
    }

    @Test func roundTripCursorToCodexAndBackKeepsEverything() throws {
        let s = try Sandbox()
        try s.write(".cursor/mcp.json", """
            {
              "mcpServers": {
                "gh": { "command": "npx", "args": ["-y", "@gh/mcp", "--flag=a b"], "env": { "TOKEN": "${GH_TOKEN}", "MODE": "x=y" } },
                "docs": { "url": "https://docs.example.com/mcp", "headers": { "Authorization": "Bearer ${T}" } }
              }
            }
            """)
        let original = servers(s, .cursor, project: false)
        #expect(original.count == 2)
        for server in original {
            try MCPCopy.plan(server, to: .codex, project: nil, environment: s.env()).apply(history: s.history)
        }
        for server in servers(s, .codex, project: false) {
            try MCPCopy.plan(server, to: .cursor, project: s.project, environment: s.env()).apply(history: s.history)
        }
        let back = servers(s, .cursor).filter { $0.scope == .project }
        #expect(back.map(\.name) == original.map(\.name))
        for (a, b) in zip(original, back) {
            #expect(a.command == b.command && a.args == b.args && a.env == b.env, "\(a.name)")
            #expect(a.url == b.url && a.headers == b.headers, "\(a.name)")
        }
    }

    // MARK: Editing

    @Test func editingOneServerLeavesSimilarlyNamedOnesAlone() throws {
        let s = try Sandbox()
        try s.write(".cursor/mcp.json", """
            {
              "mcpServers": {
                "gh-enterprise": { "command": "ghe" },
                "github": { "command": "github" },
                "gh": { "command": "gh" },
                "gh2": { "command": "gh2" }
              }
            }
            """, in: s.project)
        let gh = try #require(servers(s, .cursor).first { $0.name == "gh" })
        var changed = gh
        changed.command = "gh-new"
        try MCPEdit.replace(gh, with: changed, environment: s.env()).apply(history: s.history)
        let byName = Dictionary(uniqueKeysWithValues: servers(s, .cursor).map { ($0.name, $0.command) })
        #expect(byName == ["gh-enterprise": "ghe", "github": "github", "gh": "gh-new", "gh2": "gh2"])

        try MCPEdit.remove(try #require(servers(s, .cursor).first { $0.name == "gh" }), environment: s.env()).apply(history: s.history)
        #expect(servers(s, .cursor).map(\.name) == ["gh-enterprise", "gh2", "github"])
    }

    @Test func codexEditingOneServerLeavesSimilarlyNamedOnesAlone() throws {
        let s = try Sandbox()
        try s.write(".codex/config.toml", """
            [mcp_servers.gh]
            command = "gh"

            [mcp_servers.gh.env]
            A = "1"

            [mcp_servers."gh.env"]
            command = "dotted"

            [mcp_servers.gh-enterprise]
            command = "ghe"

            """)
        let gh = try #require(servers(s, .codex, project: false).first { $0.name == "gh" })
        #expect(gh.env == ["A": "1"])
        var changed = gh
        changed.command = "gh-new"
        try MCPEdit.replace(gh, with: changed, environment: s.env()).apply(history: s.history)
        let byName = Dictionary(uniqueKeysWithValues: servers(s, .codex, project: false).map { ($0.name, $0) })
        #expect(byName["gh"]?.command == "gh-new" && byName["gh"]?.env == ["A": "1"])
        #expect(byName["gh.env"]?.command == "dotted")
        #expect(byName["gh-enterprise"]?.command == "ghe")
    }

    @Test func switchingFromStdioToRemoteDropsTheCommand() throws {
        let s = try Sandbox()
        try s.write(".cursor/mcp.json", #"{ "mcpServers": { "x": { "command": "x", "args": ["a"], "env": { "K": "v" }, "timeout": 30 } } }"#, in: s.project)
        let x = try #require(servers(s, .cursor).first)
        var remote = x
        remote.command = nil
        remote.args = []
        remote.env = [:]
        remote.url = "https://x.example.com/mcp"
        try MCPEdit.replace(x, with: remote, environment: s.env()).apply(history: s.history)
        let json = try #require(JSONC.value(of: "x", at: ["mcpServers"], in: text(cursorFile(s))) as? [String: Any])
        #expect(json["command"] == nil && json["args"] == nil && json["env"] == nil)
        #expect(json["url"] as? String == "https://x.example.com/mcp")
        #expect(json["timeout"] as? Int == 30)
    }

    @Test func editingKeepsEnvValuesThatAreNotStrings() throws {
        let s = try Sandbox()
        try s.write(".cursor/mcp.json", #"{ "mcpServers": { "x": { "command": "x", "env": { "PORT": 8080, "DEBUG": true } } } }"#, in: s.project)
        let x = try #require(servers(s, .cursor).first)
        var changed = x
        changed.command = "x2"   // the user only touched the command
        try MCPEdit.replace(x, with: changed, environment: s.env()).apply(history: s.history)
        let env = JSONC.value(of: "env", at: ["mcpServers", "x"], in: text(cursorFile(s))) as? [String: Any]
        #expect(env?.keys.sorted() == ["DEBUG", "PORT"])
    }

    @Test func renamingADisabledGeminiServerKeepsItOff() throws {
        let s = try Sandbox()
        try s.write(".gemini/settings.json", """
            {
              "mcpServers": { "old": { "command": "x" } },
              "mcp": { "excluded": ["old"] }
            }
            """, in: s.project)
        let old = try #require(servers(s, .geminiCLI).first { $0.name == "old" })
        #expect(!old.enabled)
        var renamed = old
        renamed.name = "new"
        try MCPEdit.replace(old, with: renamed, environment: s.env()).apply(history: s.history)
        let after = try #require(servers(s, .geminiCLI).first { $0.name == "new" })
        #expect(!after.enabled)
    }

    @Test func renamingADisabledClaudeProjectServerKeepsItOff() throws {
        let s = try Sandbox()
        try s.write(".mcp.json", #"{ "mcpServers": { "old": { "type": "stdio", "command": "x", "args": [] } } }"#, in: s.project)
        try s.write(".claude/settings.local.json", #"{ "disabledMcpjsonServers": ["old"] }"#, in: s.project)
        let old = try #require(servers(s, .claudeCode).first { $0.name == "old" })
        #expect(!old.enabled)
        var renamed = old
        renamed.name = "new"
        try MCPEdit.replace(old, with: renamed, environment: s.env()).apply(history: s.history)
        let after = try #require(servers(s, .claudeCode).first { $0.name == "new" })
        #expect(!after.enabled)
    }

    // MARK: Claude Code project approval

    @Test func claudeProjectServerInNeitherListNeedsApproval() throws {
        let s = try Sandbox()
        try s.write(".mcp.json", #"{ "mcpServers": { "a": { "command": "a" }, "b": { "command": "b" }, "c": { "command": "c" } } }"#, in: s.project)
        try s.write(".claude/settings.json", #"{ "enabledMcpjsonServers": ["a"] }"#, in: s.project)
        try s.write(".claude/settings.local.json", #"{ "disabledMcpjsonServers": ["b"] }"#, in: s.project)
        let byName = Dictionary(uniqueKeysWithValues: servers(s, .claudeCode).map { ($0.name, $0) })
        #expect(byName["a"]?.enabled == true && byName["a"]?.needsApproval == false)
        #expect(byName["b"]?.enabled == false && byName["b"]?.needsApproval == false)
        // Not turned off, but Claude asks before running it.
        #expect(byName["c"]?.enabled == true && byName["c"]?.needsApproval == true)
    }

    @Test func enableAllProjectMcpServersApprovesEverything() throws {
        let s = try Sandbox()
        try s.write(".mcp.json", #"{ "mcpServers": { "a": { "command": "a" }, "b": { "command": "b" } } }"#, in: s.project)
        try s.write(".claude/settings.local.json", #"{ "enableAllProjectMcpServers": true, "disabledMcpjsonServers": ["b"] }"#, in: s.project)
        let byName = Dictionary(uniqueKeysWithValues: servers(s, .claudeCode).map { ($0.name, $0) })
        #expect(byName["a"]?.enabled == true && byName["a"]?.needsApproval == false)
        #expect(byName["b"]?.enabled == false && byName["b"]?.needsApproval == false)
    }

    @Test func turningOnAServerAwaitingApprovalSaysItApprovesIt() throws {
        let s = try Sandbox()
        try s.write(".mcp.json", #"{ "mcpServers": { "fs": { "command": "npx", "args": ["fs"] } } }"#, in: s.project)
        let fs = try #require(servers(s, .claudeCode).first)
        #expect(fs.needsApproval)
        let change = try MCPEdit.setEnabled(fs, true, environment: s.env())
        #expect(change.detail.contains("Approves") && change.detail.contains("without asking"))
        #expect(change.detail.contains("npx fs"))
        try change.apply(history: s.history)
        let settings = text(s.project.appendingPathComponent(".claude/settings.local.json"))
        #expect(JSONC.value(of: "enabledMcpjsonServers", at: [], in: settings) as? [String] == ["fs"])
        #expect(servers(s, .claudeCode).first?.needsApproval == false)
    }

    @Test func renamingAServerAwaitingApprovalDoesNotApproveIt() throws {
        let s = try Sandbox()
        try s.write(".mcp.json", #"{ "mcpServers": { "old": { "type": "stdio", "command": "x", "args": [] } } }"#, in: s.project)
        let old = try #require(servers(s, .claudeCode).first)
        var renamed = old
        renamed.name = "new"
        let change = try MCPEdit.replace(old, with: renamed, environment: s.env())
        #expect(change.edits.count == 1)
        try change.apply(history: s.history)
        #expect(servers(s, .claudeCode).first { $0.name == "new" }?.needsApproval == true)
    }

    // MARK: Codex TOML forms

    @Test func codexSingleQuotedDottedNameIsOneServer() throws {
        let s = try Sandbox()
        try s.write(".codex/config.toml", "[mcp_servers.'my.tool']\ncommand = \"tool\"\n")
        #expect(servers(s, .codex, project: false).map(\.name) == ["my.tool"])
    }

    @Test func codexHeaderWithATrailingCommentIsRead() throws {
        let s = try Sandbox()
        try s.write(".codex/config.toml", "[mcp_servers.docs] # the docs server\nurl = \"https://docs\"\n")
        let found = servers(s, .codex, project: false)
        #expect(found.map(\.name) == ["docs"])
        #expect(found.first?.url == "https://docs")
    }

    @Test func codexEnabledFalseWithACommentIsOff() throws {
        let s = try Sandbox()
        try s.write(".codex/config.toml", "[mcp_servers.docs]\nurl = \"https://docs\"\nenabled = false # flaky\n")
        #expect(servers(s, .codex, project: false).first?.enabled == false)
    }

    @Test func codexServersAsInlineTablesAreListed() throws {
        let s = try Sandbox()
        try s.write(".codex/config.toml", """
            [mcp_servers]
            docs = { url = "https://docs" }
            fs = { command = "npx", args = ["fs"] }
            """)
        #expect(servers(s, .codex, project: false).map(\.name).sorted() == ["docs", "fs"])
        let fs = try #require(servers(s, .codex, project: false).first { $0.name == "fs" })
        #expect(fs.command == "npx" && fs.args == ["fs"])
        // BrainFog only rewrites [mcp_servers.<name>] tables.
        #expect(!fs.editable)
    }

    @Test func codexEditKeepsAMultiLineArrayTheFormDoesNotOwn() throws {
        let s = try Sandbox()
        try s.write(".codex/config.toml", """
            [mcp_servers.fs]
            command = "fs"
            enabled_tools = [
              "read",
              "write",
            ]
            startup_timeout_sec = 30

            """)
        let fs = try #require(servers(s, .codex, project: false).first)
        var changed = fs
        changed.args = ["--root", "."]
        try MCPEdit.replace(fs, with: changed, environment: s.env()).apply(history: s.history)
        let after = text(codexFile(s))
        #expect(after.contains("\"read\",") && after.contains("\"write\","))
        #expect(after.contains("startup_timeout_sec = 30"))
        // The array still opens and closes.
        #expect(occurrences("[", in: after) - occurrences("[mcp_servers", in: after) == occurrences("]", in: after) - occurrences("[mcp_servers", in: after))
        #expect(servers(s, .codex, project: false).first?.args == ["--root", "."])
    }

    @Test func codexRemoveKeepsTheCommentThatIntroducesTheNextTable() throws {
        let s = try Sandbox()
        try s.write(".codex/config.toml", """
            [mcp_servers.a]
            command = "a"

            # Docs server, ask Pat before changing
            [mcp_servers.b]
            url = "https://b"

            """)
        let a = try #require(servers(s, .codex, project: false).first { $0.name == "a" })
        try MCPEdit.remove(a, environment: s.env()).apply(history: s.history)
        #expect(text(codexFile(s)).contains("# Docs server, ask Pat before changing"))
        #expect(servers(s, .codex, project: false).map(\.name) == ["b"])
    }

    @Test func codexRemoveLastServerKeepsOtherSettingsByteForByte() throws {
        let s = try Sandbox()
        let head = "model = \"o3\"\napproval_policy = \"never\"\n\n[profiles.fast]\nmodel = \"y\"\n"
        try s.write(".codex/config.toml", head + "\n[mcp_servers.only]\ncommand = \"x\"\nargs = [\"a\"]\n\n[mcp_servers.only.env]\nK = \"v\"\n")
        let only = try #require(servers(s, .codex, project: false).first)
        try MCPEdit.remove(only, environment: s.env()).apply(history: s.history)
        #expect(text(codexFile(s)) == head)
        try MCPEdit.add(only, to: .codex, project: nil, environment: s.env()).apply(history: s.history)
        let back = try #require(servers(s, .codex, project: false).first)
        #expect(back.command == "x" && back.args == ["a"] && back.env == ["K": "v"])
        #expect(text(codexFile(s)).hasPrefix(head))
    }

    // MARK: Secrets

    @Test func secretDetectionIgnoresPathAndVariableReferences() throws {
        let s = try Sandbox()
        // PATH is not a credential just because it contains "pat".
        let path = stdio("x", env: ["PATH": "/usr/local/bin:/usr/bin", "API_KEY": "${API_KEY}"], s: s)
        #expect(path.secretKeys.isEmpty)
        // A header that only refers to a variable is not a credential either.
        var bearer = stdio("x", s: s)
        bearer.headers = ["Authorization": "Bearer ${GITHUB_TOKEN}"]
        #expect(bearer.secretKeys.isEmpty)

        var leaky = stdio("y", env: ["GITHUB_TOKEN": "ghp_abcdefghijklmnopqrstuvwxyz0123456789"], s: s)
        leaky.headers = ["Authorization": "Bearer sk-abcdefghijklmnopqrstuvwxyz"]
        #expect(leaky.secretKeys == ["Authorization", "GITHUB_TOKEN"])
    }
}
