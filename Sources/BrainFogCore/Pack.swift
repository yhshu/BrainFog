import Foundation

/// A `.agentpack`: the instructions, memory, skills and MCP servers of one
/// place (a project, or the global layer), in a single JSON file that can
/// be moved to another project or machine. Credentials are taken out on
/// export, and importing shows every file it would write first.
public struct AgentPack: Codable, Sendable, Equatable {
    public static let fileExtension = "agentpack"

    /// Where a file's path starts, so it lands in the right place elsewhere.
    public enum Base: String, Codable, Sendable {
        /// The project folder.
        case project
        /// The home folder.
        case home
        /// Claude Code's auto-memory folder for the project, whose name
        /// encodes the project's path and so differs on every machine.
        case claudeMemory
    }

    public struct File: Codable, Sendable, Equatable {
        public var base: Base
        public var path: String
        public var text: String
        /// The agents that read it where it was exported.
        public var agents: [AgentID]
    }

    public struct Server: Codable, Sendable, Equatable {
        public var agent: AgentID
        public var name: String
        public var command: String?
        public var args: [String]
        public var env: [String: String]
        public var url: String?
        public var transport: String?
        public var headers: [String: String]
    }

    public var format = 1
    public var created: Date
    /// The project folder's name, or "Global".
    public var source: String
    public var files: [File]
    public var servers: [Server]
    /// What was taken out on export, one line each.
    public var stripped: [String]

    // MARK: Export

    /// Packs the files the agents read in `project` (or, with nil, in the
    /// home folder), every file of their skills there, and their servers.
    public static func export(project: URL?, contexts: [ResolvedContext], servers: [MCPServer],
                              environment env: ResolverEnvironment = .init(), date: Date = Date()) -> AgentPack {
        let home = env.home.resolvingSymlinksInPath()
        let root = project?.resolvingSymlinksInPath()
        var stripped: [String] = []

        // The folder that holds Claude's MEMORY.md, when it is in the list.
        let memory = contexts.first { $0.agent == .claudeCode }?.entries
            .first { $0.scope == .autoMemory && $0.url.lastPathComponent == "MEMORY.md" }?
            .url.deletingLastPathComponent().resolvingSymlinksInPath()

        func place(_ url: URL) -> (Base, String)? {
            let path = url.resolvingSymlinksInPath().path
            if let root {
                if let rel = relative(path, to: root) { return (.project, rel) }
                if let memory, let rel = relative(path, to: memory) { return (.claudeMemory, rel) }
                return nil
            }
            return relative(path, to: home).map { (.home, $0) }
        }

        var files: [String: File] = [:]
        func add(_ url: URL, agent: AgentID) {
            guard url.isFileURL, let (base, path) = place(url), let raw = FileSupport.read(url) else { return }
            let key = base.rawValue + ":" + path
            if files[key] != nil {
                if !files[key]!.agents.contains(agent) { files[key]!.agents.append(agent) }
                return
            }
            let (text, hits) = redact(raw)
            if hits > 0 { stripped.append("\(hits) possible \(hits == 1 ? "credential" : "credentials") in \(path)") }
            files[key] = File(base: base, path: path, text: text, agents: [agent])
        }

        for ctx in contexts {
            for entry in ctx.entries where entry.scope != .bundled {
                if case .skipped = entry.timing { continue }
                add(entry.url, agent: ctx.agent)
            }
            // A skill is its whole folder: scripts and references too.
            for skill in ctx.skills where skill.scope != .bundled && place(skill.folder) != nil {
                for url in FileSupport.walk(skill.folder, maxDepth: 4, limit: 200, skipHidden: true,
                                            include: { FileSupport.size($0) <= History.maxBytes }) {
                    add(url, agent: ctx.agent)
                }
            }
        }

        var packed: [Server] = []
        for server in servers where place(server.file) != nil {
            var out = Server(agent: server.agent, name: server.name, command: server.command, args: server.args,
                             env: server.env, url: server.url, transport: server.transport, headers: server.headers)
            // A credential becomes a reference to an environment variable of
            // the same name, which the receiving machine sets itself.
            for key in server.secretKeys {
                if out.env[key] != nil { out.env[key] = "${\(key)}" }
                if out.headers[key] != nil { out.headers[key] = "${\(key)}" }
                stripped.append("\(key) of MCP server “\(server.name)” (\(server.agent.displayName)), now ${\(key)}")
            }
            packed.append(out)
        }

        return AgentPack(created: date, source: project?.lastPathComponent ?? "Global",
                         files: files.values.sorted { ($0.base.rawValue, $0.path) < ($1.base.rawValue, $1.path) },
                         servers: packed, stripped: stripped)
    }

