import Foundation
import Testing
@testable import BrainFogCore

/// Edge cases found while reviewing; each asserts the behaviour a user
/// would expect. All of them run inside a throwaway Sandbox.
@Suite struct EdgeCaseTests {
    /// The app reopens the editor on the entry it just created by looking it
    /// up in the fresh resolve; a file the resolver leaves out closes it.
    private func appLookup(_ url: URL, agent: AgentID, s: Sandbox) -> ContextEntry? {
        Resolvers.resolveAll(workingDirectory: s.project, environment: s.env())
            .first { $0.agent == agent }?.entries
            .first { $0.url == url.standardizedFileURL }
    }

    @Test func newEmptyFilesStayListedSoTheEditorStaysOpen() throws {
        let s = try Sandbox()
        for agent in AgentID.allCases {
            for option in NewFileOption.options(for: agent, project: s.project, environment: s.env())
            where !option.needsName {
                let url = try option.create()
                #expect(appLookup(url, agent: agent, s: s) != nil, "\(agent) \(option.title)")
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    @Test func crlfRuleFrontmatter() throws {
        let s = try Sandbox()
        try s.write(".claude/rules/api.md", "---\r\npaths:\r\n  - \"src/**\"\r\n---\r\nAPI rules\r\n", in: s.project)
        let ctx = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        let rule = ctx.entries.first { $0.url.lastPathComponent == "api.md" }
        #expect(rule.map { !$0.timing.isLoadedAtLaunch } == true)
    }

    @Test func crlfSkillFrontmatter() throws {
        let s = try Sandbox()
        try s.write(".claude/skills/x/SKILL.md", "---\r\nname: deploy\r\ndescription: Ship it\r\n---\r\nbody\r\n")
        let skill = SkillResolver.resolve(agent: .claudeCode, workingDirectory: nil, environment: s.env()).first
        #expect(skill?.name == "deploy")
        #expect(skill?.description == "Ship it")
    }

    @Test func ruleNameCannotEscapeTheRulesFolder() throws {
        let s = try Sandbox()
        let rule = NewFileOption.options(for: .claudeCode, project: s.project, environment: s.env())
            .first { $0.needsName }!
        let url = try? rule.create(name: "../../escaped")
        #expect(url.map { FileSupport.isWithin($0, rule.url) } ?? true)
    }

    @Test func upperCaseExtensionRuleIsListed() throws {
        let s = try Sandbox()
        let rule = NewFileOption.options(for: .claudeCode, project: s.project, environment: s.env())
            .first { $0.needsName }!
        let url = try rule.create(name: "Style.MD")
        #expect(appLookup(url, agent: .claudeCode, s: s) != nil)
    }

    @Test func copyToCodexWarnsClaudeWhenClaudeReadsAgents() throws {
        let s = try Sandbox()
        try s.write("notes.md", "x", in: s.root)
        // No CLAUDE.md anywhere, so Claude Code reads AGENTS.md too.
        let plan = CopyPlan(source: s.root.appendingPathComponent("notes.md"), to: .codex,
                            project: s.project, from: nil, environment: s.env())!
        try plan.apply(text: "x", source: s.root.appendingPathComponent("notes.md"), history: s.history)
        let claude = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        let readsIt = claude.entries.contains { $0.url == plan.destination && $0.timing.isLoadedAtLaunch }
        #expect(!readsIt || plan.sharedWith.contains(.claudeCode))
    }

    @Test func copyOfPathScopedRuleKeepsItScoped() throws {
        let s = try Sandbox()
        let text = "---\npaths:\n  - \"src/**\"\n---\nOnly for src\n"
        try s.write(".claude/rules/src.md", text, in: s.project)
        let src = s.project.appendingPathComponent(".claude/rules/src.md")
        let plan = CopyPlan(source: src, to: .codex, project: s.project, from: .claudeCode, environment: s.env())!
        try plan.apply(text: text, source: src, history: s.history)
        let written = FileSupport.read(plan.destination) ?? ""
        // The frontmatter means nothing to Codex; it lands mid-file as text.
        #expect(!written.contains("paths:"))
    }

    @Test func cursorGlobsBecomeClaudePaths() throws {
        let s = try Sandbox()
        let text = "---\nglobs: *.swift, *.m\nalwaysApply: false\n---\nUse tabs.\n"
        try s.write(".cursor/rules/style.mdc", text, in: s.project)
        let src = s.project.appendingPathComponent(".cursor/rules/style.mdc")
        let plan = CopyPlan(source: src, to: .claudeCode, project: s.project, from: .cursor, environment: s.env())!
        try plan.apply(text: text, source: src, history: s.history)
        let ctx = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        let copy = ctx.entries.first { $0.url == plan.destination }
        #expect(copy?.timing == .onDemand("when Claude reads or edits files matching *.swift, *.m"))
        #expect(FileSupport.read(plan.destination)?.hasSuffix("Use tabs.\n") == true)
    }

    @Test func parentAgentsImportedByChildClaudeLoads() throws {
        let s = try Sandbox()
        try s.write("code/AGENTS.md", "shared")
        try s.write("CLAUDE.md", "@../AGENTS.md\n", in: s.project)
        let ctx = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(s.names(ctx).contains("~/code/AGENTS.md"))
    }

    @Test func nestedClaudeFileFoundInLargeRepo() throws {
        let s = try Sandbox()
        for i in 0..<2100 { try s.write(String(format: "a/f%04d.txt", i), "", in: s.project) }
        try s.write("z/CLAUDE.md", "deep", in: s.project)
        let ctx = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(ctx.entries.contains { $0.url.path.hasSuffix("z/CLAUDE.md") })
    }

    @Test func codexConfigHashInsideString() throws {
        let s = try Sandbox()
        try s.write(".codex/config.toml", "project_doc_fallback_filenames = [\"NOTES#1.md\"]\n")
        try s.write("NOTES#1.md", "notes", in: s.project)
        let ctx = CodexResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(ctx.entries.contains { $0.url.lastPathComponent == "NOTES#1.md" })
    }

    @Test func jsoncTrailingCommaInsideString() {
        let obj = JSONC.object(from: #"{"instructions": ["a, ]"]}"#)
        #expect((obj?["instructions"] as? [String]) == ["a, ]"])
    }

    @Test func importOfOnDemandRuleBecomesLaunch() throws {
        let s = try Sandbox()
        try s.write(".claude/rules/api.md", "---\npaths: src/**\n---\napi\n")
        try s.write("CLAUDE.md", "@~/.claude/rules/api.md\n", in: s.project)
        let ctx = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        let rule = ctx.entries.first { $0.url.lastPathComponent == "api.md" }
        // CLAUDE.md pulls it in at launch, whatever its paths say.
        #expect(rule?.timing.isLoadedAtLaunch == true)
    }
}

@Suite struct ImportSyntaxTests {
    @Test func relativeImportsKeepTheirDots() {
        #expect(ClaudeCodeResolver.importPaths(in: "See @./a.md and @../b.md, then @c.md.")
            == ["./a.md", "../b.md", "c.md"])
    }
}
