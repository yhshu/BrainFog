import Foundation
import Testing
@testable import BrainFogCore

/// Regressions in the code that reads and rewrites config, rule and pack
/// files: TOML strings and tables, JSONC comments, credential stripping,
/// symlinks, line endings and the global sync import.
@Suite struct WritePathFixTests {
    private func codexFile(_ s: Sandbox) -> URL { s.home.appendingPathComponent(".codex/config.toml") }

    private func codex(_ s: Sandbox) -> [MCPServer] {
        MCPResolver.resolve(agent: .codex, project: nil, environment: s.env())
    }

    // MARK: Codex TOML

    @Test func tomlEscapesAreDecodedAndSurviveAnUnchangedEdit() throws {
        let s = try Sandbox()
        try s.write(".codex/config.toml", #"""
            [mcp_servers.a]
            command = 'C:\tools\a.exe'
            env = { SEP = "a\tb", NAME = "caf\u00e9", Q = "say \"hi\"", BIG = "\U0001F600" }

            """#)
        let a = try #require(codex(s).first)
        #expect(a.command == #"C:\tools\a.exe"#)
        #expect(a.env == ["SEP": "a\tb", "NAME": "café", "Q": "say \"hi\"", "BIG": "😀"])
        try MCPEdit.replace(a, with: a, environment: s.env()).apply(history: s.history)
        #expect(try #require(codex(s).first).env == a.env)
        // Written back as valid TOML: no raw tab inside the string.
        let text = try #require(FileSupport.read(codexFile(s)))
        #expect(text.contains(#"SEP = "a\tb""#))
        #expect(CodexMCPToml.quote("x\ny\u{1}") == #""x\ny\u0001""#)
    }

    @Test func codexEditKeepsSubTablesAndCommentsAndRemoveDropsThem() throws {
        let s = try Sandbox()
        try s.write(".codex/config.toml", """
            [mcp_servers.a]
            # started by hand
            command = "a"
            startup_timeout_sec = 5

            [mcp_servers.a.env_http_headers]
            X_KEY = "KEY_VAR"

            [mcp_servers.a.tools.search]
            approval = "never"

            [other]
            x = 1

            """)
        let a = try #require(codex(s).first)
        var changed = a
        changed.name = "b"
        changed.args = ["--fast"]
        try MCPEdit.replace(a, with: changed, environment: s.env()).apply(history: s.history)
        #expect(FileSupport.read(codexFile(s)) == """
            [mcp_servers.b]
            command = "a"
            args = ["--fast"]
            # started by hand
            startup_timeout_sec = 5

            [mcp_servers.b.env_http_headers]
            X_KEY = "KEY_VAR"

            [mcp_servers.b.tools.search]
            approval = "never"

            [other]
            x = 1

            """)
        let b = try #require(codex(s).first)
        try MCPEdit.remove(b, environment: s.env()).apply(history: s.history)
        #expect(FileSupport.read(codexFile(s)) == "[other]\nx = 1\n")
    }

    @Test func codexEnvSubTableKeepsUnchangedEntriesAndComments() throws {
        let s = try Sandbox()
        try s.write(".codex/config.toml", """
            [mcp_servers.a]
            command = "a"

            [mcp_servers.a.env]
            # local dev
            PORT = 8080 # default
            MODE = "fast"
            OLD = "x"

            [other]
            x = 1

            """)
        let a = try #require(codex(s).first)
        #expect(a.env == ["PORT": "8080", "MODE": "fast", "OLD": "x"])
        var changed = a
        changed.env = ["PORT": "8080", "MODE": "slow", "NEW": "y"]
        try MCPEdit.replace(a, with: changed, environment: s.env()).apply(history: s.history)
        #expect(FileSupport.read(codexFile(s)) == """
            [mcp_servers.a]
            command = "a"

            [mcp_servers.a.env]
            # local dev
            PORT = 8080 # default
            MODE = "slow"
            NEW = "y"

            [other]
            x = 1

            """)
        var cleared = try #require(codex(s).first)
        cleared.env = [:]
        try MCPEdit.replace(try #require(codex(s).first), with: cleared, environment: s.env()).apply(history: s.history)
        #expect(FileSupport.read(codexFile(s)) == "[mcp_servers.a]\ncommand = \"a\"\n\n[other]\nx = 1\n")
    }

    @Test func codexInlineEnvKeepsRawValuesOfUnchangedEntries() throws {
        let s = try Sandbox()
        try s.write(".codex/config.toml", "[mcp_servers.a]\ncommand = \"a\"\nenv = { PORT = 8080, \"B\" = 'q' }\n")
        let a = try #require(codex(s).first)
        var changed = a
        changed.env = ["PORT": "8080", "B": "q", "C": "z"]
        changed.args = ["-v"]
        try MCPEdit.replace(a, with: changed, environment: s.env()).apply(history: s.history)
        #expect(FileSupport.read(codexFile(s))
                == "[mcp_servers.a]\ncommand = \"a\"\nargs = [\"-v\"]\nenv = { PORT = 8080, \"B\" = 'q', C = \"z\" }\n")
    }

    @Test func codexEditsKeepWindowsLineEndings() throws {
        let s = try Sandbox()
        try s.write(".codex/config.toml", "[mcp_servers.a]\r\ncommand = \"a\"\r\n\r\n[mcp_servers.a.env]\r\nPORT = 8080\r\n")
        let a = try #require(codex(s).first)
        #expect(a.env == ["PORT": "8080"])
        var changed = a
        changed.env = ["PORT": "9090"]
        try MCPEdit.replace(a, with: changed, environment: s.env()).apply(history: s.history)
        #expect(FileSupport.read(codexFile(s)) == "[mcp_servers.a]\r\ncommand = \"a\"\r\n\r\n[mcp_servers.a.env]\r\nPORT = \"9090\"\r\n")

        let b = try #require(codex(s).first)
        try MCPEdit.setEnabled(b, false, environment: s.env()).apply(history: s.history)
        #expect(FileSupport.read(codexFile(s))?.contains("command = \"a\"\r\nenabled = false\r\n") == true)

        var added = MCPServer(agent: .codex, name: "c", scope: .user, file: codexFile(s))
        added.command = "c"
        try MCPEdit.add(added, to: .codex, file: codexFile(s), project: nil, environment: s.env()).apply(history: s.history)
        try MCPEdit.remove(try #require(codex(s).first { $0.name == "a" }), environment: s.env()).apply(history: s.history)
        #expect(FileSupport.read(codexFile(s)) == "[mcp_servers.c]\r\ncommand = \"c\"\r\n")
    }

    @Test func multiLineArrayWithABracketInAStringReadsToItsEnd() throws {
        let s = try Sandbox()
        try s.write(".codex/config.toml", "[mcp_servers.a]\ncommand = \"a\"\nargs = [\n  \"--match=]\",\n  \"y\", # a ] here too\n]\nenabled = false\n")
        let a = try #require(codex(s).first)
        #expect(a.args == ["--match=]", "y"])
        #expect(!a.enabled)
        var changed = a
        changed.command = "b"
        try MCPEdit.replace(a, with: changed, environment: s.env()).apply(history: s.history)
        let after = try #require(codex(s).first)
        #expect(after.command == "b" && after.args == ["--match=]", "y"] && !after.enabled)
        #expect(!(FileSupport.read(codexFile(s)) ?? "").contains("\"y\", #"))
    }

    @Test func arrayOfTablesHeaderEndsTheServerTable() throws {
        let s = try Sandbox()
        try s.write(".codex/config.toml", "[mcp_servers.a]\ncommand = \"a\"\n\n[[skills.config]]\nenabled = false\n")
        let a = try #require(codex(s).first)
        #expect(a.enabled)
        try MCPEdit.remove(a, environment: s.env()).apply(history: s.history)
        #expect(FileSupport.read(codexFile(s)) == "[[skills.config]]\nenabled = false\n")
    }

    // MARK: JSONC comments

    @Test func insertingIntoACommentOnlyObjectKeepsTheComment() throws {
        let text = "{\n  \"mcpServers\": {\n    // add servers here\n  }\n}\n"
        let out = try #require(JSONC.inserting(member: "a", value: ["command": "x"], intoObject: "mcpServers", in: text))
        #expect(out.contains("// add servers here"))
        #expect((JSONC.object(from: out)?["mcpServers"] as? [String: Any])?["a"] != nil)
    }

    @Test func removingTheLastMemberKeepsThePreviousMembersComment() throws {
        let text = "{\n  \"mcpServers\": {\n    \"a\": 1, // the first\n    \"b\": 2\n  }\n}\n"
        let out = try #require(JSONC.removing(member: "b", fromObject: "mcpServers", in: text))
        #expect(out == "{\n  \"mcpServers\": {\n    \"a\": 1 // the first\n  }\n}\n")
        // On one line, the comma and the member still go together.
        #expect(JSONC.removing(member: "b", at: [], in: #"{"a": 1, "b": 2}"#) == #"{"a": 1}"#)
    }

    // MARK: Packs

    @Test func packStripsHeaderArgsUrlPasswordsAndCookies() throws {
        let s = try Sandbox()
        let file = s.project.appendingPathComponent(".cursor/mcp.json")
        var local = MCPServer(agent: .cursor, name: "db", scope: .project, file: file)
        local.command = "mcp"
        local.args = ["--header", "Authorization: Bearer abc123", "--header=Proxy-Authorization: Basic Zm9v",
                      "postgres://admin:hunter2@db/app", "--header", "Accept: text/plain"]
        local.env = ["DATABASE_URL": "postgres://admin:hunter2@db/app", "PLAIN_URL": "https://example.com/x"]
        var remote = MCPServer(agent: .cursor, name: "web", scope: .project, file: file)
        remote.url = "https://user:s3cret@example.com/mcp"
        remote.headers = ["Cookie": "sid=xyz", "Set-Cookie": "a=b"]
        #expect(local.secretKeys == ["DATABASE_URL"])
        #expect(remote.secretKeys == ["Cookie", "Set-Cookie"])

        let pack = AgentPack.export(project: s.project, contexts: [], servers: [local, remote], environment: s.env())
        let json = String(decoding: try pack.encoded(), as: UTF8.self)
        for secret in ["abc123", "Zm9v", "hunter2", "s3cret", "sid=xyz", "a=b"] { #expect(!json.contains(secret)) }
        let db = try #require(pack.servers.first { $0.name == "db" })
        #expect(db.args == ["--header", "Authorization: ${AUTHORIZATION}", "--header=Proxy-Authorization: ${PROXY_AUTHORIZATION}",
                            "postgres://admin:${URL_PASSWORD}@db/app", "--header", "Accept: text/plain"])
        #expect(db.env == ["DATABASE_URL": "${DATABASE_URL}", "PLAIN_URL": "https://example.com/x"])
        #expect(pack.servers.first { $0.name == "web" }?.url == "https://user:${URL_PASSWORD}@example.com/mcp")
        #expect(pack.stripped.count == 7)
    }

    @Test func symlinkedSkillFolderIsPackedUnderItsOwnPath() throws {
        let s = try Sandbox()
        try s.write("shared/deploy/SKILL.md", "---\nname: deploy\ndescription: Ship\n---\nSteps\n")
        try s.write("shared/deploy/scripts/run.sh", "echo hi\n")
        try FileManager.default.createDirectory(at: s.project.appendingPathComponent(".claude/skills"),
                                                withIntermediateDirectories: true)
        let link = s.project.appendingPathComponent(".claude/skills/deploy")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: s.home.appendingPathComponent("shared/deploy"))
        #expect(FileSupport.walk(link).map(\.lastPathComponent) == ["SKILL.md", "run.sh"])
        #expect(FileSupport.walk(link).allSatisfy { $0.path.hasPrefix(link.standardizedFileURL.path + "/") })

        var ctx = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        ctx.skills = SkillResolver.resolve(agent: .claudeCode, workingDirectory: s.project, environment: s.env())
        let pack = AgentPack.export(project: s.project, contexts: [ctx], servers: [], environment: s.env())
        #expect(pack.files.map(\.path).sorted() == [".claude/skills/deploy/SKILL.md", ".claude/skills/deploy/scripts/run.sh"])
    }

    // MARK: Global sync

    @Test func switchingTheSyncSourceReplacesClaudesImport() throws {
        let s = try Sandbox()
        let env = s.env()
        try s.write(".claude/CLAUDE.md", "Mine.\n")
        try s.write(".codex/AGENTS.md", "Codex rules.\n")
        try s.write(".gemini/settings.json", "{}\n")
        let codex = s.home.appendingPathComponent(".codex/AGENTS.md")
        try #require(GlobalSyncReport.analyze(environment: env).sync(from: codex, environment: env)).apply(history: s.history)
        let claude = s.home.appendingPathComponent(".claude/CLAUDE.md")
        #expect(FileSupport.read(claude) == "Mine.\n\n@~/.codex/AGENTS.md\n")

        try s.write(".gemini/GEMINI.md", "Gemini rules.\n")
        let gemini = s.home.appendingPathComponent(".gemini/GEMINI.md")
        try #require(GlobalSyncReport.analyze(environment: env).sync(from: gemini, environment: env)).apply(history: s.history)
        #expect(FileSupport.read(claude) == "Mine.\n\n@~/.gemini/GEMINI.md\n")
    }

    // MARK: Rule frontmatter

    @Test func settingAFieldKeepsWindowsLineEndings() throws {
        let field = try #require(RuleFormat.cursor.fields.first { $0.key == "description" })
        let text = "---\r\ndescription: old\r\nalwaysApply: false\r\n---\r\nBody\r\nMore\r\n"
        #expect(RuleFormat.setting(field, to: "new", in: text)
                == "---\r\ndescription: new\r\nalwaysApply: false\r\n---\r\nBody\r\nMore\r\n")
    }

    @Test func scalarsThatWouldParseAsOtherTypesAreQuoted() throws {
        let field = try #require(RuleFormat.cursor.fields.first { $0.key == "description" })
        for value in ["yes", "true", "null", "123", "1.5", "~"] {
            let out = RuleFormat.setting(field, to: value, in: "---\n---\nBody\n")
            #expect(out.contains("description: \"\(value)\""))
            #expect(RuleFormat.value(of: field, in: out) == value)
        }
        #expect(RuleFormat.setting(field, to: "plain", in: "---\n---\n").contains("description: plain\n"))
    }

    // MARK: Writing through links

    @Test func writingThroughADanglingSymlinkKeepsTheLink() throws {
        let s = try Sandbox()
        let link = s.home.appendingPathComponent("CLAUDE.md")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "notes/AGENTS.md")
        try FileWriter.write("hello\n", to: link, history: s.history)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "notes/AGENTS.md")
        #expect(FileSupport.read(s.home.appendingPathComponent("notes/AGENTS.md")) == "hello\n")
    }
}
