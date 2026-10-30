import Foundation

public enum AgentID: String, CaseIterable, Codable, Sendable, Identifiable {
    case claudeCode
    case codex
    case openCode
    case cursor
    case geminiCLI
    case copilot
    case devin
    case cline

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .openCode: "OpenCode"
        case .cursor: "Cursor"
        case .geminiCLI: "Gemini CLI"
        case .copilot: "GitHub Copilot"
        case .devin: "Devin Desktop"
        case .cline: "Cline"
        }
    }
}

/// Where in the layering an instruction or memory file sits.
public enum Scope: String, Codable, Sendable, CaseIterable {
    case managed      // organization policy
    case user         // global, per user
    case project      // checked into the repository
    case local        // per user, per project, not committed
    case directory    // nested below the working directory
    case rule         // modular rule files (.claude/rules)
    case autoMemory   // written by the agent itself
    case extra        // pulled in by configuration (OpenCode `instructions`)
    case imported     // reached through an @import
    case bundled      // ships with the agent itself

    public var displayName: String {
        switch self {
        case .managed: "Managed"
        case .user: "Global"
        case .project: "Project"
        case .local: "Local"
        case .directory: "Subdirectory"
        case .rule: "Rule"
        case .autoMemory: "Auto memory"
        case .extra: "Extra"
        case .imported: "Import"
        case .bundled: "Bundled"
        }
    }
}

public enum LoadTiming: Codable, Sendable, Hashable {
    /// Loaded into context when the session starts.
    case launch
    /// Loaded later, when the agent touches something that triggers it.
    case onDemand(String)
    /// Present on disk but not loaded, for the reason given.
    case skipped(String)

    public var isLoadedAtLaunch: Bool {
        if case .launch = self { return true }
        return false
    }
}

public struct ContextEntry: Identifiable, Sendable, Hashable {
    public var id: String { url.path + "#" + String(order) }
    public var agent: AgentID
    public var url: URL
    public var scope: Scope
    public var timing: LoadTiming
    /// Position in the final prompt, 0-based, among entries of this agent.
    public var order: Int
    public var bytes: Int
    /// Tokens that actually reach the context (after truncation).
    public var tokens: Int
    public var truncated: Bool
    public var importedBy: URL?
    public var note: String?

    public init(agent: AgentID, url: URL, scope: Scope, timing: LoadTiming, order: Int = 0,
                bytes: Int = 0, tokens: Int = 0, truncated: Bool = false,
                importedBy: URL? = nil, note: String? = nil) {
        self.agent = agent
        self.url = url
        self.scope = scope
        self.timing = timing
        self.order = order
        self.bytes = bytes
        self.tokens = tokens
        self.truncated = truncated
        self.importedBy = importedBy
        self.note = note
    }
}

public struct Diagnostic: Identifiable, Sendable, Hashable {
    public enum Severity: String, Sendable, Comparable {
        case info, warning, error
        public static func < (a: Severity, b: Severity) -> Bool {
            let rank: [Severity: Int] = [.info: 0, .warning: 1, .error: 2]
            return rank[a]! < rank[b]!
        }
    }

    /// Which part of the context a note is about, so it can be shown there.
    public enum Topic: Sendable, Hashable {
        case launch, onDemand
    }

    public var id: String { severity.rawValue + message + (url?.path ?? "") }
    public var severity: Severity
    public var message: String
    public var url: URL?
    public var topic: Topic

    public init(_ severity: Severity, _ message: String, url: URL? = nil, topic: Topic = .launch) {
        self.severity = severity
        self.message = message
        self.url = url
        self.topic = topic
    }
}

public struct ResolvedContext: Sendable {
    public var agent: AgentID
    public var workingDirectory: URL
    public var projectRoot: URL?
    public var entries: [ContextEntry]
    public var diagnostics: [Diagnostic]
    public var skills: [Skill] = []

    public var launchTokens: Int {
        entries.filter { $0.timing.isLoadedAtLaunch }.reduce(0) { $0 + $1.tokens }
    }

    public init(agent: AgentID, workingDirectory: URL, projectRoot: URL?,
                entries: [ContextEntry], diagnostics: [Diagnostic]) {
        self.agent = agent
        self.workingDirectory = workingDirectory
        self.projectRoot = projectRoot
        self.entries = entries
        self.diagnostics = diagnostics
    }
}

/// Everything a resolver needs to know about the machine. Tests point
/// these at a temporary directory.
public struct ResolverEnvironment: Sendable {
    public var home: URL
    public var variables: [String: String]
    public var claudeManagedDirectory: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                variables: [String: String] = ProcessInfo.processInfo.environment,
                claudeManagedDirectory: URL = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode")) {
        self.home = home.standardizedFileURL
        self.variables = variables
        self.claudeManagedDirectory = claudeManagedDirectory
    }

    func flag(_ name: String) -> Bool {
        guard let v = variables[name]?.lowercased() else { return false }
        return v == "1" || v == "true" || v == "yes"
    }
}

public protocol ContextResolver: Sendable {
    var agent: AgentID { get }
    func resolve(workingDirectory: URL, environment: ResolverEnvironment) -> ResolvedContext
}

public enum Resolvers {
    public static let all: [any ContextResolver] = [
        ClaudeCodeResolver(), CodexResolver(), OpenCodeResolver(), CursorResolver(),
        GeminiResolver(), CopilotResolver(), DevinResolver(), ClineResolver(),
    ]

    public static func resolveAll(workingDirectory: URL,
                                  environment: ResolverEnvironment = .init()) -> [ResolvedContext] {
        all.map { $0.resolve(workingDirectory: workingDirectory, environment: environment) }
    }
}
