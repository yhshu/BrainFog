import Foundation
import SQLite3
import Testing
@testable import BrainFogCore

/// Odd-but-plausible user behaviour around History/undo, .agentpack
/// export/import, global-instruction sync, project discovery and the
/// Codex memory store.
@Suite struct HistoryPackSyncEdgeTests {

    // MARK: History and undo

    @Test func undoingAnUndoBringsTheEditBack() throws {
        let s = try Sandbox()
        let h = s.history
        let file = s.project.appendingPathComponent("CLAUDE.md")
        try s.write("CLAUDE.md", "A\n", in: s.project)
        h.observe(file)
        try FileWriter.write("B\n", to: file, history: h)

        let edit = try #require(h.changes(to: [file]).first)
        try #require(h.undo(edit)).apply(history: h)
        #expect(FileSupport.read(file) == "A\n")

        // The undo is itself the newest change; undoing it restores B.
        let undoChange = try #require(h.changes(to: [file]).first)
        #expect(h.text(of: undoChange.version) == "A\n")
        try #require(h.undo(undoChange)).apply(history: h)
        #expect(FileSupport.read(file) == "B\n")
    }

    @Test func undoAfterTheFileWasDeletedRecreatesIt() throws {
        let s = try Sandbox()
        let h = s.history
        let file = s.project.appendingPathComponent("AGENTS.md")
        try s.write("AGENTS.md", "one\n", in: s.project)
        h.observe(file)
        try FileWriter.write("two\n", to: file, history: h)
        try FileManager.default.removeItem(at: file)

        let latest = try #require(h.changes(to: [file]).first)
        let undo = try #require(h.undo(latest))
        #expect(undo.edits.first?.isNewFile == true)
        try undo.apply(history: h)
        #expect(FileSupport.read(file) == "one\n")
    }

    @Test func undoPlannedThenFileChangedOnDiskRefusesToWrite() throws {
        let s = try Sandbox()
        let h = s.history
        let file = s.project.appendingPathComponent("AGENTS.md")
        try s.write("AGENTS.md", "one\n", in: s.project)
        h.observe(file)
        try FileWriter.write("two\n", to: file, history: h)
        let latest = try #require(h.changes(to: [file]).first)
        let undo = try #require(h.undo(latest))

        try "agent wrote three\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: ChangeSet.ApplyError.self) { try undo.apply(history: h) }
        #expect(FileSupport.read(file) == "agent wrote three\n")
    }

    @Test func undoWhenTheOldObjectIsMissingIsNil() throws {
        let s = try Sandbox()
        let h = s.history
        let file = s.project.appendingPathComponent("AGENTS.md")
        try s.write("AGENTS.md", "one\n", in: s.project)
        h.observe(file)
        try FileWriter.write("two\n", to: file, history: h)
        let change = try #require(h.changes(to: [file]).first)
        try FileManager.default.removeItem(at: s.root.appendingPathComponent("history/objects"))
        #expect(h.text(of: change.previous) == nil)
        #expect(h.undo(change) == nil)
    }

    @Test func moreThanMaxVersionsKeepsTheNewestAndOtherFilesSharingObjectsSurvive() throws {
        let s = try Sandbox()
        let h = s.history
        let a = s.project.appendingPathComponent("a.md")
        let b = s.project.appendingPathComponent("b.md")
        // b has the same first text as a, so they share an object.
        h.record(b, text: "v0", origin: .observed)
        let base = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<(History.maxVersions + 5) {
            h.record(a, text: "v\(i)", origin: .observed, date: base.addingTimeInterval(Double(i)))
        }
        let versions = h.versions(of: a)
        #expect(versions.count == History.maxVersions)
        #expect(versions.first.flatMap(h.text(of:)) == "v\(History.maxVersions + 4)")
        #expect(versions.last.flatMap(h.text(of:)) == "v5")
        // Pruning a's log does not take b's text away.
        #expect(h.versions(of: b).first.flatMap(h.text(of:)) == "v0")
    }

    @Test func sameTextWithDifferentOriginsIsOneVersion() throws {
        let s = try Sandbox()
        let h = s.history
        let file = s.project.appendingPathComponent("x.md")
        #expect(h.record(file, text: "same", origin: .observed) != nil)
        #expect(h.record(file, text: "same", origin: .brainFog) == nil)
        #expect(h.record(file, text: "same", origin: .observed) == nil)
        #expect(h.record(file, text: "same", origin: .beforeChange) == nil)
        #expect(h.versions(of: file).map(\.origin) == [.brainFog])
        // Going back to a previous text is a new version, not a no-op.
        h.record(file, text: "other", origin: .observed)
        h.record(file, text: "same", origin: .observed)
        #expect(h.versions(of: file).count == 3)
    }

