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
        /// Missing in packs made before it was recorded, meaning on.
        public var enabled: Bool?
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

        /// `resolving: false` keeps a link's own path (only its folder is resolved).
        func place(_ url: URL, resolving: Bool = true) -> (Base, String)? {
            let path = resolving ? url.resolvingSymlinksInPath().path
                : url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
            if let root {
                if let rel = relative(path, to: root) { return (.project, rel) }
                if let memory, let rel = relative(path, to: memory) { return (.claudeMemory, rel) }
                return nil
            }
            return relative(path, to: home).map { (.home, $0) }
        }

        var files: [String: File] = [:]
        func add(_ url: URL, agent: AgentID, as placed: (Base, String)? = nil) {
            guard url.isFileURL, let (base, path) = placed ?? place(url), let raw = FileSupport.read(url) else { return }
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
            // A symlinked skill folder is packed under its own name, not its target's.
            for skill in ctx.skills where skill.scope != .bundled {
                guard let (base, root) = place(skill.folder, resolving: false) else { continue }
                let prefixes = [skill.folder.standardizedFileURL.path, skill.folder.resolvingSymlinksInPath().path].map { $0 + "/" }
                for url in FileSupport.walk(skill.folder, maxDepth: 4, limit: 200, skipHidden: true,
                                            include: { FileSupport.size($0) <= History.maxBytes }) {
                    let rel = prefixes.first(where: url.path.hasPrefix).map { url.path.dropFirst($0.count) }
                    add(url, agent: ctx.agent, as: rel.map { (base, root + "/" + $0) })
                }
            }
        }

        var packed: [Server] = []
        for server in servers where place(server.file) != nil {
            var out = Server(agent: server.agent, name: server.name, command: server.command, args: server.args,
                             env: server.env, url: server.url, transport: server.transport, headers: server.headers,
                             enabled: server.enabled ? nil : false)
            // A credential becomes a reference to an environment variable of
            // the same name, which the receiving machine sets itself.
            for key in server.secretKeys {
                if out.env[key] != nil { out.env[key] = "${\(key)}" }
                if out.headers[key] != nil { out.headers[key] = "${\(key)}" }
                stripped.append("\(key) of MCP server “\(server.name)” (\(server.agent.displayName)), now ${\(key)}")
            }
            // Tokens also turn up on the command line and in URL queries.
            var names: [String] = []
            out.args = redactArgs(out.args, names: &names)
            if let url = out.url {
                let query = redactQuery(url, names: &names)
                out.url = redactPassword(query, names: &names) ?? query
            }
            for name in names {
                stripped.append("\(name) in MCP server “\(server.name)” (\(server.agent.displayName)), now ${\(name)}")
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
            // An empty or "." path names the folder itself, which can't be written.
            let parts = file.path.split(separator: "/").filter { $0 != "." }
            guard !parts.isEmpty, !parts.contains("..") else { continue }
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
                var text = try MCPEdit.inserting(server, for: packed.agent, at: location, into: current)
                // A server that was off stays off, where the agent keeps that in
                // the same file. (A Claude project server waits for approval anyway.)
                server.format = location.format
                server.editable = true
                if packed.enabled == false, server.switchKind != nil, server.switchKind != .claudeSettings {
                    text = try MCPEdit.switching(server, on: false, sameFileText: text).after
                }
                texts[location.file] = text
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

    /// True for an argument flag or query name that names a credential,
    /// matched by whole words so `--path` is not taken for a `pat`.
    private static func namesSecret(_ name: String) -> Bool {
        let words = name.lowercased().split { !$0.isLetter && !$0.isNumber }
        return words.contains { ["token", "secret", "key", "apikey", "password", "passwd", "auth",
                                 "authorization", "credential", "credentials", "pat", "cookie"].contains(String($0)) }
    }

    /// A value that is a literal credential, not a reference to a variable.
    private static func isSecretValue(_ value: String, named: Bool) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("$"), !value.hasPrefix("{env:") else { return false }
        return named || Secrets.looksSecret(value: value)
            || HealthCheck.secretPattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    /// The variable a credential becomes: `--api-key` gives `API_KEY`.
    private static func variable(_ name: String, fallback: String) -> String {
        let words = name.uppercased().split { !$0.isLetter && !$0.isNumber }
        return words.isEmpty ? fallback : words.joined(separator: "_")
    }

    /// `Authorization: Bearer xyz` (as passed to `--header`) with the value
    /// replaced by a reference to a variable, when the header names a
    /// credential; nil otherwise.
    static func redactHeader(_ s: String, names: inout [String]) -> String? {
        guard let head = s.range(of: #"^[A-Za-z][A-Za-z0-9_-]*:[ \t]*"#, options: .regularExpression) else { return nil }
        let header = String(s[..<s[head].firstIndex(of: ":")!]), value = String(s[head.upperBound...])
        guard namesSecret(header), !value.isEmpty, !value.hasPrefix("$"), !Secrets.onlyReferences(value) else { return nil }
        let name = variable(header, fallback: "TOKEN")
        names.append(name)
        return String(s[..<head.upperBound]) + "${\(name)}"
    }

    /// A URL with the password of its `user:password@` replaced by a
    /// reference to a variable; nil when it has none.
    static func redactPassword(_ url: String, names: inout [String]) -> String? {
        guard let password = Secrets.urlPassword(in: url) else { return nil }
        names.append("URL_PASSWORD")
        return url.replacingCharacters(in: password, with: "${URL_PASSWORD}")
    }

    /// Replaces credentials in `--flag value`, `--flag=value`, bare token
    /// arguments, `Name: value` headers and URL passwords with references
    /// to variables, named in `names`.
    static func redactArgs(_ args: [String], names: inout [String]) -> [String] {
        var out = args
        for i in out.indices {
            let arg = out[i]
            if arg.hasPrefix("-"), let eq = arg.firstIndex(of: "=") {
                let flag = String(arg[..<eq]), value = String(arg[arg.index(after: eq)...])
                if let v = redactHeader(value, names: &names) ?? redactPassword(value, names: &names) {
                    out[i] = flag + "=" + v
                    continue
                }
                guard isSecretValue(value, named: namesSecret(flag)) else { continue }
                let name = variable(flag, fallback: "TOKEN")
                out[i] = flag + "=${\(name)}"
                names.append(name)
            } else if !arg.hasPrefix("-") {
                if let v = redactHeader(arg, names: &names) ?? redactPassword(arg, names: &names) {
                    out[i] = v
                    continue
                }
                let flag = i > 0 && args[i - 1].hasPrefix("-") && !args[i - 1].contains("=") ? args[i - 1] : ""
                guard isSecretValue(arg, named: namesSecret(flag)) else { continue }
                let name = variable(flag, fallback: "TOKEN")
                out[i] = "${\(name)}"
                names.append(name)
            }
        }
        return out
    }

    /// Replaces credentials in a URL's query string with references to
    /// variables, named in `names`.
    static func redactQuery(_ url: String, names: inout [String]) -> String {
        guard let q = url.firstIndex(of: "?") else { return url }
        let end = url[q...].firstIndex(of: "#") ?? url.endIndex
        let items = url[url.index(after: q)..<end].split(separator: "&", omittingEmptySubsequences: false).map { item in
            guard let eq = item.firstIndex(of: "=") else { return String(item) }
            let key = String(item[..<eq]), value = String(item[item.index(after: eq)...])
            let decoded = value.removingPercentEncoding ?? value
            guard isSecretValue(decoded, named: namesSecret(key)) else { return String(item) }
            let name = variable(key, fallback: "TOKEN")
            names.append(name)
            return key + "=${\(name)}"
        }
        return url[...q] + items.joined(separator: "&") + url[end...]
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
