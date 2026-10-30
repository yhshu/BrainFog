import Foundation
import Testing
@testable import BrainFogCore

/// A throwaway home directory plus a git project inside it.
final class Sandbox {
    let root: URL
    var home: URL { root.appendingPathComponent("home") }
    var project: URL { home.appendingPathComponent("code/app") }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("brainfog-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ relative: String, _ text: String, in base: URL? = nil) throws {
        let url = (base ?? home).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func env(_ vars: [String: String] = [:]) -> ResolverEnvironment {
        ResolverEnvironment(home: home, variables: vars,
                            claudeManagedDirectory: root.appendingPathComponent("managed"))
    }

    func names(_ ctx: ResolvedContext, launchOnly: Bool = true) -> [String] {
        ctx.entries.filter { !launchOnly || $0.timing.isLoadedAtLaunch }.map {
            $0.url.path.replacingOccurrences(of: home.path + "/", with: "~/")
        }
    }
}

@Suite struct ClaudeCodeTests {
    @Test func layersInOrder() throws {
        let s = try Sandbox()
        try s.write("CLAUDE.md", "managed", in: s.root.appendingPathComponent("managed"))
        try s.write(".claude/CLAUDE.md", "user")
        try s.write("code/CLAUDE.md", "parent")
        try s.write("CLAUDE.md", "project", in: s.project)
        try s.write("CLAUDE.local.md", "mine", in: s.project)
        try s.write("AGENTS.md", "agents", in: s.project)

        let ctx = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        let launched = s.names(ctx)
        #expect(launched.first?.hasSuffix("managed/CLAUDE.md") == true)
        #expect(Array(launched.dropFirst()) == [
            "~/.claude/CLAUDE.md", "~/code/CLAUDE.md", "~/code/app/CLAUDE.md", "~/code/app/CLAUDE.local.md",
        ])
        let agents = ctx.entries.first { $0.url.lastPathComponent == "AGENTS.md" }
        #expect(agents.map { !$0.timing.isLoadedAtLaunch } == true)
    }

    @Test func readsAgentsWhenNoClaudeFile() throws {
        let s = try Sandbox()
        try s.write(".claude/CLAUDE.md", "user")   // user scope does not count
        try s.write("AGENTS.md", "agents", in: s.project)
        let ctx = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(s.names(ctx) == ["~/.claude/CLAUDE.md", "~/code/app/AGENTS.md"])
    }

    @Test func localFileShadowsAgentsWithWarning() throws {
        let s = try Sandbox()
        try s.write("CLAUDE.local.md", "mine", in: s.project)
        try s.write("AGENTS.md", "agents", in: s.project)
        let ctx = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(s.names(ctx) == ["~/code/app/CLAUDE.local.md"])
        #expect(ctx.diagnostics.contains { $0.severity == .warning && $0.message.contains("CLAUDE.local.md") })
    }

    @Test func importsResolveRelativeAndStopAtFourHops() throws {
        let s = try Sandbox()
        try s.write("CLAUDE.md", "See @docs/a.md and `@not/code.md` and email me@x.com", in: s.project)
        try s.write("docs/a.md", "@b.md", in: s.project)
        try s.write("docs/b.md", "@c.md", in: s.project)
        try s.write("docs/c.md", "@d.md", in: s.project)
        try s.write("docs/d.md", "@e.md", in: s.project)
        try s.write("docs/e.md", "too deep", in: s.project)
        let ctx = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        let imported = ctx.entries.filter { $0.scope == .imported }.map(\.url.lastPathComponent)
        #expect(imported == ["a.md", "b.md", "c.md", "d.md"])
        #expect(ctx.diagnostics.contains { $0.message.contains("@e.md") })
    }

    @Test func pathScopedRulesLoadOnDemand() throws {
        let s = try Sandbox()
        try s.write(".claude/rules/always.md", "x", in: s.project)
        try s.write(".claude/rules/api.md", "---\npaths:\n  - \"src/api/**/*.ts\"\n---\nbody", in: s.project)
        let ctx = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        let rules = Dictionary(uniqueKeysWithValues: ctx.entries.filter { $0.scope == .rule }
            .map { ($0.url.lastPathComponent, $0.timing.isLoadedAtLaunch) })
        #expect(rules == ["always.md": true, "api.md": false])
    }

    @Test func autoMemoryIsKeyedByGitRootAndTruncated() throws {
        let s = try Sandbox()
        let key = ClaudeCodeResolver.projectKey(for: s.project)
        let lines = (1...250).map { "- line \($0)" }.joined(separator: "\n")
        try s.write(".claude/projects/\(key)/memory/MEMORY.md", lines)
        try s.write(".claude/projects/\(key)/memory/topic.md", "t")
        let sub = s.project.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let ctx = ClaudeCodeResolver().resolve(workingDirectory: sub, environment: s.env())
        let memory = try #require(ctx.entries.first { $0.url.lastPathComponent == "MEMORY.md" })
        #expect(memory.truncated && memory.timing.isLoadedAtLaunch)
        #expect(ctx.entries.contains { $0.url.lastPathComponent == "topic.md" && !$0.timing.isLoadedAtLaunch })

        let off = ClaudeCodeResolver().resolve(workingDirectory: sub,
                                               environment: s.env(["CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"]))
        #expect(off.entries.allSatisfy { $0.scope != .autoMemory || !$0.timing.isLoadedAtLaunch })
    }

    @Test func projectKeyMatchesClaudeCode() {
        let url = URL(fileURLWithPath: "/Users/me/Application Support/my.app")
        #expect(ClaudeCodeResolver.projectKey(for: url) == "-Users-me-Application-Support-my-app")
    }
}

