import Foundation
import Testing
@testable import BrainFogCore

/// Odd things a user can do in the GUI around creating, copying, sharing
/// and fixing instruction files, and how the resolvers see the result.
@Suite struct FileCrudEdgeTests {
    private let fm = FileManager.default

    private func ruleOption(_ agent: AgentID, _ s: Sandbox, project: URL? = nil) throws -> NewFileOption {
        try #require(NewFileOption.options(for: agent, project: project ?? s.project, environment: s.env())
            .first { $0.needsName })
    }

    private func contexts(_ s: Sandbox, cwd: URL? = nil) -> [ResolvedContext] {
        Resolvers.resolveAll(workingDirectory: cwd ?? s.project, environment: s.env())
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    // MARK: Creating

    @Test func badRuleNamesAreRefusedAndCreateNothing() throws {
        let s = try Sandbox()
        let rule = try ruleOption(.claudeCode, s)
        for name in ["", " ", "\n", ".", "..", "a/b", ".hidden", "x:y", ".md"] {
            #expect(throws: (any Error).self, "\(name.debugDescription)") { try rule.create(name: name) }
        }
        let made = (try? fm.contentsOfDirectory(atPath: rule.url.path)) ?? []
        #expect(made.isEmpty)
    }

    @Test func unicodeAndDoubledExtensionNamesLoad() throws {
        let s = try Sandbox()
        let rule = try ruleOption(.claudeCode, s)
        let cjk = try rule.create(name: "  名字 \n")
        #expect(cjk.lastPathComponent == "名字.md")
        let doubled = try rule.create(name: "x.md.md")
        #expect(doubled.lastPathComponent == "x.md.md")
        let ctx = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(ctx.entries.contains { $0.url == cjk.standardizedFileURL && $0.timing.isLoadedAtLaunch })
        #expect(ctx.entries.contains { $0.url == doubled.standardizedFileURL && $0.timing.isLoadedAtLaunch })
    }

    @Test func overlongNameThrowsWithoutLeavingAFile() throws {
        let s = try Sandbox()
        let rule = try ruleOption(.claudeCode, s)
        #expect(throws: (any Error).self) { try rule.create(name: String(repeating: "a", count: 300)) }
        let made = (try? fm.contentsOfDirectory(atPath: rule.url.path)) ?? []
        #expect(made.isEmpty)
        // Just under the limit still works.
        let ok = try rule.create(name: String(repeating: "b", count: 250))
        #expect(FileSupport.isFile(ok))
    }

    @Test func nameDifferingOnlyInCaseDoesNotOverwrite() throws {
        let s = try Sandbox()
        let rule = try ruleOption(.claudeCode, s)
        let first = try rule.create(name: "Style")
        try "keep me".write(to: first, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try rule.create(name: "style") }
        #expect(throws: (any Error).self) { try rule.create(name: "STYLE.MD") }
        #expect(FileSupport.read(first) == "keep me")
    }

    @Test func creatingAnExistingFixedFileNeverOverwrites() throws {
        let s = try Sandbox()
        for agent in AgentID.allCases {
            for option in NewFileOption.options(for: agent, project: s.project, environment: s.env()) where !option.needsName {
                let url = try option.create()
                try "mine".write(to: url, atomically: true, encoding: .utf8)
                #expect(option.exists)
                #expect(throws: (any Error).self, "\(agent) \(option.title)") { try option.create() }
                #expect(FileSupport.read(url) == "mine")
                try fm.removeItem(at: url)
            }
        }
    }

    @Test func templatedRuleFilesLoadAtLaunchInTheirAgent() throws {
        let s = try Sandbox()
        for agent in [AgentID.copilot, .devin, .cline, .cursor] {
            let url = try ruleOption(agent, s).create(name: "team")
            let ctx = try #require(contexts(s).first { $0.agent == agent })
            let entry = ctx.entries.first { $0.url == url.standardizedFileURL }
            #expect(entry?.timing.isLoadedAtLaunch == true, "\(agent) \(url.lastPathComponent)")
        }
        // Copilot's own suffix is not doubled.
        let copilot = try ruleOption(.copilot, s).create(name: "api.instructions.md")
        #expect(copilot.lastPathComponent == "api.instructions.md")
    }

    @Test func deletingClaudeMdMakesClaudeReadAgentsMdAgain() throws {
        let s = try Sandbox()
        try s.write("AGENTS.md", "shared", in: s.project)
        let option = try #require(NewFileOption.options(for: .claudeCode, project: s.project, environment: s.env())
            .first { $0.title == "CLAUDE.md" })
        let claude = try option.create()
        var ctx = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(!s.names(ctx).contains("~/code/app/AGENTS.md"))
        try fm.removeItem(at: claude)
        ctx = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(s.names(ctx).contains("~/code/app/AGENTS.md"))
        #expect(!ctx.entries.contains { $0.url == claude.standardizedFileURL })
    }

    @Test func projectPathWithSpacesAndUnicode() throws {
        let s = try Sandbox()
        let project = s.home.appendingPathComponent("My Code/应用 app")
        try fm.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try s.write("CLAUDE.md", "@docs/说明.md\n", in: project)
        try s.write("docs/说明.md", "notes", in: project)
        let rule = try ruleOption(.claudeCode, s, project: project).create(name: "规则")
        let ctx = ClaudeCodeResolver().resolve(workingDirectory: project, environment: s.env())
        let launched = s.names(ctx)
        #expect(launched.contains("~/My Code/应用 app/docs/说明.md"))
        #expect(ctx.entries.contains { $0.url == rule.standardizedFileURL })
        #expect(!ctx.diagnostics.contains { $0.severity == .warning })
    }

    // MARK: Symlinks and odd file contents

    @Test func brokenAndLoopingClaudeSymlinksFallBackToAgentsMd() throws {
        let s = try Sandbox()
        try s.write("AGENTS.md", "shared", in: s.project)
        let claude = s.project.appendingPathComponent("CLAUDE.md")
        try fm.createSymbolicLink(atPath: claude.path, withDestinationPath: "missing.md")
        var ctx = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(s.names(ctx).contains("~/code/app/AGENTS.md"))
        try fm.removeItem(at: claude)
        try fm.createSymbolicLink(atPath: claude.path, withDestinationPath: "CLAUDE.md")
        ctx = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(s.names(ctx).contains("~/code/app/AGENTS.md"))
    }

    /// Claude Code detects circular symlinks; a rules folder linking back to
    /// itself must not list (and count) the same rule many times.
    @Test func ruleFolderSymlinkLoopListsEachRuleOnce() throws {
        let s = try Sandbox()
        try s.write(".claude/rules/x.md", "rule text", in: s.project)
        let rules = s.project.appendingPathComponent(".claude/rules")
        try fm.createSymbolicLink(atPath: rules.appendingPathComponent("loop").path, withDestinationPath: rules.path)
        let ctx = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        let copies = ctx.entries.filter { $0.url.lastPathComponent == "x.md" }
        #expect(copies.count == 1, "listed \(copies.count) times: \(copies.map(\.url.path))")
    }

    @Test func importCyclesAndSelfImportsListEachFileOnce() throws {
        let s = try Sandbox()
        try s.write("CLAUDE.md", "@CLAUDE.md\n@a.md\n", in: s.project)
        try s.write("a.md", "@b.md\n", in: s.project)
        try s.write("b.md", "@a.md\n@./CLAUDE.md\n", in: s.project)
        let ctx = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        let paths = ctx.entries.map(\.url.path)
        #expect(paths.count == Set(paths).count)
        #expect(s.names(ctx).contains("~/code/app/a.md") && s.names(ctx).contains("~/code/app/b.md"))
        #expect(!ctx.diagnostics.contains { $0.message.contains("not found") })
    }

    @Test func nonUtf8AndNoTrailingNewlineFilesStillLoad() throws {
        let s = try Sandbox()
        let url = s.project.appendingPathComponent("CLAUDE.md")
        try Data([0x63, 0x61, 0x66, 0xE9, 0x20, 0xFF, 0xFE]).write(to: url)   // Latin-1 "café" + junk
        try s.write(".claude/rules/only-frontmatter.md", "---\npaths:\n  - \"src/**\"\n---", in: s.project)
        try s.write(".claude/rules/unclosed.md", "---\npaths:\n  - \"src/**\"\nbody", in: s.project)
        let ctx = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(ctx.entries.first { $0.url.lastPathComponent == "CLAUDE.md" }?.tokens ?? 0 > 0)
        #expect(ctx.entries.first { $0.url.lastPathComponent == "only-frontmatter.md" }?.timing.isLoadedAtLaunch == false)
        // Without a closing --- it isn't frontmatter, so the rule always loads.
        #expect(ctx.entries.first { $0.url.lastPathComponent == "unclosed.md" }?.timing.isLoadedAtLaunch == true)
    }

    /// Windows editors save with a UTF-8 BOM; the frontmatter is still there.
    @Test func bomRuleKeepsItsPaths() throws {
        let s = try Sandbox()
        try s.write(".claude/rules/api.md", "\u{FEFF}---\npaths:\n  - \"src/**\"\n---\nAPI rules\n", in: s.project)
        let ctx = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        let rule = ctx.entries.first { $0.url.lastPathComponent == "api.md" }
        #expect(rule?.timing.isLoadedAtLaunch == false)
    }

    @Test func bomSkillKeepsItsNameAndDescription() throws {
        let s = try Sandbox()
        try s.write(".claude/skills/x/SKILL.md", "\u{FEFF}---\nname: deploy\ndescription: Ship it\n---\nbody\n")
        let skill = SkillResolver.resolve(agent: .claudeCode, workingDirectory: nil, environment: s.env()).first
        #expect(skill?.name == "deploy")
        #expect(skill?.description == "Ship it")
    }

    /// `name:` left blank falls back to the folder name, as when it is absent.
    @Test func blankSkillNameFallsBackToFolder() throws {
        let s = try Sandbox()
        try s.write(".claude/skills/deploy/SKILL.md", "---\nname:\ndescription: Ship it\n---\n")
        try s.write(".claude/skills/lint/SKILL.md", "---\nname: \"\"\ndescription: Lint\n---\n")
        let skills = SkillResolver.resolve(agent: .claudeCode, workingDirectory: nil, environment: s.env())
        #expect(skills.map(\.name) == ["deploy", "lint"])
        #expect(skills.allSatisfy { $0.timing.isLoadedAtLaunch })
    }

    @Test func skillsFromASubfolderOfTheRepo() throws {
        let s = try Sandbox()
        try s.write(".claude/skills/root/SKILL.md", "---\nname: root\ndescription: x\n---\n", in: s.project)
        try s.write("pkg/web/.claude/skills/web/SKILL.md", "---\nname: web\ndescription: x\n---\n", in: s.project)
        let cwd = s.project.appendingPathComponent("pkg/web")
        let skills = SkillResolver.resolve(agent: .claudeCode, workingDirectory: cwd, environment: s.env())
        #expect(Set(skills.map(\.name)) == ["root", "web"])
    }

    // MARK: Copying

    @Test func copyingTwiceToCopilotStillLoads() throws {
        let s = try Sandbox()
        try s.write("notes.md", "be terse\n", in: s.project)
        let src = s.project.appendingPathComponent("notes.md")
        let first = try #require(CopyPlan(source: src, to: .copilot, project: s.project, from: .claudeCode, environment: s.env()))
        try first.apply(text: "be terse\n", source: src, history: s.history)
        let second = try #require(CopyPlan(source: src, to: .copilot, project: s.project, from: .claudeCode, environment: s.env()))
        #expect(second.destination != first.destination)
        try second.apply(text: "be terse\n", source: src, history: s.history)
        #expect(second.destination.lastPathComponent.hasSuffix(".instructions.md"), "\(second.destination.lastPathComponent)")
        let ctx = CopilotResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(ctx.entries.contains { $0.url == second.destination && $0.timing.isLoadedAtLaunch })
    }

    @Test func copyingTwiceToClaudeKeepsBothAndIgnoresCase() throws {
        let s = try Sandbox()
        try s.write("Notes.md", "x\n", in: s.project)
        try s.write(".claude/rules/codex-notes.md", "older\n", in: s.project)
        let src = s.project.appendingPathComponent("Notes.md")
        let plan = try #require(CopyPlan(source: src, to: .claudeCode, project: s.project, from: .codex, environment: s.env()))
        #expect(plan.destination.lastPathComponent == "codex-Notes-2.md")
        try plan.apply(text: "x\n", source: src, history: s.history)
        #expect(FileSupport.read(s.project.appendingPathComponent(".claude/rules/codex-notes.md")) == "older\n")
    }

    /// A Copilot file limited by applyTo must not become an always-on Claude rule.
    @Test func copilotApplyToSurvivesCopyToClaude() throws {
        let s = try Sandbox()
        let text = "---\napplyTo: \"src/**\"\n---\nAPI rules\n"
        try s.write(".github/instructions/api.instructions.md", text, in: s.project)
        let src = s.project.appendingPathComponent(".github/instructions/api.instructions.md")
        let plan = try #require(CopyPlan(source: src, to: .claudeCode, project: s.project, from: .copilot, environment: s.env()))
        try plan.apply(text: text, source: src, history: s.history)
        let ctx = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        let copy = ctx.entries.first { $0.url == plan.destination }
        #expect(copy?.timing.isLoadedAtLaunch == false || !plan.lostScope.isEmpty)
    }

    /// Commas inside {a,b} are part of one glob, not a list separator.
    @Test func braceGlobSurvivesCopyToCline() throws {
        let s = try Sandbox()
        let text = "---\npaths:\n  - \"src/**/*.{ts,tsx}\"\n---\nTS rules\n"
        try s.write(".claude/rules/ts.md", text, in: s.project)
        let src = s.project.appendingPathComponent(".claude/rules/ts.md")
        let plan = try #require(CopyPlan(source: src, to: .cline, project: s.project, from: .claudeCode, environment: s.env()))
        try plan.apply(text: text, source: src, history: s.history)
        let yaml = Frontmatter.split(FileSupport.read(plan.destination) ?? "").yaml ?? ""
        #expect(Frontmatter.list("paths", in: yaml) == ["src/**/*.{ts,tsx}"])
    }

    @Test func crlfRuleCopiedToCursorKeepsScopeAndDropsCR() throws {
        let s = try Sandbox()
        let text = "---\r\npaths:\r\n  - \"src/**\"\r\n---\r\nUse tabs.\r\n"
        try s.write(".claude/rules/style.md", text, in: s.project)
        let src = s.project.appendingPathComponent(".claude/rules/style.md")
        let plan = try #require(CopyPlan(source: src, to: .cursor, project: s.project, from: .claudeCode, environment: s.env()))
        try plan.apply(text: text, source: src, history: s.history)
        let written = FileSupport.read(plan.destination) ?? ""
        #expect(!written.contains("paths:"))
        #expect(written.components(separatedBy: "---").count == 3)   // exactly one frontmatter block
        let ctx = CursorResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(ctx.entries.first { $0.url == plan.destination }?.timing == .onDemand("when files matching src/** are in context"))
    }

    /// `ln -s CLAUDE.md AGENTS.md` is a common way to share one file;
    /// appending a copy must go into the real file and keep the link.
    @Test func copyIntoSymlinkedAgentsMdKeepsTheLink() throws {
        let s = try Sandbox()
        try s.write("CLAUDE.md", "claude\n", in: s.project)
        let agents = s.project.appendingPathComponent("AGENTS.md")
        try fm.createSymbolicLink(atPath: agents.path, withDestinationPath: "CLAUDE.md")
        try s.write("notes.md", "copied\n", in: s.root)
        let src = s.root.appendingPathComponent("notes.md")
        let plan = try #require(CopyPlan(source: src, to: .codex, project: s.project, from: nil, environment: s.env()))
        #expect(plan.destination.lastPathComponent == "AGENTS.md")
        try plan.apply(text: "copied\n", source: src, history: s.history)
        #expect(isSymlink(agents))
        #expect(FileSupport.read(s.project.appendingPathComponent("CLAUDE.md"))?.contains("copied") == true)
    }

    @Test func staleCopyIsRefused() throws {
        let s = try Sandbox()
        try s.write("AGENTS.md", "v1\n", in: s.project)
        try s.write("notes.md", "n\n", in: s.root)
        let src = s.root.appendingPathComponent("notes.md")
        let plan = try #require(CopyPlan(source: src, to: .codex, project: s.project, from: nil, environment: s.env()))
        let edit = plan.edit(text: "n\n", source: src)
        try s.write("AGENTS.md", "edited elsewhere\n", in: s.project)
        #expect(throws: ChangeSet.ApplyError.self) {
            try ChangeSet(title: "", detail: "", edits: [edit]).apply(history: s.history)
        }
        #expect(FileSupport.read(s.project.appendingPathComponent("AGENTS.md")) == "edited elsewhere\n")
    }

    // MARK: Sharing

    @Test func sharingFixAllThenRecheckIsClean() throws {
        let s = try Sandbox()
        try s.write("AGENTS.md", "shared\n", in: s.project)
        try s.write(".claude/CLAUDE.md", "claude", in: s.project)
        let report = SharingReport.analyze(project: s.project, contexts: contexts(s), environment: s.env())
        let all = try #require(report.fixAll)
        try all.apply(history: s.history)
        #expect(FileSupport.read(s.project.appendingPathComponent(".claude/CLAUDE.md")) == "claude\n\n@../AGENTS.md\n")

        let again = SharingReport.analyze(project: s.project, contexts: contexts(s), environment: s.env())
        #expect(again.statuses.filter { !$0.reads }.map(\.agent) == [])
        #expect(again.statuses.allSatisfy { $0.fix == nil })
        // The old fix, applied again, is refused instead of adding a second import.
        #expect(throws: ChangeSet.ApplyError.self) { try all.apply(history: s.history) }
    }

    /// With `ln -s AGENTS.md CLAUDE.md`, Claude Code already reads the
    /// shared text; the fix must not write `@AGENTS.md` into AGENTS.md itself.
    @Test func sharingWithSymlinkedClaudeMdDoesNotSelfImport() throws {
        let s = try Sandbox()
        try s.write("AGENTS.md", "shared\n", in: s.project)
        try fm.createSymbolicLink(atPath: s.project.appendingPathComponent("CLAUDE.md").path, withDestinationPath: "AGENTS.md")
        let report = SharingReport.analyze(project: s.project, contexts: contexts(s), environment: s.env())
        let claude = try #require(report.statuses.first { $0.agent == .claudeCode })
        #expect(claude.reads || claude.fix == nil, "fix: \(claude.fix?.title ?? "-")")
        if let fix = claude.fix { try fix.apply(history: s.history) }
        #expect(FileSupport.read(s.project.appendingPathComponent("AGENTS.md")) == "shared\n")
        // And whatever is written, CLAUDE.md is still the link.
        #expect(isSymlink(s.project.appendingPathComponent("CLAUDE.md")))
    }

    @Test func sharingSetupFromEmptyThenRecheck() throws {
        let s = try Sandbox()
        let report = SharingReport.analyze(project: s.project, contexts: contexts(s), environment: s.env())
        #expect(!report.exists)
        try #require(report.setup).apply(history: s.history)
        let again = SharingReport.analyze(project: s.project, contexts: contexts(s), environment: s.env())
        #expect(again.exists && again.setup == nil)
        #expect(again.statuses.filter { !$0.reads }.map(\.agent) == [])
    }

    // MARK: Rule format form

    @Test func quotedDescriptionRoundTrips() {
        let field = RuleFormat.cursor.fields[2]
        for value in [#"Use "tabs" always"#, "Follow the users'", "Path: C:\\src"] {
            let text = RuleFormat.setting(field, to: value, in: "Body\n")
            #expect(RuleFormat.value(of: field, in: text) == value, "\(text.debugDescription)")
        }
    }

    /// Opening the form and saving the paths field unchanged must not split
    /// a brace glob into two broken globs.
    @Test func braceGlobRoundTripsThroughTheForm() {
        let field = RuleFormat.claude.fields[0]
        let text = "---\npaths:\n  - \"src/**/*.{ts,tsx}\"\n---\nBody\n"
        let shown = RuleFormat.value(of: field, in: text)
        #expect(RuleFormat.setting(field, to: shown, in: text) == text)
    }

    @Test func settingAFieldOnABomFileDoesNotAddASecondBlock() {
        let field = RuleFormat.claude.fields[0]
        let text = "\u{FEFF}---\npaths:\n  - \"a/**\"\n---\nBody\n"
        let after = RuleFormat.setting(field, to: "b/**", in: text)
        #expect(after.components(separatedBy: "---").count == 3, "\(after.debugDescription)")
    }

    // MARK: Health

    @Test func healthFixThenRecheckIsClean() throws {
        let s = try Sandbox()
        try s.write(".gitignore", "node_modules", in: s.project)   // no trailing newline
        try s.write("CLAUDE.local.md", "mine", in: s.project)
        try s.write("AGENTS.local.md", "mine", in: s.project)
        var rounds = 0
        while let fix = HealthCheck.localFilesNotIgnored(project: s.project).first?.fix, rounds < 5 {
            try fix.apply(history: s.history)
            rounds += 1
        }
        #expect(rounds == 2)
        #expect(HealthCheck.localFilesNotIgnored(project: s.project).isEmpty)
        let ignore = FileSupport.read(s.project.appendingPathComponent(".gitignore")) ?? ""
        #expect(ignore.components(separatedBy: "\n").contains("node_modules"))
        #expect(ignore.components(separatedBy: "\n").filter { $0 == "CLAUDE.local.md" }.count == 1)
    }

    @Test func healthFromASubfolderUsesTheRootGitignore() throws {
        let s = try Sandbox()
        try s.write(".gitignore", "pkg/CLAUDE.local.md\n", in: s.project)
        try s.write("pkg/CLAUDE.local.md", "mine", in: s.project)
        #expect(HealthCheck.localFilesNotIgnored(project: s.project.appendingPathComponent("pkg")).isEmpty)
    }

    /// A .gitignore saved with Windows line endings still ignores the file.
    @Test func crlfGitignoreCounts() throws {
        let s = try Sandbox()
        try s.write(".gitignore", "node_modules\r\nCLAUDE.local.md\r\n", in: s.project)
        try s.write("CLAUDE.local.md", "mine", in: s.project)
        #expect(HealthCheck.localFilesNotIgnored(project: s.project).isEmpty)
    }

    /// `*.local.md` is a common way to ignore every personal file.
    @Test func globGitignoreCounts() throws {
        let s = try Sandbox()
        try s.write(".gitignore", "*.local.md\n", in: s.project)
        try s.write("CLAUDE.local.md", "mine", in: s.project)
        #expect(HealthCheck.localFilesNotIgnored(project: s.project).isEmpty)
    }

    @Test func emptyFileIssueGoesAwayOnceWritten() throws {
        let s = try Sandbox()
        let url = try #require(NewFileOption.options(for: .claudeCode, project: s.project, environment: s.env())
            .first { $0.title == "CLAUDE.md" }).create()
        #expect(HealthCheck.run(project: s.project, contexts: contexts(s)).contains { $0.title == "CLAUDE.md is empty" })
        try FileWriter.write("Be terse.\n", to: url, history: s.history)
        #expect(!HealthCheck.run(project: s.project, contexts: contexts(s)).contains { $0.title.hasSuffix("is empty") })
    }
}
