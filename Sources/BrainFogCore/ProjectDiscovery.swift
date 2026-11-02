import Foundation

/// Finds project folders the agents already know about, so the sidebar is
/// populated on first launch.
public enum ProjectDiscovery {
    public struct Project: Hashable, Sendable {
        public var url: URL
        public var knownBy: Set<AgentID>

        public init(url: URL, knownBy: Set<AgentID>) {
            self.url = url
            self.knownBy = knownBy
        }
    }

    /// Folders whose projects are throwaway and never listed.
    public static let transientFolders = ["/private/tmp", "/tmp", "/private/var/folders", "/var/folders"]

    public static func discover(environment env: ResolverEnvironment = .init(),
                                transient: [String] = transientFolders) -> [Project] {
        var found: [String: Set<AgentID>] = [:]
        // Keyed by the standardized path, so `/x/app` and `/x/app/` are one project.
        func add(_ path: String, _ agent: AgentID) {
            found[URL(fileURLWithPath: path).standardizedFileURL.path, default: []].insert(agent)
        }

        // Claude Code: keys of `projects` in ~/.claude.json.
        if let text = FileSupport.read(env.home.appendingPathComponent(".claude.json")),
           let json = JSONC.object(from: text), let projects = json["projects"] as? [String: Any] {
            for path in projects.keys { add(path, .claudeCode) }
        }

        // Codex: `[projects."<path>"]` tables in config.toml.
        let codexHome = env.variables["CODEX_HOME"].map {
            URL(fileURLWithPath: FileSupport.expandTilde($0, home: env.home))
        } ?? env.home.appendingPathComponent(".codex")
        if let text = FileSupport.read(codexHome.appendingPathComponent("config.toml")) {
            let re = try! NSRegularExpression(pattern: #"^\[projects\."([^"]+)"\]"#, options: .anchorsMatchLines)
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(m.range(at: 1), in: text) { add(String(text[r]), .codex) }
            }
        }

        return found.compactMap { path, agents in
            let url = URL(fileURLWithPath: path)
            guard url.path != env.home.path, FileSupport.isDirectory(url),
                  !transient.contains(where: { FileSupport.isWithin(url, URL(fileURLWithPath: $0)) }),
                  !url.path.contains("/Library/Application Support/Claude/") else { return nil }
            return Project(url: url, knownBy: agents)
        }
        .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }
}