@Suite struct CodexTests {
    @Test func overrideWinsAndOneFilePerDirectory() throws {
        let s = try Sandbox()
        try s.write(".codex/AGENTS.override.md", "override")
        try s.write(".codex/AGENTS.md", "global")
        try s.write("AGENTS.md", "root", in: s.project)
        try s.write("TEAM.md", "fallback", in: s.project)
        try s.write("pkg/TEAM.md", "fallback", in: s.project)
        try s.write(".codex/config.toml", "project_doc_fallback_filenames = [\"TEAM.md\"]\n")
        let ctx = CodexResolver().resolve(workingDirectory: s.project.appendingPathComponent("pkg"),
                                          environment: s.env())
        #expect(s.names(ctx) == ["~/.codex/AGENTS.override.md", "~/code/app/AGENTS.md", "~/code/app/pkg/TEAM.md"])
    }

    @Test func byteBudgetTruncatesThenSkips() throws {
        let s = try Sandbox()
        try s.write(".codex/config.toml", "project_doc_max_bytes = 10\n")
        try s.write("AGENTS.md", String(repeating: "a", count: 20), in: s.project)
        try s.write("pkg/AGENTS.md", "more", in: s.project)
        let ctx = CodexResolver().resolve(workingDirectory: s.project.appendingPathComponent("pkg"),
                                          environment: s.env())
        #expect(ctx.entries[0].truncated)
        #expect(!ctx.entries[1].timing.isLoadedAtLaunch)
    }

    @Test func emptyGlobalOverrideFallsThrough() throws {
        let s = try Sandbox()
        try s.write(".codex/AGENTS.override.md", "  \n")
        try s.write(".codex/AGENTS.md", "global")
        let ctx = CodexResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(s.names(ctx) == ["~/.codex/AGENTS.md"])
    }
}

@Suite struct OpenCodeTests {
    @Test func agentsBeatsClaudeAndGlobalFallsBack() throws {
        let s = try Sandbox()
        try s.write(".claude/CLAUDE.md", "claude global")
        try s.write("AGENTS.md", "agents", in: s.project)
        try s.write("CLAUDE.md", "claude", in: s.project)
        let ctx = OpenCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(s.names(ctx) == ["~/.claude/CLAUDE.md", "~/code/app/AGENTS.md"])

        let off = OpenCodeResolver().resolve(workingDirectory: s.project,
                                             environment: s.env(["OPENCODE_DISABLE_CLAUDE_CODE_PROMPT": "1"]))
        #expect(s.names(off) == ["~/code/app/AGENTS.md"])
    }

    @Test func instructionsGlobsAndRemote() throws {
        let s = try Sandbox()
        try s.write("opencode.jsonc", """
            {
              // comment
              "instructions": ["docs/*.md", "https://example.com/rules.md",],
            }
            """, in: s.project)
        try s.write("docs/a.md", "a", in: s.project)
        try s.write("docs/b.md", "b", in: s.project)
        let ctx = OpenCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        let extras = ctx.entries.filter { $0.scope == .extra }.map(\.url.lastPathComponent)
        #expect(extras == ["a.md", "b.md", "rules.md"])
    }
}

@Suite struct SupportTests {
    @Test func globs() {
        #expect(Glob.matches("src/**/*.{ts,tsx}", "src/a/b/c.tsx"))
        #expect(Glob.matches("src/**/*.ts", "src/c.ts"))
        #expect(!Glob.matches("*.md", "docs/a.md"))
    }

    @Test func tokensCountCJKPerCharacter() {
        #expect(TokenEstimator.estimate("abcd") == 1)
        #expect(TokenEstimator.estimate("\u{8BB0}\u{5FC6}") == 2)
    }
}