    // MARK: Import

    /// The writes that unpack this into `project` (or the home folder),
    /// as one change to review. Files already identical are left out, and
    /// what can't be placed is said in the detail.
    public func importChange(project: URL?, environment env: ResolverEnvironment = .init()) -> ChangeSet {
        var edits: [FileEdit] = []
        var notes: [String] = []
        let memory = project.map {
            env.home.appendingPathComponent(".claude/projects")
                .appendingPathComponent(ClaudeCodeResolver.projectKey(for: FileSupport.gitRoot(of: $0) ?? $0))
                .appendingPathComponent("memory")
        }

        var skippedProject = 0
        for file in files {
            let target: URL
            switch file.base {
            case .home: target = env.home.appendingPathComponent(file.path)
            case .project:
                guard let project else { skippedProject += 1; continue }
                target = project.appendingPathComponent(file.path)
            case .claudeMemory:
                guard let memory else { skippedProject += 1; continue }
                target = memory.appendingPathComponent(file.path)
            }
            // Never write outside the folder the path is relative to.
            guard !file.path.split(separator: "/").contains("..") else { continue }
            let existing = FileSupport.read(target)
            if existing == file.text { continue }
            edits.append(FileEdit(url: target, before: existing, after: file.text))
        }
        if skippedProject > 0 {
            notes.append("\(skippedProject) project \(skippedProject == 1 ? "file needs" : "files need") a project; open one to import \(skippedProject == 1 ? "it" : "them").")
        }

        // Servers are added one after another to each agent's config file.
        var texts: [URL: String?] = [:]
        for packed in servers {
            guard let location = MCPResolver.target(for: packed.agent, project: project, env: env) else {
                notes.append("“\(packed.name)” was not added: \(MCPEdit.Failure.noFile(packed.agent).errorDescription ?? "")")
                continue
            }
            var server = MCPServer(agent: packed.agent, name: packed.name, scope: location.scope, file: location.file)
            server.command = packed.command
            server.args = packed.args
            server.env = packed.env
            server.url = packed.url
            server.transport = packed.transport
            server.headers = packed.headers
            let current = texts[location.file] ?? FileSupport.read(location.file)
            do {
                texts[location.file] = try MCPEdit.inserting(server, for: packed.agent, at: location, into: current)
            } catch MCPEdit.Failure.nameTaken {
                notes.append("\(packed.agent.displayName) already has a server named “\(packed.name)”; it was left as is.")
            } catch {
                notes.append("“\(packed.name)” was not added: \(error.localizedDescription)")
            }
        }
        for (url, text) in texts.sorted(by: { $0.key.path < $1.key.path }) {
            guard let text else { continue }
            edits.append(FileEdit(url: url, before: FileSupport.read(url), after: text))
        }

        let replaced = edits.filter { !$0.isNewFile }.count
        var detail = "From the \(source) pack, made \(created.formatted(date: .abbreviated, time: .omitted))."
        if replaced > 0 { detail += " \(replaced) existing \(replaced == 1 ? "file is" : "files are") changed; the old text stays in History." }
        if !stripped.isEmpty { detail += " Credentials were taken out on export, so set \(stripped.count == 1 ? "it" : "them") again where needed." }
        if !notes.isEmpty { detail += " " + notes.joined(separator: " ") }
        return ChangeSet(title: "Import the \(source) agent pack?", detail: detail, edits: edits)
    }

    // MARK: Reading and writing

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> AgentPack {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgentPack.self, from: data)
    }

    // MARK: Helpers

    private static func relative(_ path: String, to root: URL) -> String? {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    /// Replaces anything that looks like a credential.
    static func redact(_ text: String) -> (String, Int) {
        let re = HealthCheck.secretPattern
        let range = NSRange(text.startIndex..., in: text)
        let hits = re.numberOfMatches(in: text, range: range)
        guard hits > 0 else { return (text, 0) }
        return (re.stringByReplacingMatches(in: text, range: range, withTemplate: "<removed credential>"), hits)
    }
}
