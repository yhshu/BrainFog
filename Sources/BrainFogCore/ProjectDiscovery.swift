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

    public static func discover(environment env: ResolverEnvironment = .init()) -> [Project] {
        var found: [String: Set<AgentID>] = [:]

        // Claude Code: keys of `projects` in ~/.claude.json.
        if let text = FileSupport.read(env.home.appendingPathComponent(".claude.json")),
           let json = JSONC.object(from: text), let projects = json["projects"] as? [String: Any] {
            for path in projects.keys { found[path, default: []].insert(.claudeCode) }
        }

        // Codex: `[projects."<path>"]` tables in config.toml.
        if let text = FileSupport.read(env.home.appendingPathComponent(".codex/config.toml")) {
            let re = try! NSRegularExpression(pattern: #"^\[projects\."([^"]+)"\]"#, options: .anchorsMatchLines)
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(m.range(at: 1), in: text) { found[String(text[r]), default: []].insert(.codex) }
            }
        }

        let transient = ["/private/tmp", "/tmp", "/private/var/folders", "/var/folders"]
        return found.compactMap { path, agents in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.path != env.home.path, FileSupport.isDirectory(url),
                  !transient.contains(where: { url.path.hasPrefix($0) }),
                  !url.path.contains("/Library/Application Support/Claude/") else { return nil }
            return Project(url: url, knownBy: agents)
        }
        .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }
}