@Suite struct CursorTests {
    @Test func ruleTypes() throws {
        let s = try Sandbox()
        try s.write(".cursor/rules/always.mdc", "---\nalwaysApply: true\n---\nalways", in: s.project)
        try s.write(".cursor/rules/swift.mdc", "---\nglobs: *.swift, *.m\nalwaysApply: false\n---\nx", in: s.project)
        try s.write(".cursor/rules/smart.mdc", "---\ndescription: Database tips\n---\nx", in: s.project)
        try s.write(".cursor/rules/manual.mdc", "x", in: s.project)
        try s.write(".cursor/rules/plain.md", "x", in: s.project)
        try s.write("AGENTS.md", "agents", in: s.project)
        try s.write(".cursorrules", "legacy", in: s.project)
        try s.write("web/AGENTS.md", "web", in: s.project)
        try s.write("web/.cursor/rules/ui.mdc", "---\nalwaysApply: true\n---\nui", in: s.project)
        try s.write("node_modules/x/AGENTS.md", "ignored", in: s.project)

        let ctx = CursorResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(s.names(ctx) == [
            "~/code/app/.cursor/rules/always.mdc", "~/code/app/AGENTS.md", "~/code/app/.cursorrules",
        ])
        func timing(_ name: String) -> LoadTiming? {
            ctx.entries.first { $0.url.path.hasSuffix(name) }?.timing
        }
        #expect(timing("swift.mdc") == .onDemand("when files matching *.swift, *.m are in context"))
        #expect(timing("smart.mdc") == .onDemand("when the agent judges it relevant: Database tips"))
        #expect(timing("manual.mdc") == .onDemand("only when @-mentioned in chat"))
        #expect(timing("plain.md") == .skipped("Cursor only reads .mdc rule files"))
        #expect(timing("web/AGENTS.md") == .onDemand("when working in web/"))
        #expect(timing("web/.cursor/rules/ui.mdc") == .onDemand("when working in web/"))
        #expect(timing("node_modules/x/AGENTS.md") == nil)
    }

    @Test func newRuleFileIsAlwaysApplied() throws {
        let s = try Sandbox()
        let rule = try #require(NewFileOption.options(for: .cursor, project: s.project, environment: s.env())
            .first { $0.needsName })
        let url = try rule.create(name: "style")
        #expect(url.lastPathComponent == "style.mdc")
        let ctx = CursorResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(s.names(ctx).contains("~/code/app/.cursor/rules/style.mdc"))
        #expect(NewFileOption.options(for: .cursor, project: nil, environment: s.env()).isEmpty)
    }

    @Test func skillLocations() throws {
        let s = try Sandbox()
        try s.write(".cursor/skills/a/SKILL.md", "---\nname: a\ndescription: x\n---\n", in: s.project)
        try s.write(".claude/skills/b/SKILL.md", "---\nname: b\ndescription: x\n---\n")
        try s.write(".codex/skills/c/SKILL.md", "---\nname: c\ndescription: x\n---\n")
        try s.write(".cursor/skills-cursor/d/SKILL.md", "---\nname: d\ndescription: x\n---\n")
        let skills = SkillResolver.resolve(agent: .cursor, workingDirectory: s.project, environment: s.env())
        #expect(skills.map(\.name) == ["a", "b", "c", "d"])
        #expect(skills.last?.scope == .bundled)

        // New skills go where Cursor looks, in both layers.
        for project in [s.project, nil] {
            let folder = SkillResolver.newSkillFolder(named: "new", agent: .cursor, project: project, environment: s.env())
            try s.write("SKILL.md", SkillResolver.template(name: "new"), in: folder)
            let found = SkillResolver.resolve(agent: .cursor, workingDirectory: project, environment: s.env())
            #expect(found.contains { $0.url.path == folder.appendingPathComponent("SKILL.md").path })
        }
    }
}

@Suite struct CopyTests {
    /// A copied file must end up somewhere the target agent loads at launch.
    @Test func copiesLoadInTheTargetAgent() throws {
        let s = try Sandbox()
        try s.write("MEMORY.md", "remember this", in: s.project)
        let source = s.project.appendingPathComponent("MEMORY.md")

        let toClaude = try #require(CopyPlan(source: source, to: .claudeCode, project: s.project, from: .codex, environment: s.env()))
        #expect(toClaude.destination.path.hasSuffix("app/.claude/rules/codex-MEMORY.md"))
        try toClaude.apply(text: "remember this", source: source)
        let claude = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(s.names(claude).contains("~/code/app/.claude/rules/codex-MEMORY.md"))
        // A second copy gets its own name instead of overwriting.
        #expect(CopyPlan(source: source, to: .claudeCode, project: s.project, from: .codex, environment: s.env())?
            .destination.lastPathComponent == "codex-MEMORY-2.md")