    @Test func corruptedLogReadsAsEmptyAndRecordingStartsOver() throws {
        let s = try Sandbox()
        let h = s.history
        let file = s.project.appendingPathComponent("x.md")
        h.record(file, text: "one", origin: .observed)
        let logs = s.root.appendingPathComponent("history/files")
        let log = try #require(try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil).first)
        try "{not json".write(to: log, atomically: true, encoding: .utf8)
        #expect(h.versions(of: file).isEmpty)
        #expect(h.changes(to: [file]).isEmpty)
        #expect(h.record(file, text: "two", origin: .observed) != nil)
        #expect(h.versions(of: file).count == 1)
    }

    @Test func concurrentRecordsKeepEveryVersion() throws {
        let s = try Sandbox()
        let h = s.history
        let file = s.project.appendingPathComponent("x.md")
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            h.record(file, text: "text \(i)", origin: .observed)
        }
        let versions = h.versions(of: file)
        #expect(versions.count == 64)
        #expect(Set(versions.map(\.hash)).count == 64)
    }

    @Test func oversizedTextIsNotRecorded() throws {
        let s = try Sandbox()
        let h = s.history
        let file = s.project.appendingPathComponent("big.md")
        #expect(h.record(file, text: String(repeating: "x", count: History.maxBytes + 1), origin: .observed) == nil)
        #expect(h.versions(of: file).isEmpty)
    }

    /// `apply` promises to write all edits or none, but a write that fails
    /// partway leaves the earlier edits on disk.
    @Test func changeSetIsAllOrNothingWhenALaterWriteFails() throws {
        let s = try Sandbox()
        let first = s.project.appendingPathComponent("first.md")
        try s.write("first.md", "original\n", in: s.project)
        // A regular file where the second edit needs a folder.
        try s.write("blocker", "i am a file\n", in: s.project)
        let second = s.project.appendingPathComponent("blocker/second.md")

        let set = ChangeSet(title: "t", detail: "d", edits: [
            FileEdit(url: first, before: "original\n", after: "changed\n"),
            FileEdit(url: second, before: nil, after: "new\n"),
        ])
        #expect(throws: (any Error).self) { try set.apply(history: s.history) }
        #expect(FileSupport.read(first) == "original\n")
    }

    @Test func applyRefusesWhenANewFileAppearedMeanwhile() throws {
        let s = try Sandbox()
        let file = s.project.appendingPathComponent("new.md")
        let set = ChangeSet(title: "t", detail: "d", edits: [FileEdit(url: file, before: nil, after: "mine\n")])
        try s.write("new.md", "theirs\n", in: s.project)
        #expect(throws: ChangeSet.ApplyError.self) { try set.apply(history: s.history) }
        #expect(FileSupport.read(file) == "theirs\n")
    }

    // MARK: Packs: credentials

    private func server(_ s: Sandbox, _ name: String) -> MCPServer {
        MCPServer(agent: .claudeCode, name: name, scope: .project, file: s.project.appendingPathComponent(".mcp.json"))
    }

    @Test func exportStripsSecretsInEnvAndHeaders() throws {
        let s = try Sandbox()
        var local = server(s, "local")
        local.command = "api-mcp"
        local.env = ["API_TOKEN": "plainvalue123", "SAFE": "${SAFE}", "OTHER": "ghp_abcdefghijklmnopqrstuvwxyz0123456789"]
        var remote = server(s, "remote")
        remote.url = "https://mcp.example.com/mcp"
        remote.headers = ["Authorization": "Bearer sk-live-0123456789abcdef"]

        let pack = AgentPack.export(project: s.project, contexts: [], servers: [local, remote], environment: s.env())
        let data = String(decoding: try pack.encoded(), as: UTF8.self)
        #expect(!data.contains("plainvalue123"))
        #expect(!data.contains("ghp_abcdef"))
        #expect(!data.contains("sk-live"))
        #expect(pack.servers.first { $0.name == "local" }?.env["SAFE"] == "${SAFE}")
        #expect(pack.stripped.count == 3)
    }

    /// A token passed on the command line (`--token ghp_…`) is common in MCP
    /// configs, and it goes into the pack as is.
    @Test func exportStripsSecretsInArgs() throws {
        let s = try Sandbox()
        var gh = server(s, "github")
        gh.command = "npx"
        gh.args = ["-y", "@modelcontextprotocol/server-github", "--token", "ghp_abcdefghijklmnopqrstuvwxyz0123456789"]
        let pack = AgentPack.export(project: s.project, contexts: [], servers: [gh], environment: s.env())
        let data = String(decoding: try pack.encoded(), as: UTF8.self)
        #expect(!data.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
        #expect(!pack.stripped.isEmpty)
    }

    /// Many hosted MCP servers take the key in the URL query string.
    @Test func exportStripsSecretsInServerURLs() throws {
        let s = try Sandbox()
        var remote = server(s, "search")
        remote.url = "https://mcp.example.com/sse?api_key=sk-abcdefghijklmnopqrstuvwxyz012345"
        remote.transport = "sse"
        let pack = AgentPack.export(project: s.project, contexts: [], servers: [remote], environment: s.env())
        let data = String(decoding: try pack.encoded(), as: UTF8.self)
        #expect(!data.contains("sk-abcdefghijklmnopqrstuvwxyz012345"))
        #expect(!pack.stripped.isEmpty)
    }

    /// `secretKeys` merges env and headers keeping the env value, so a header
    /// sharing a name with a harmless env reference is never checked.
    @Test func exportStripsAHeaderSecretWhoseNameAlsoAppearsInEnv() throws {
        let s = try Sandbox()
        var remote = server(s, "both")
        remote.url = "https://mcp.example.com/mcp"
        remote.env = ["API_KEY": "${API_KEY}"]
        remote.headers = ["API_KEY": "sk-abcdefghijklmnopqrstuvwxyz012345"]
        let pack = AgentPack.export(project: s.project, contexts: [], servers: [remote], environment: s.env())
        #expect(pack.servers.first?.headers["API_KEY"] != "sk-abcdefghijklmnopqrstuvwxyz012345")
    }

    // MARK: Packs: export and import

    @Test func emptyProjectExportsAnEmptyPackThatImportsToNothing() throws {
        let s = try Sandbox()
        let env = s.env()
        let pack = AgentPack.export(project: s.project, contexts: [], servers: [], environment: env)
        #expect(pack.files.isEmpty && pack.servers.isEmpty && pack.stripped.isEmpty)
        #expect(pack.source == "app")
        let decoded = try AgentPack.decode(pack.encoded())
        #expect(decoded.importChange(project: s.project, environment: env).edits.isEmpty)
    }

    @Test func exportImportExportRoundTripsWithUnicodeNames() throws {
        let s = try Sandbox()
        let env = s.env()
        try s.write("CLAUDE.md", "Übersicht — 中文 ✅\n", in: s.project)
        try s.write(".claude/rules/café 规则.md", "Règle\n", in: s.project)
        var ctx = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: env)
        ctx.skills = SkillResolver.resolve(agent: .claudeCode, workingDirectory: s.project, environment: env)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try AgentPack.decode(AgentPack.export(project: s.project, contexts: [ctx], servers: [],
                                                          environment: env, date: date).encoded())
        #expect(first.files.map(\.path).contains { $0.hasPrefix(".claude/rules/") && $0.hasSuffix("规则.md") })

        let other = s.home.appendingPathComponent("code/other")
        try FileManager.default.createDirectory(at: other.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try first.importChange(project: other, environment: env).apply(history: s.history)

        var ctx2 = ClaudeCodeResolver().resolve(workingDirectory: other, environment: env)
        ctx2.skills = SkillResolver.resolve(agent: .claudeCode, workingDirectory: other, environment: env)
        var second = AgentPack.export(project: other, contexts: [ctx2], servers: [], environment: env, date: date)
        second.source = first.source
        #expect(second == first)
    }

    @Test func importIntoAConflictingProjectShowsReplacementsAndKeepsOldText() throws {
        let s = try Sandbox()
        let env = s.env()
        try s.write("CLAUDE.md", "mine\n", in: s.project)
        try s.write("AGENTS.md", "same\n", in: s.project)
        let pack = AgentPack(created: Date(), source: "Other", files: [
            .init(base: .project, path: "CLAUDE.md", text: "theirs\n", agents: [.claudeCode]),
            .init(base: .project, path: "AGENTS.md", text: "same\n", agents: [.codex]),
        ], servers: [], stripped: [])
        let change = pack.importChange(project: s.project, environment: env)
        #expect(change.edits.count == 1)
        #expect(change.edits.first?.before == "mine\n")
        #expect(change.detail.contains("1 existing file is changed"))
        let h = s.history
        try change.apply(history: h)
        let file = s.project.appendingPathComponent("CLAUDE.md")
        #expect(h.versions(of: file).compactMap(h.text(of:)) == ["theirs\n", "mine\n"])
    }

    @Test func importNeverWritesOutsideTheProjectWithDotDotOrAbsolutePaths() throws {
        let s = try Sandbox()
        let env = s.env()
        let pack = AgentPack(created: Date(), source: "Evil", files: [
            .init(base: .project, path: "../../evil.md", text: "x", agents: []),
            .init(base: .project, path: "docs/../../evil2.md", text: "x", agents: []),
            .init(base: .project, path: "/etc/evil3.md", text: "x", agents: []),
            .init(base: .claudeMemory, path: "../../../../evil4.md", text: "x", agents: []),
            .init(base: .home, path: "../evil5.md", text: "x", agents: []),
        ], servers: [], stripped: [])
        let change = pack.importChange(project: s.project, environment: env)
        for edit in change.edits {
            #expect(FileSupport.isWithin(edit.url, s.project), "escapes: \(edit.url.path)")
        }
    }

    /// An empty or "." path names the folder itself; the import should skip
    /// it like "..", not plan a write that fails and sinks the whole import.
    @Test func importSkipsPathsThatNameTheFolderItself() throws {
        let s = try Sandbox()
        let env = s.env()
        let pack = AgentPack(created: Date(), source: "Odd", files: [
            .init(base: .project, path: "", text: "x", agents: []),
            .init(base: .project, path: ".", text: "x", agents: []),
            .init(base: .project, path: "ok.md", text: "fine\n", agents: []),
        ], servers: [], stripped: [])
        let change = pack.importChange(project: s.project, environment: env)
        #expect(change.edits.map { $0.url.lastPathComponent } == ["ok.md"])
        try change.apply(history: s.history)
        #expect(FileSupport.read(s.project.appendingPathComponent("ok.md")) == "fine\n")
    }

    @Test func malformedOrTruncatedPacksFailToDecode() throws {
        let s = try Sandbox()
        try s.write("CLAUDE.md", "hello\n", in: s.project)
        let ctx = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        let data = try AgentPack.export(project: s.project, contexts: [ctx], servers: [], environment: s.env()).encoded()
        #expect(throws: (any Error).self) { try AgentPack.decode(data.prefix(data.count / 2)) }
        #expect(throws: (any Error).self) { try AgentPack.decode(Data()) }
        #expect(throws: (any Error).self) { try AgentPack.decode(Data(#"{"format":1}"#.utf8)) }
        let badBase = String(decoding: data, as: UTF8.self).replacingOccurrences(of: #""base" : "project""#,
                                                                                 with: #""base" : "root""#)
        #expect(throws: (any Error).self) { try AgentPack.decode(Data(badBase.utf8)) }
    }

    @Test func globalPackOfProjectFilesNeedsAProject() throws {
        let s = try Sandbox()
        let pack = AgentPack(created: Date(), source: "app", files: [
            .init(base: .project, path: "CLAUDE.md", text: "x", agents: []),
            .init(base: .claudeMemory, path: "MEMORY.md", text: "y", agents: []),
        ], servers: [], stripped: [])
        let change = pack.importChange(project: nil, environment: s.env())
        #expect(change.edits.isEmpty)
        #expect(change.detail.contains("2 project files need a project"))
    }

    // MARK: Global sync

    @Test func emptySourceIsNotACandidate() throws {
        let s = try Sandbox()
        try s.write(".agents/AGENTS.md", "")
        try s.write(".codex/AGENTS.md", "Codex rules\n")
        let report = GlobalSyncReport.analyze(environment: s.env())
        #expect(report.candidates.map(\.path) == [s.home.appendingPathComponent(".codex/AGENTS.md").path])
    }

    /// A common hand-made setup: ~/.codex/AGENTS.md is a symlink to the
    /// shared file. Syncing from that file should see the link as in step,
    /// not replace it with a generated copy.
    @Test func targetSymlinkedToTheSourceIsLeftAlone() throws {
        let s = try Sandbox()
        try s.installAll()
        let env = s.env()
        try s.write(".agents/AGENTS.md", "Shared rules\n")
        let source = s.home.appendingPathComponent(".agents/AGENTS.md")
        let codex = s.home.appendingPathComponent(".codex/AGENTS.md")
        try FileManager.default.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: codex, withDestinationURL: source)

        let change = try #require(GlobalSyncReport.analyze(environment: env).sync(from: source, environment: env))
        #expect(!change.edits.contains { $0.url == codex.standardizedFileURL })
        #expect(!change.detail.contains("Codex"))
    }

    @Test func manualEditOfACopyIsDriftAndTheFixRestoresIt() throws {
        let s = try Sandbox()
        try s.installAll()
        let env = s.env()
        let h = s.history
        try s.write(".agents/AGENTS.md", "Be brief.\n")
        let source = s.home.appendingPathComponent(".agents/AGENTS.md")
        try #require(GlobalSyncReport.analyze(environment: env).sync(from: source, environment: env)).apply(history: h)
        // Second sync: nothing to do.
        #expect(GlobalSyncReport.analyze(environment: env).sync(from: source, environment: env) == nil)

        let codex = s.home.appendingPathComponent(".codex/AGENTS.md")
        let synced = try #require(FileSupport.read(codex))
        try (synced + "Hand edit\n").write(to: codex, atomically: true, encoding: .utf8)
        h.observe(codex)
        let report = GlobalSyncReport.analyze(environment: env)
        #expect(report.targets.first { $0.agent == .codex }?.state == .drifted)
        #expect(report.targets.filter { $0.state == .drifted }.count == 1)
        let issue = try #require(report.issues(environment: env).first)
        try #require(issue.fix).apply(history: h)
        #expect(FileSupport.read(codex) == synced)
        #expect(h.versions(of: codex).compactMap(h.text(of:)).contains(synced + "Hand edit\n"))

        // Removing the marker turns the copy into its own file.
        try "My own codex rules\n".write(to: codex, atomically: true, encoding: .utf8)
        #expect(GlobalSyncReport.analyze(environment: env).targets.first { $0.agent == .codex }?.state == .separate)
    }

    @Test func syncHonoursCodexHome() throws {
        let s = try Sandbox()
        try s.installAll()
        let env = s.env(["CODEX_HOME": "~/alt-codex"])
        try s.write(".agents/AGENTS.md", "Rules\n")
        try s.write("alt-codex/config.toml", "")
        let source = s.home.appendingPathComponent(".agents/AGENTS.md")
        let change = try #require(GlobalSyncReport.analyze(environment: env).sync(from: source, environment: env))
        #expect(change.edits.contains { $0.url.path == s.home.appendingPathComponent("alt-codex/AGENTS.md").path })
    }

    /// When the source is deleted after a sync, every copy reports drift
    /// "fixed by syncing again", but the fix is nil since the source is gone.
    @Test func driftIssuesAfterTheSourceIsDeletedStillOfferAFix() throws {
        let s = try Sandbox()
        try s.installAll()
        let env = s.env()
        try s.write(".agents/AGENTS.md", "Rules\n")
        let source = s.home.appendingPathComponent(".agents/AGENTS.md")
        try #require(GlobalSyncReport.analyze(environment: env).sync(from: source, environment: env)).apply(history: s.history)
        try FileManager.default.removeItem(at: source)
        let issues = GlobalSyncReport.analyze(environment: env).issues(environment: env)
        #expect(issues.allSatisfy { $0.fix != nil })
    }

    /// A CLAUDE.md saved with CRLF line endings never matches the import
    /// line, so it is reported as separate and every sync appends another.
    @Test func claudeImportLineWithCRLFCountsAsSynced() throws {
        let s = try Sandbox()
        let env = s.env()
        try s.write(".agents/AGENTS.md", "Rules\n")
        try s.write(".claude/CLAUDE.md", "Note\r\n\r\n@~/.agents/AGENTS.md\r\n")
        let source = s.home.appendingPathComponent(".agents/AGENTS.md")
        let report = GlobalSyncReport.analyze(environment: env)
        let claude = s.home.appendingPathComponent(".claude/CLAUDE.md").standardizedFileURL
        let change = report.sync(from: source, environment: env)
        #expect(change?.edits.contains { $0.url == claude } != true)
    }

    // MARK: Project discovery

    /// Discovery normally ignores /tmp and /var/folders, where the sandbox
    /// lives, so these tests pass no transient folders.
    private func scratchProjects(_ s: Sandbox) throws -> URL {
        let dir = s.root.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func discoveryMergesTrailingSlashAndDuplicatePaths() throws {
        let s = try Sandbox()
        let dir = try scratchProjects(s)
        let app = dir.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try s.write(".claude.json", #"{"projects":{"\#(app.path)":{},"\#(app.path)/":{}}}"#)
        try s.write(".codex/config.toml", "[projects.\"\(app.path)/\"]\ntrust_level = \"trusted\"\n")
        let found = ProjectDiscovery.discover(environment: s.env(), transient: [])
        #expect(found.count == 1)
        #expect(found.first?.knownBy == [.claudeCode, .codex])
    }

    @Test func discoverySurvivesMalformedClaudeJSONAndDropsMissingFolders() throws {
        let s = try Sandbox()
        let dir = try scratchProjects(s)
        let real = dir.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try s.write(".claude.json", #"{"projects": {"/x": "#)
        try s.write(".codex/config.toml", """
            [projects."\(real.path)"]
            trust_level = "trusted"
            [projects."\(dir.appendingPathComponent("gone").path)"]
            """)
        let found = ProjectDiscovery.discover(environment: s.env(), transient: [])
        #expect(found.map(\.url.path) == [real.path])
        #expect(found.first?.knownBy == [.codex])
    }

    /// Everything else reads Codex's files from $CODEX_HOME; discovery
    /// always looks in ~/.codex.
    @Test func discoveryHonoursCodexHome() throws {
        let s = try Sandbox()
        let dir = try scratchProjects(s)
        let app = dir.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try s.write("alt-codex/config.toml", "[projects.\"\(app.path)\"]\ntrust_level = \"trusted\"\n")
        let found = ProjectDiscovery.discover(environment: s.env(["CODEX_HOME": s.home.appendingPathComponent("alt-codex").path]),
                                             transient: [])
        #expect(found.map(\.url.path) == [app.path])
    }

    // MARK: Codex memory store

    private func makeMemoryDB(_ url: URL, rows: [(String, String?, Int64)], schema: Bool = true) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        if schema {
            sqlite3_exec(db, """
                CREATE TABLE stage1_outputs (thread_id TEXT, rollout_slug TEXT, rollout_summary TEXT,
                  raw_memory TEXT, generated_at INTEGER, usage_count INTEGER, selected_for_phase2 INTEGER);
                """, nil, nil, nil)
            for (id, memory, at) in rows {
                let mem = memory.map { "'\($0)'" } ?? "NULL"
                sqlite3_exec(db, "INSERT INTO stage1_outputs VALUES ('\(id)', NULL, 'sum', \(mem), \(at), NULL, 1);", nil, nil, nil)
            }
        } else {
            sqlite3_exec(db, "CREATE TABLE other (x INTEGER);", nil, nil, nil)
        }
    }

    @Test func memoryStoreOpensTheNumericallyNewestDatabase() throws {
        let s = try Sandbox()
        let codex = s.home.appendingPathComponent(".codex")
        try makeMemoryDB(codex.appendingPathComponent("memories_9.sqlite"), rows: [("old", "o", 1)])
        try makeMemoryDB(codex.appendingPathComponent("memories_10.sqlite"), rows: [("a", "first", 100), ("b", nil, 200)])
        try s.write(".codex/memories_11.sqlite-wal", "junk")
        let store = try #require(CodexMemoryStore(codexHome: codex))
        #expect(store.stats()?.rawMemories == 2)
        let raw = store.rawMemories()
        #expect(raw.map(\.threadID) == ["b", "a"])
        #expect(raw.first?.memory == "")
        #expect(raw.first?.slug == nil)
    }

    @Test func memoryStoreWithoutTheTableOrDatabaseIsQuiet() throws {
        let s = try Sandbox()
        let codex = s.home.appendingPathComponent(".codex")
        #expect(CodexMemoryStore(codexHome: codex) == nil)
        try makeMemoryDB(codex.appendingPathComponent("memories_1.sqlite"), rows: [], schema: false)
        let store = try #require(CodexMemoryStore(codexHome: codex))
        #expect(store.stats() == nil)
        #expect(store.rawMemories().isEmpty)
    }

    /// The database is opened as a `file:` URI without percent-encoding, so
    /// a `#` or `?` in the folder path points SQLite at the wrong file.
    @Test func memoryStoreOpensUnderAFolderWithURIMetacharacters() throws {
        let s = try Sandbox()
        let codex = s.home.appendingPathComponent("C# work?/.codex")
        try makeMemoryDB(codex.appendingPathComponent("memories_1.sqlite"), rows: [("a", "m", 1)])
        let store = CodexMemoryStore(codexHome: codex)
        #expect(store?.stats()?.rawMemories == 1)
    }
}
