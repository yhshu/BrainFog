import Foundation

/// A new instruction file the user can create for an agent, placed where
/// that agent reads it at the start of every session.
public struct NewFileOption: Identifiable, Sendable, Hashable {
    public var id: String { title + url.path }
    public var title: String
    public var detail: String
    /// The file, or for a rule (`needsName`) the folder it goes in.
    public var url: URL
    public var needsName: Bool
    /// Extension and starting text for a named rule file.
    public var fileExtension = "md"
    public var template = ""
    public var exists: Bool { !needsName && FileManager.default.fileExists(atPath: url.path) }

    /// - Parameter project: the project folder, or nil for the global layer.
    public static func options(for agent: AgentID, project: URL?,
                               environment env: ResolverEnvironment = .init()) -> [NewFileOption] {
        switch agent {
        case .claudeCode:
            let claudeHome = env.home.appendingPathComponent(".claude")
            guard let project else {
                return [
                    .init(title: "CLAUDE.md", detail: "Instructions for every project",
                          url: claudeHome.appendingPathComponent("CLAUDE.md"), needsName: false),
                    .init(title: "Rule File…", detail: "A separate file of instructions for every project",
                          url: claudeHome.appendingPathComponent("rules"), needsName: true),
                ]
            }
            return [
                .init(title: "CLAUDE.md", detail: "Shared with everyone on the project",
                      url: project.appendingPathComponent("CLAUDE.md"), needsName: false),
                .init(title: "CLAUDE.local.md", detail: "Just for you; add it to .gitignore",
                      url: project.appendingPathComponent("CLAUDE.local.md"), needsName: false),
                .init(title: "Rule File…", detail: "A separate file of instructions for this project",
                      url: project.appendingPathComponent(".claude/rules"), needsName: true),
            ]
        case .codex:
            let codexHome = env.codexHome
            return [project.map {
                .init(title: "AGENTS.md", detail: "Also read by other agents",
                      url: $0.appendingPathComponent("AGENTS.md"), needsName: false)
            } ?? .init(title: "AGENTS.md", detail: "Instructions for every project",
                       url: codexHome.appendingPathComponent("AGENTS.md"), needsName: false)]
        case .openCode:
            let configHome = env.variables["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
                ?? env.home.appendingPathComponent(".config")
            return [project.map {
                .init(title: "AGENTS.md", detail: "Also read by other agents",
                      url: $0.appendingPathComponent("AGENTS.md"), needsName: false)
            } ?? .init(title: "AGENTS.md", detail: "Instructions for every project",
                       url: configHome.appendingPathComponent("opencode/AGENTS.md"), needsName: false)]
        case .cursor:
            // User Rules live in Cursor's settings, so there is no global file.
            guard let project else { return [] }
            var rule = NewFileOption(title: "Rule File…", detail: "Applied to every chat in this project",
                                     url: project.appendingPathComponent(".cursor/rules"), needsName: true)
            rule.fileExtension = "mdc"
            rule.template = "---\ndescription:\nalwaysApply: true\n---\n\n"
            return [
                .init(title: "AGENTS.md", detail: "Also read by other agents",
                      url: project.appendingPathComponent("AGENTS.md"), needsName: false),
                rule,
            ]
        case .geminiCLI:
            let geminiHome = GeminiResolver.home(env).appendingPathComponent(".gemini")
            guard let project else {
                return [.init(title: "GEMINI.md", detail: "Instructions for every project; the agent saves global notes here too",
                              url: geminiHome.appendingPathComponent("GEMINI.md"), needsName: false)]
            }
            // Antigravity drops a rule without a trigger; Gemini CLI ignores the folder.
            var rule = NewFileOption(title: "Rule File…", detail: "Applied to every Antigravity session in this project",
                                     url: project.appendingPathComponent(".agents/rules"), needsName: true)
            rule.template = "---\ntrigger: always_on\n---\n\n"
            return [
                .init(title: "GEMINI.md", detail: "Read by Gemini CLI and Antigravity in this project",
                      url: project.appendingPathComponent("GEMINI.md"), needsName: false),
                rule,
            ]
        case .copilot:
            guard let project else {
                return [.init(title: "copilot-instructions.md", detail: "Personal instructions for Copilot CLI",
                              url: env.home.appendingPathComponent(".copilot/copilot-instructions.md"), needsName: false)]
            }
            var scoped = NewFileOption(title: "Instructions File…", detail: "Applied to the files its applyTo matches",
                                       url: project.appendingPathComponent(".github/instructions"), needsName: true)
            scoped.fileExtension = "instructions.md"
            scoped.template = "---\napplyTo: \"**\"\n---\n\n"
            return [
                .init(title: "copilot-instructions.md", detail: "Applied to every request in this repository",
                      url: project.appendingPathComponent(".github/copilot-instructions.md"), needsName: false),
                .init(title: "AGENTS.md", detail: "Also read by other agents",
                      url: project.appendingPathComponent("AGENTS.md"), needsName: false),
                scoped,
            ]
        case .devin:
            guard let project else {
                return [.init(title: "AGENTS.md", detail: "Instructions for every workspace",
                              url: env.home.appendingPathComponent(".config/devin/AGENTS.md"), needsName: false)]
            }
            var rule = NewFileOption(title: "Rule File…", detail: "Applied to every session in this workspace",
                                     url: project.appendingPathComponent(".devin/rules"), needsName: true)
            rule.template = "---\ntrigger: always_on\n---\n\n"
            return [
                .init(title: "AGENTS.md", detail: "Also read by other agents",
                      url: project.appendingPathComponent("AGENTS.md"), needsName: false),
                .init(title: "AGENTS.local.md", detail: "Just for you; add it to .gitignore",
                      url: project.appendingPathComponent("AGENTS.local.md"), needsName: false),
                rule,
            ]
        case .cline:
            let globalRule = NewFileOption(title: "Rule File…", detail: "Applied in every workspace",
                                           url: env.home.appendingPathComponent("Documents/Cline/Rules"), needsName: true)
            guard let project else { return [globalRule] }
            // A plain .clinerules file can't hold a folder of rules.
            let rules = project.appendingPathComponent(".clinerules")
            if FileSupport.isFile(rules) {
                return [.init(title: ".clinerules", detail: "This workspace’s rules", url: rules, needsName: false)]
            }
            return [
                .init(title: "AGENTS.md", detail: "Also read by other agents",
                      url: project.appendingPathComponent("AGENTS.md"), needsName: false),
                .init(title: "Rule File…", detail: "Applied in this workspace", url: rules, needsName: true),
            ]
        }
    }

    /// Creates the file and returns its URL. For a rule, `name` becomes
    /// `<name>.<fileExtension>` in the rules folder. Never overwrites.
    public func create(name: String? = nil) throws -> URL {
        var file = url
        if needsName {
            var n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // The agents match the extension exactly, so `Style.MD` becomes `Style.md`.
            if n.lowercased().hasSuffix("." + fileExtension) { n = String(n.dropLast(fileExtension.count + 1)) }
            // A single file name inside the rules folder, never a path out of it.
            guard !n.isEmpty, !n.contains("/"), !n.contains(":"), !n.hasPrefix(".") else {
                throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: name ?? ""])
            }
            file = url.appendingPathComponent(n + "." + fileExtension)
        }
        if FileManager.default.fileExists(atPath: file.path) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: file.path])
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (needsName ? template : "").write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