        try s.write("AGENTS.md", "existing", in: s.project)
        let toCodex = try #require(CopyPlan(source: source, to: .codex, project: s.project, from: .claudeCode, environment: s.env()))
        #expect(toCodex.mode == .append && toCodex.sharedWith == [.openCode, .cursor])
        try toCodex.apply(text: "remember this", source: source)
        let agents = try String(contentsOf: s.project.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        #expect(agents.hasPrefix("existing\n\n<!-- Copied from ") && agents.hasSuffix("remember this\n"))

        let global = CopyPlan(source: source, to: .openCode, project: nil, from: nil, environment: s.env())
        #expect(global?.destination.path == s.home.appendingPathComponent(".config/opencode/AGENTS.md").path)

        // Cursor gets an always-applied rule; it has no global rule file.
        try s.write("style.md", "---\npaths: [\"*.swift\"]\n---\nUse tabs.\n", in: s.project)
        let style = s.project.appendingPathComponent("style.md")
        let toCursor = try #require(CopyPlan(source: style, to: .cursor, project: s.project, from: .claudeCode, environment: s.env()))
        #expect(toCursor.destination.path.hasSuffix("app/.cursor/rules/claudeCode-style.mdc"))
        try toCursor.apply(text: FileSupport.read(style)!, source: style)
        let written = try String(contentsOf: toCursor.destination, encoding: .utf8)
        #expect(!written.contains("paths:") && written.hasSuffix("Use tabs.\n"))
        let cursor = CursorResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(s.names(cursor).contains("~/code/app/.cursor/rules/claudeCode-style.mdc"))
        #expect(CopyPlan(source: style, to: .cursor, project: nil, from: nil, environment: s.env()) == nil)
    }
}

@Suite struct SkillTests {
    @Test func claudePersonalBeatsProject() throws {
        let s = try Sandbox()
        try s.write(".claude/skills/deploy/SKILL.md", "---\nname: deploy\ndescription: Personal deploy\n---\n")
        try s.write(".claude/skills/deploy/SKILL.md", "---\nname: deploy\ndescription: Project deploy\n---\n", in: s.project)
        try s.write(".claude/skills/lint/SKILL.md", "---\ndescription: >\n  Runs the\n  linter\n---\n", in: s.project)
        let skills = SkillResolver.resolve(agent: .claudeCode, workingDirectory: s.project, environment: s.env())
        #expect(skills.map(\.name) == ["deploy", "deploy", "lint"])
        #expect(skills[0].scope == .user && skills[0].timing.isLoadedAtLaunch)
        #expect(!skills[1].timing.isLoadedAtLaunch)
        #expect(skills[2].description == "Runs the linter")
        // The global layer leaves project skills out.
        #expect(SkillResolver.resolve(agent: .claudeCode, workingDirectory: nil, environment: s.env()).count == 1)
    }

    @Test func codexAndOpenCodeLocations() throws {
        let s = try Sandbox()
        try s.write(".agents/skills/a/SKILL.md", "---\nname: a\ndescription: x\n---\n", in: s.project)
        try s.write(".codex/skills/b/SKILL.md", "---\nname: b\ndescription: x\n---\n")
        try s.write(".codex/skills/.system/c/SKILL.md", "---\nname: c\ndescription: x\n---\n")
        try s.write(".claude/skills/d/SKILL.md", "---\nname: d\ndescription: x\n---\n", in: s.project)
        let codex = SkillResolver.resolve(agent: .codex, workingDirectory: s.project, environment: s.env())
        #expect(codex.map(\.name) == ["a", "b", "c"])
        #expect(codex.map(\.scope) == [.project, .user, .bundled])
        let open = SkillResolver.resolve(agent: .openCode, workingDirectory: s.project, environment: s.env())
        #expect(Set(open.map(\.name)) == ["a", "d"])
    }

    @Test func newRuleFileLoadsInClaude() throws {
        let s = try Sandbox()
        let rule = try #require(NewFileOption.options(for: .claudeCode, project: s.project, environment: s.env())
            .first { $0.needsName })
        let url = try rule.create(name: "style")
        try "Use tabs.".write(to: url, atomically: true, encoding: .utf8)
        let ctx = ClaudeCodeResolver().resolve(workingDirectory: s.project, environment: s.env())
        #expect(s.names(ctx).contains("~/code/app/.claude/rules/style.md"))
        #expect(throws: (any Error).self) { try rule.create(name: "style") }
    }
}
