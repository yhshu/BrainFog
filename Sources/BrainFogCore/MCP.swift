import Foundation

/// One MCP server an agent is configured to start or connect to.
public struct MCPServer: Identifiable, Sendable, Hashable {
    public var id: String { agent.rawValue + file.path + "#" + name }
    public var agent: AgentID
    public var name: String
    public var scope: Scope
    /// The config file that defines it.
    public var file: URL
    public var enabled = true
    /// A project `.mcp.json` server Claude Code hasn't been told to run or
    /// skip, so it asks at the start of each session. `enabled` stays true:
    /// nothing turned it off, but it doesn't run until the user approves it.
    public var needsApproval = false
    public var command: String?
    public var args: [String] = []
    public var env: [String: String] = [:]
    public var url: String?
    /// "sse" or "http" for remote servers, when the config says.
    public var transport: String?
    public var headers: [String: String] = [:]
    public var note: String?
    /// Whether BrainFog may change or remove it in place.
    public var editable = false
    /// How its file is laid out; nil for a server not read from disk.
    var format: MCPResolver.Location.Format?

    public init(agent: AgentID, name: String, scope: Scope, file: URL) {
        self.agent = agent
        self.name = name
        self.scope = scope
        self.file = file
    }

    public var isRemote: Bool { url != nil }

    /// Whether BrainFog can turn the server on and off.
    public var canSwitch: Bool { switchKind != nil }

    enum SwitchKind { case codex, enabledKey, disabledKey, claudeSettings, geminiExcluded }

    /// Where the agent records that a server is off.
    var switchKind: SwitchKind? {
        guard editable, let format else { return nil }
        switch format {
        case .codexToml: return .codex
        case .openCode: return .enabledKey
        case .claudeUser: return nil
        case .json:
            switch agent {
            case .cline, .devin: return .disabledKey
            case .claudeCode: return file.lastPathComponent == ".mcp.json" ? .claudeSettings : nil
            case .geminiCLI: return .geminiExcluded
            default: return nil
            }
        }
    }

    /// What the server runs or connects to, in one line.
    public var summary: String {
        if let url { return url }
        return ([command ?? ""] + args).joined(separator: " ")
    }

    /// Environment or header values that look like credentials rather than
    /// references to variables.
    public var secretKeys: [String] {
        // Env and headers apart: the same name can be harmless in one and a credential in the other.
        let found = [env, headers].flatMap { values in
            values.filter { key, value in
                !value.isEmpty && !Secrets.onlyReferences(value)
                    && (Secrets.looksSecret(key: key) || Secrets.looksSecret(value: value))
            }.keys
        }
        return Set(found).sorted()
    }
}

enum Secrets {
    static func looksSecret(key: String) -> Bool {
        let k = key.lowercased()
        // "pat" only as a word of its own (GITHUB_PAT), not inside PATH.
        let words = k.split { !$0.isLetter && !$0.isNumber }
        return ["token", "secret", "key", "password", "authorization", "auth", "credential"].contains { k.contains($0) }
            || words.contains("pat")
    }

    /// Whether `value` is just references to variables (`${T}`, `$T`,
    /// `{env:T}`, `${input:t}`), perhaps after an auth scheme such as "Bearer".
    static func onlyReferences(_ value: String) -> Bool {
        let rest = value.replacingOccurrences(of: #"\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\{env:[^}]*\}"#,
                                              with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).lowercased()
        return rest != value.trimmingCharacters(in: .whitespaces).lowercased()
            && (rest.isEmpty || ["bearer", "basic", "token"].contains(rest))
    }

    /// Well-known credential prefixes.
    static func looksSecret(value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "Bearer ", with: "")
        let prefixes = ["sk-", "sk_", "ghp_", "gho_", "github_pat_", "xoxb-", "xoxp-", "AKIA", "AIza", "glpat-", "pk_live_", "rk_live_"]
        return prefixes.contains { v.hasPrefix($0) } && v.count >= 16
    }
}

/// Where each agent keeps its MCP servers, and how to read them.
public enum MCPResolver {
    public static func resolve(agent: AgentID, project: URL?,
                               environment env: ResolverEnvironment = .init()) -> [MCPServer] {
        var found: [MCPServer] = []
        for location in locations(for: agent, project: project, env: env) {
            guard let text = FileSupport.read(location.file) else { continue }
            let (off, approved) = switchState(agent: agent, location: location, text: text, env: env)
            found += location.read(text, location).map { server in
                var server = server
                server.editable = location.writable && server.scope == location.scope
                if case .codexToml = location.format, !CodexMCPToml.hasTable(server.name, in: text) {
                    server.editable = false
                }
                server.format = location.format
                if off.contains(server.name) { server.enabled = false }
                else if let approved, !approved.contains(server.name) { server.needsApproval = true }
                return server
            }
        }
        return found
    }

    /// One config file and the reader for its format.
    struct Location: Sendable {
        var file: URL
        var scope: Scope
        var format: Format
        var note: String?
        /// Whether BrainFog may add servers to it.
        var writable = true
        /// The agent whose config this is.
        var agentHint: AgentID

        enum Format: Sendable, Hashable {
            /// `{ "<key>": { name: {command, args, env, url, headers} } }`
            case json(key: String)
            /// Claude Code's `~/.claude.json`: user servers at the top, local ones per project.
            case claudeUser(project: String?)
            case openCode
            case codexToml
        }

        func read(_ text: String, _ location: Location) -> [MCPServer] {
            switch format {
            case .json(let key):
                guard let json = JSONC.object(from: text), let servers = json[key] as? [String: Any] else { return [] }
                return MCPResolver.servers(servers, location)
            case .claudeUser(let project):
                guard let json = JSONC.object(from: text) else { return [] }
                var out = MCPResolver.servers(json["mcpServers"] as? [String: Any] ?? [:], location)
                if let project, let projects = json["projects"] as? [String: Any],
                   let entry = projects[project] as? [String: Any],
                   let local = entry["mcpServers"] as? [String: Any] {
                    var l = location
                    l.scope = .local
                    l.note = "local to this project, in ~/.claude.json"
                    out += MCPResolver.servers(local, l)
                }
                return out
            case .openCode:
                guard let json = JSONC.object(from: text), let servers = json["mcp"] as? [String: Any] else { return [] }
                return servers.sorted { $0.key < $1.key }.compactMap { name, value in
                    guard let s = value as? [String: Any] else { return nil }
                    var server = MCPServer(agent: location.agentHint, name: name, scope: location.scope, file: location.file)
                    server.enabled = (s["enabled"] as? Bool) ?? true
                    if let cmd = s["command"] as? [Any], let first = cmd.first as? String {
                        server.command = first
                        server.args = MCPCopy.texts(Array(cmd.dropFirst()))
                    }
                    server.env = MCPCopy.textMap(s["environment"])
                    server.url = s["url"] as? String
                    server.headers = MCPCopy.textMap(s["headers"])
                    server.note = location.note
                    return server
                }
            case .codexToml:
                return CodexMCPToml.parse(text).map { name, table in
                    var server = MCPServer(agent: .codex, name: name, scope: location.scope, file: location.file)
                    server.command = table.strings["command"]
                    server.args = table.arrays["args"] ?? []
                    server.env = table.tables["env"] ?? [:]
                    server.url = table.strings["url"]
                    server.headers = table.tables["http_headers"] ?? [:]
                    server.enabled = table.bools["enabled"] ?? true
                    server.note = table.inline ? "written inline under [mcp_servers]; edit it by hand" : location.note
                    return server
                }
            }
        }
    }

    /// Servers an agent records as off outside their own entry, and the
    /// ones it has approved when it asks before running the rest (nil when
    /// it doesn't ask).
    static func switchState(agent: AgentID, location: Location, text: String,
                            env: ResolverEnvironment) -> (off: Set<String>, approved: Set<String>?) {
        switch agent {
        case .claudeCode where location.file.lastPathComponent == ".mcp.json":
            // Claude Code asks about a project server in neither list, unless
            // enableAllProjectMcpServers approves them all.
            let dir = location.file.deletingLastPathComponent().appendingPathComponent(".claude")
            var off = Set<String>()
            var approved: Set<String>? = []
            for name in ["settings.json", "settings.local.json"] {
                guard let t = FileSupport.read(dir.appendingPathComponent(name)) else { continue }
                if let list = JSONC.value(of: "disabledMcpjsonServers", at: [], in: t) as? [String] { off.formUnion(list) }
                if let list = JSONC.value(of: "enabledMcpjsonServers", at: [], in: t) as? [String] {
                    off.subtract(list)
                    approved?.formUnion(list)
                }
                if JSONC.value(of: "enableAllProjectMcpServers", at: [], in: t) as? Bool == true { approved = nil }
            }
            return (off, approved)
        case .geminiCLI:
            return (Set(JSONC.value(of: "excluded", at: ["mcp"], in: text) as? [String] ?? []), nil)
        default:
            return ([], nil)
        }
    }

    static func servers(_ dict: [String: Any], _ location: Location) -> [MCPServer] {
        dict.sorted { $0.key < $1.key }.compactMap { name, value in
            guard let s = value as? [String: Any] else { return nil }
            var server = MCPServer(agent: location.agentHint, name: name, scope: location.scope, file: location.file)
            server.command = s["command"] as? String
            server.args = MCPCopy.texts(s["args"])
            server.env = MCPCopy.textMap(s["env"])
            server.url = (s["url"] ?? s["httpUrl"] ?? s["serverUrl"]) as? String
            let type = (s["type"] ?? s["transport"]) as? String
            if s["httpUrl"] != nil { server.transport = "http" }
            // Cline treats a remote server without a type as SSE.
            else if location.agentHint == .cline, server.url != nil, type == nil { server.transport = "sse" }
            else if let type, ["sse", "http", "streamable-http", "streamableHttp"].contains(type) {
                server.transport = type == "sse" ? "sse" : "http"
            }
            server.headers = MCPCopy.textMap(s["headers"])
            if let disabled = s["disabled"] as? Bool { server.enabled = !disabled }
            if let enabled = s["enabled"] as? Bool { server.enabled = enabled }
            server.note = location.note
            return server
        }
    }

    static func locations(for agent: AgentID, project: URL?, env: ResolverEnvironment) -> [Location] {
        let home = env.home
        let configHome = env.variables["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config")
        let appSupport = home.appendingPathComponent("Library/Application Support")
        var out: [Location] = []
        func add(_ file: URL, _ scope: Scope, _ format: Location.Format, note: String? = nil, writable: Bool = true) {
            out.append(Location(file: file, scope: scope, format: format, note: note, writable: writable, agentHint: agent))
        }
        switch agent {
        case .claudeCode:
            add(home.appendingPathComponent(".claude.json"), .user,
                .claudeUser(project: project.map { (FileSupport.gitRoot(of: $0) ?? $0).path }),
                note: "change with `claude mcp`", writable: false)
            if let project { add(project.appendingPathComponent(".mcp.json"), .project, .json(key: "mcpServers")) }
            add(env.claudeManagedDirectory.appendingPathComponent("managed-mcp.json"), .managed,
                .json(key: "mcpServers"), writable: false)
        case .codex:
            let codexHome = env.variables["CODEX_HOME"].map {
                URL(fileURLWithPath: FileSupport.expandTilde($0, home: home))
            } ?? home.appendingPathComponent(".codex")
            add(codexHome.appendingPathComponent("config.toml"), .user, .codexToml)
            if let project {
                add(project.appendingPathComponent(".codex/config.toml"), .project, .codexToml,
                    note: "used when the project is trusted")
            }
        case .openCode:
            for name in ["opencode.json", "opencode.jsonc"] {
                add(configHome.appendingPathComponent("opencode/\(name)"), .user, .openCode)
            }
            if let project {
                for name in ["opencode.json", "opencode.jsonc"] {
                    add(project.appendingPathComponent(name), .project, .openCode)
                }
            }
        case .cursor:
            add(home.appendingPathComponent(".cursor/mcp.json"), .user, .json(key: "mcpServers"))
            if let project { add(project.appendingPathComponent(".cursor/mcp.json"), .project, .json(key: "mcpServers")) }
        case .geminiCLI:
            add(GeminiResolver.home(env).appendingPathComponent(".gemini/settings.json"), .user, .json(key: "mcpServers"))
            if let project { add(project.appendingPathComponent(".gemini/settings.json"), .project, .json(key: "mcpServers")) }
            add(URL(fileURLWithPath: "/Library/Application Support/GeminiCli/settings.json"), .managed,
                .json(key: "mcpServers"), writable: false)
        case .copilot:
            let copilotHome = env.variables["COPILOT_HOME"].map {
                URL(fileURLWithPath: FileSupport.expandTilde($0, home: home))
            } ?? home.appendingPathComponent(".copilot")
            add(copilotHome.appendingPathComponent("mcp-config.json"), .user, .json(key: "mcpServers"))
            add(appSupport.appendingPathComponent("Code/User/mcp.json"), .user, .json(key: "servers"),
                note: "VS Code; passed on to Copilot")
            if let project {
                add(project.appendingPathComponent(".github/mcp.json"), .project, .json(key: "mcpServers"))
                add(project.appendingPathComponent(".mcp.json"), .project, .json(key: "mcpServers"),
                    note: "shared with Claude Code", writable: false)
                add(project.appendingPathComponent(".vscode/mcp.json"), .project, .json(key: "servers"),
                    note: "VS Code; passed on to Copilot", writable: false)
            }
        case .devin:
            add(home.appendingPathComponent(".config/devin/mcp_config.json"), .user, .json(key: "mcpServers"))
            if let project {
                add(project.appendingPathComponent(".devin/mcp_config.json"), .project, .json(key: "mcpServers"))
                add(project.appendingPathComponent(".devin/mcp_config.local.json"), .local, .json(key: "mcpServers"),
                    note: "just for you", writable: false)
            }
            add(home.appendingPathComponent(".codeium/windsurf/mcp_config.json"), .user, .json(key: "mcpServers"),
                note: "Windsurf’s file, imported by Devin", writable: false)
        case .cline:
            let data = env.variables["CLINE_DATA_DIR"].map { URL(fileURLWithPath: FileSupport.expandTilde($0, home: home)) }
                ?? home.appendingPathComponent(".cline/data")
            add(env.variables["CLINE_MCP_SETTINGS_PATH"].map { URL(fileURLWithPath: FileSupport.expandTilde($0, home: home)) }
                    ?? data.appendingPathComponent("settings/cline_mcp_settings.json"), .user,
                .json(key: "mcpServers"), note: "Cline CLI and the newer extension")
            add(appSupport.appendingPathComponent("Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json"),
                .user, .json(key: "mcpServers"), note: "Cline in VS Code")
        }
        return out
    }

    /// The config files BrainFog may add servers to, most specific first.
    /// Config files of `agent` that exist but can't be parsed, so the agent
    /// reads no servers from them, or fails to start.
    public static func unreadableFiles(for agent: AgentID, project: URL?,
                                       environment env: ResolverEnvironment = .init()) -> [URL] {
        locations(for: agent, project: project, env: env).compactMap { l in
            if case .codexToml = l.format { return nil }
            guard let text = FileSupport.read(l.file),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines.union(["\u{FEFF}"])).isEmpty,
                  JSONC.object(from: text) == nil else { return nil }
            return l.file
        }
    }

    public static func editableFiles(for agent: AgentID, project: URL?,
                                     environment env: ResolverEnvironment = .init()) -> [MCPConfigFile] {
        let all = locations(for: agent, project: project, env: env).filter(\.writable)
        var seen = Set<Scope>()
        var out: [MCPConfigFile] = []
        // One file per layer: the one that exists, else the first.
        for scope in [Scope.project, .user] {
            guard let l = all.first(where: { $0.scope == scope && FileSupport.isFile($0.file) })
                    ?? all.first(where: { $0.scope == scope }), !seen.contains(scope) else { continue }
            seen.insert(scope)
            out.append(MCPConfigFile(file: l.file, scope: l.scope, note: l.note))
        }
        // Other writable files of a layer that already exist (VS Code's mcp.json next to Copilot CLI's).
        for l in all where FileSupport.isFile(l.file) && !out.contains(where: { $0.file == l.file }) {
            out.append(MCPConfigFile(file: l.file, scope: l.scope, note: l.note))
        }
        return out
    }

    /// The file a server copied to `agent` should go in, at the project
    /// layer when there is a project and the agent has one.
    static func target(for agent: AgentID, project: URL?, env: ResolverEnvironment) -> Location? {
        let all = locations(for: agent, project: project, env: env).filter(\.writable)
        // Within a layer, a file that already exists wins (opencode.json vs .jsonc).
        func pick(_ scope: Scope) -> Location? {
            all.first { $0.scope == scope && FileSupport.isFile($0.file) } ?? all.first { $0.scope == scope }
        }
        return (project != nil ? pick(.project) : nil) ?? pick(.user)
    }
}

/// A config file servers can be added to.
public struct MCPConfigFile: Identifiable, Sendable, Hashable {
    public var id: String { file.path }
    public var file: URL
    public var scope: Scope
    public var note: String?
}

// MARK: Adding, changing and removing servers

public enum MCPEdit {
    public enum Failure: LocalizedError {
        case noFile(AgentID)
        case nameTaken(String, URL)
        case unreadable(URL)
        case notEditable(MCPServer)
        case notFound(String, URL)
        case noSwitch(MCPServer)
        public var errorDescription: String? {
            switch self {
            case .noFile(let agent):
                agent == .claudeCode
                    ? "Claude Code keeps global servers in ~/.claude.json, which it rewrites constantly. Open a project to use its .mcp.json, or use the `claude mcp` command."
                    : "\(agent.displayName) has no MCP config file BrainFog can write here."
            case .nameTaken(let name, let file): "\(file.lastPathComponent) already has a server named “\(name)”."
            case .unreadable(let file): "\(file.lastPathComponent) couldn’t be read as \(file.pathExtension.uppercased()); it was left alone."
            case .notEditable(let server):
                server.file.lastPathComponent == ".claude.json"
                    ? "“\(server.name)” lives in ~/.claude.json, which Claude Code rewrites constantly. Use `claude mcp remove \(server.name)` instead."
                    : "BrainFog doesn’t change \(server.file.lastPathComponent) for \(server.agent.displayName)\(server.note.map { " (\($0))" } ?? "")."
            case .notFound(let name, let file): "\(file.lastPathComponent) no longer has a server named “\(name)”."
            case .noSwitch(let server):
                switch server.agent {
                case .cursor: "Cursor keeps servers on or off in its own settings (Cursor Settings → MCP), not in mcp.json."
                case .copilot: "VS Code and Copilot CLI keep servers on or off in their own state, not in the config file."
                case .claudeCode: "Claude Code’s global servers are switched with `claude mcp` or /mcp, not in a file BrainFog writes."
                default: "\(server.agent.displayName) has no on/off setting for this server that BrainFog can change."
                }
            }
        }
    }

    /// Adds `server` to `agent`'s config: to `file` when given, else to the
    /// project file when there is a project, else the global one.
    public static func add(_ server: MCPServer, to agent: AgentID, file: URL? = nil, project: URL?,
                           environment env: ResolverEnvironment = .init()) throws -> ChangeSet {
        let location: MCPResolver.Location
        if let file {
            guard let l = MCPResolver.locations(for: agent, project: project, env: env)
                    .first(where: { $0.file.standardizedFileURL == file.standardizedFileURL && $0.writable })
            else { throw Failure.noFile(agent) }
            location = l
        } else {
            guard let l = MCPResolver.target(for: agent, project: project, env: env) else { throw Failure.noFile(agent) }
            location = l
        }
        let existing = FileSupport.read(location.file)
        let after = try inserting(server, for: agent, at: location, into: existing)
        var detail = "Adds “\(server.name)” to \(display(location.file, env)). " + consequences(server, location.scope)
        if server.agent != agent, server.file.isFileURL, server.file != location.file {
            detail = "Copies “\(server.name)” from \(server.agent.displayName) to \(display(location.file, env)), in \(agent.displayName)’s format. " + consequences(server, location.scope)
        }
        return ChangeSet(title: server.agent == agent ? "Add \(server.name)" : "Add \(server.name) to \(agent.displayName)",
                         detail: detail.trimmingCharacters(in: .whitespaces),
                         edits: [FileEdit(url: location.file, before: existing, after: after)])
    }

    /// Removes `server` from the file it was read from.
    public static func remove(_ server: MCPServer, environment env: ResolverEnvironment = .init()) throws -> ChangeSet {
        guard server.editable, let format = server.format else { throw Failure.notEditable(server) }
        guard let text = FileSupport.read(server.file) else { throw Failure.notFound(server.name, server.file) }
        let after = try removing(server.name, format: format, file: server.file, from: text)
        return ChangeSet(title: "Remove \(server.name)",
                         detail: "Removes “\(server.name)” from \(display(server.file, env)). \(server.agent.displayName) stops starting it in new sessions.",
                         edits: [FileEdit(url: server.file, before: text, after: after)])
    }

    /// Replaces `old` with `new` in `old`'s file. Settings the form doesn't
    /// cover (timeouts, tool lists, auto-approve…) are kept.
    public static func replace(_ old: MCPServer, with new: MCPServer,
                               environment env: ResolverEnvironment = .init()) throws -> ChangeSet {
        guard old.editable, let format = old.format else { throw Failure.notEditable(old) }
        guard let text = FileSupport.read(old.file) else { throw Failure.notFound(old.name, old.file) }
        var after: String
        switch format {
        case .codexToml:
            guard CodexMCPToml.parse(text).contains(where: { $0.0 == old.name }) else { throw Failure.notFound(old.name, old.file) }
            if old.name != new.name, CodexMCPToml.parse(text).contains(where: { $0.0 == new.name }) {
                throw Failure.nameTaken(new.name, old.file)
            }
            let kept = CodexMCPToml.otherLines(of: old.name, in: text)
            var table = CodexMCPToml.table(for: new)
            if !kept.isEmpty { table += kept.joined(separator: "\n") + "\n" }
            after = CodexMCPToml.replacingTable(old.name, with: table, in: text)
        default:
            let key = key(for: format)
            if old.name != new.name, (JSONC.value(of: new.name, at: [key], in: text)) != nil {
                throw Failure.nameTaken(new.name, old.file)
            }
            let original = JSONC.value(of: old.name, at: [key], in: text) as? [String: Any] ?? [:]
            var entry = original
            for k in MCPCopy.controlledKeys { entry[k] = nil }
            for (k, v) in MCPCopy.shape(new, for: old.agent, format: format) {
                entry[k] = MCPCopy.keepingRaw(v, old: original[k])
            }
            // The form doesn't edit Copilot's tool list, so a narrowed one stays.
            if let tools = original["tools"] { entry["tools"] = tools }
            let merged: String?
            if old.name == new.name {
                merged = JSONC.setting(member: old.name, value: entry, at: [key], in: text)
            } else {
                merged = JSONC.removing(member: old.name, at: [key], in: text)
                    .flatMap { JSONC.inserting(member: new.name, value: entry, at: [key], in: $0) }
            }
            guard let merged else { throw Failure.unreadable(old.file) }
            after = merged
        }
        var edits = [FileEdit(url: old.file, before: text, after: after)]
        // Gemini and Claude Code record on/off by name, so a rename carries it
        // over (a server still awaiting approval has no record to carry).
        let byName = old.switchKind == .geminiExcluded || old.switchKind == .claudeSettings
        let renamedRecord = byName && old.name != new.name && !old.needsApproval
        if old.switchKind != nil, old.enabled != new.enabled || renamedRecord {
            var renamed = old
            renamed.name = new.name
            let switched = try switching(renamed, on: new.enabled, sameFileText: after, previousName: old.name)
            if switched.url == old.file { edits[0].after = switched.after }
            else if switched.after != switched.before { edits.append(switched) }
        }
        let renamed = old.name == new.name ? "" : " It is renamed to “\(new.name)”."
        return ChangeSet(title: "Change \(old.name)",
                         detail: "Updates “\(old.name)” in \(display(old.file, env)).\(renamed) " + consequences(new, old.scope),
                         edits: edits)
    }

    /// Turns `server` on or off where its agent keeps that setting.
    public static func setEnabled(_ server: MCPServer, _ on: Bool,
                                  environment env: ResolverEnvironment = .init()) throws -> ChangeSet {
        guard server.switchKind != nil else { throw Failure.noSwitch(server) }
        let edit = try switching(server, on: on, sameFileText: nil)
        let where_ = edit.url == server.file ? display(server.file, env) : "\(display(edit.url, env)), where \(server.agent.displayName) records it"
        if on && server.needsApproval {
            let runs = server.isRemote ? "connect to \(server.summary)" : "run `\(server.summary)`"
            return ChangeSet(title: "Approve \(server.name)",
                             detail: "Approves “\(server.name)” in \(where_). \(server.agent.displayName) will \(runs) in new sessions without asking you first.",
                             edits: [edit])
        }
        return ChangeSet(title: "\(on ? "Turn on" : "Turn off") \(server.name)",
                         detail: "\(on ? "Turns on" : "Turns off") “\(server.name)” in \(where_). It takes effect in new sessions.",
                         edits: [edit])
    }

    /// The edit that switches `server`. `sameFileText` is the server's file
    /// as an earlier edit in the same change leaves it; a record kept under
    /// `previousName` (before a rename) is dropped.
    static func switching(_ server: MCPServer, on: Bool, sameFileText: String?,
                          previousName: String? = nil) throws -> FileEdit {
        let names: Set<String> = [server.name, previousName ?? server.name]
        guard let kind = server.switchKind, let format = server.format else { throw Failure.noSwitch(server) }
        if kind == .claudeSettings {
            // Approvals for a project's .mcp.json live in .claude/settings.local.json.
            let file = server.file.deletingLastPathComponent().appendingPathComponent(".claude/settings.local.json")
            let before = FileSupport.read(file)
            var text = before ?? "{\n}\n"
            var disabled = JSONC.value(of: "disabledMcpjsonServers", at: [], in: text) as? [String] ?? []
            var enabled = JSONC.value(of: "enabledMcpjsonServers", at: [], in: text) as? [String] ?? []
            disabled.removeAll { names.contains($0) }
            enabled.removeAll { names.contains($0) }
            if on { enabled.append(server.name) } else { disabled.append(server.name) }
            for (k, list) in [("enabledMcpjsonServers", enabled), ("disabledMcpjsonServers", disabled)] {
                let next = list.isEmpty ? (JSONC.removing(member: k, at: [], in: text) ?? text)
                                        : JSONC.setting(member: k, value: list, at: [], in: text)
                guard let next else { throw Failure.unreadable(file) }
                text = next
            }
            return FileEdit(url: file, before: before, after: text)
        }
        let before = FileSupport.read(server.file)
        guard let original = sameFileText ?? before else { throw Failure.notFound(server.name, server.file) }
        let key = key(for: format)
        let after: String?
        switch kind {
        case .codex:
            after = CodexMCPToml.setting("enabled", to: on ? nil : "false", in: server.name, text: original)
        case .enabledKey:
            after = JSONC.setting(member: "enabled", value: on, at: [key, server.name], in: original)
        case .disabledKey:
            after = on ? (JSONC.removing(member: "disabled", at: [key, server.name], in: original) ?? original)
                       : JSONC.setting(member: "disabled", value: true, at: [key, server.name], in: original)
        case .geminiExcluded:
            var excluded = JSONC.value(of: "excluded", at: ["mcp"], in: original) as? [String] ?? []
            excluded.removeAll { names.contains($0) }
            if !on { excluded.append(server.name) }
            after = excluded.isEmpty ? (JSONC.removing(member: "excluded", at: ["mcp"], in: original) ?? original)
                                     : JSONC.setting(member: "excluded", value: excluded, at: ["mcp"], in: original)
        case .claudeSettings:
            after = nil
        }
        guard let after else { throw Failure.unreadable(server.file) }
        return FileEdit(url: server.file, before: before, after: after)
    }

    // MARK: Text edits

    static func key(for format: MCPResolver.Location.Format) -> String {
        switch format {
        case .json(let k): k
        case .openCode: "mcp"
        default: "mcpServers"
        }
    }

    static func inserting(_ server: MCPServer, for agent: AgentID, at location: MCPResolver.Location,
                          into existing: String?) throws -> String {
        let file = location.file
        switch location.format {
        case .codexToml:
            if let existing, CodexMCPToml.parse(existing).contains(where: { $0.0 == server.name }) {
                throw Failure.nameTaken(server.name, file)
            }
            var start = existing ?? ""
            if !start.isEmpty && !start.hasSuffix("\n") { start += "\n" }
            if !start.isEmpty && !start.hasSuffix("\n\n") { start += "\n" }
            return start + CodexMCPToml.table(for: server)
        default:
            let key = key(for: location.format)
            // An empty file is as good as a missing one.
            let text = existing.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                ?? (location.format.isOpenCode ? "{\n  \"$schema\": \"https://opencode.ai/config.json\"\n}\n" : "{\n}\n")
            guard let json = JSONC.object(from: text) else { throw Failure.unreadable(file) }
            if let servers = json[key] as? [String: Any], servers[server.name] != nil {
                throw Failure.nameTaken(server.name, file)
            }
            guard let out = JSONC.inserting(member: server.name, value: MCPCopy.shape(server, for: agent, format: location.format),
                                            intoObject: key, in: text) else { throw Failure.unreadable(file) }
            return out
        }
    }

    static func removing(_ name: String, format: MCPResolver.Location.Format, file: URL, from text: String) throws -> String {
        switch format {
        case .codexToml:
            guard CodexMCPToml.parse(text).contains(where: { $0.0 == name }) else { throw Failure.notFound(name, file) }
            return CodexMCPToml.removing(name, from: text)
        default:
            guard let out = JSONC.removing(member: name, fromObject: key(for: format), in: text) else {
                throw Failure.notFound(name, file)
            }
            return out
        }
    }

    private static func consequences(_ server: MCPServer, _ scope: Scope) -> String {
        var text = scope == .project ? "This file is usually committed, so everyone on the project gets the server." : ""
        if !server.secretKeys.isEmpty {
            text += " It carries values that look like credentials (\(server.secretKeys.joined(separator: ", ")))"
            text += scope == .project ? "; move them to environment variables before committing." : "."
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func display(_ url: URL, _ env: ResolverEnvironment) -> String {
        url.path.replacingOccurrences(of: env.home.path, with: "~")
    }
}

public enum MCPCopy {
    public typealias Failure = MCPEdit.Failure

    /// The change that adds `server` to `agent`'s config.
    public static func plan(_ server: MCPServer, to agent: AgentID, project: URL?,
                            environment env: ResolverEnvironment = .init()) throws -> ChangeSet {
        try MCPEdit.add(server, to: agent, project: project, environment: env)
    }

    /// Entry keys the server form owns; anything else is left as it was.
    static let controlledKeys = ["command", "args", "env", "environment", "url", "httpUrl", "serverUrl",
                                 "headers", "type", "transport"]

    /// A JSON scalar as the form shows it: `8080` → "8080", `true` → "true".
    static func text(_ value: Any) -> String? {
        if let s = value as? String { return s }
        guard let n = value as? NSNumber else { return nil }
        return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
    }

    static func texts(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap(text)
    }

    static func textMap(_ value: Any?) -> [String: String] {
        (value as? [String: Any] ?? [:]).compactMapValues(text)
    }

    /// `new` with `old`'s values put back wherever the form shows them as
    /// text and they weren't changed, so `"PORT": 8080` stays a number.
    static func keepingRaw(_ new: Any, old: Any?) -> Any {
        if let new = new as? [String: Any], let old = old as? [String: Any] {
            return new.reduce(into: [String: Any]()) { $0[$1.key] = keepingRaw($1.value, old: old[$1.key]) }
        }
        if let new = new as? [Any], let old = old as? [Any], new.count == old.count {
            return zip(new, old).map { keepingRaw($0, old: $1) }
        }
        if let new = new as? String, let old, !(old is String), text(old) == new { return old }
        return new
    }

    /// The server in the JSON shape `agent` expects.
    static func shape(_ s: MCPServer, for agent: AgentID, format: MCPResolver.Location.Format) -> [String: Any] {
        var out: [String: Any] = [:]
        if format.isOpenCode {
            if let url = s.url {
                out["type"] = "remote"
                out["url"] = url
                if !s.headers.isEmpty { out["headers"] = s.headers }
            } else {
                out["type"] = "local"
                out["command"] = [s.command ?? ""] + s.args
                if !s.env.isEmpty { out["environment"] = s.env }
            }
            out["enabled"] = s.enabled
            return out
        }
        if let url = s.url {
            out["url"] = url
            switch agent {
            case .claudeCode, .copilot, .geminiCLI: out["type"] = s.transport ?? "http"
            case .devin: out["transport"] = s.transport ?? "http"
            case .cline: out["type"] = s.transport == "sse" ? "sse" : "streamableHttp"
            default: break
            }
            if !s.headers.isEmpty { out["headers"] = s.headers }
        } else {
            if agent == .copilot { out["type"] = isVSCode(format) ? "stdio" : "local" }
            if agent == .claudeCode { out["type"] = "stdio" }
            out["command"] = s.command ?? ""
            out["args"] = s.args
            if !s.env.isEmpty { out["env"] = s.env }
        }
        if agent == .copilot, !isVSCode(format) { out["tools"] = ["*"] }
        if !s.enabled, agent == .cline || agent == .devin { out["disabled"] = true }
        return out
    }

    private static func isVSCode(_ format: MCPResolver.Location.Format) -> Bool {
        if case .json(let key) = format { return key == "servers" }
        return false
    }

    /// The `claude mcp remove` command for a server in ~/.claude.json.
    public static func claudeRemoveCommand(for server: MCPServer) -> String {
        "claude mcp remove \(server.name) --scope \(server.scope == .local ? "local" : "user")"
    }

    /// The `claude mcp add-json` command that adds `server` to Claude Code's
    /// user scope, for when BrainFog won't touch ~/.claude.json itself.
    public static func claudeCommand(for server: MCPServer) -> String {
        let value = shape(server, for: .claudeCode, format: .json(key: "mcpServers"))
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        let json = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "'", with: "'\\''")
        return "claude mcp add-json --scope user \(server.name) '\(json)'"
    }
}

extension MCPResolver.Location.Format {
    var isOpenCode: Bool { if case .openCode = self { return true }; return false }
}

// MARK: Codex TOML

/// Reads and writes the `[mcp_servers.<name>]` tables of Codex's
/// config.toml. Handles the subset Codex documents; not a TOML parser.
enum CodexMCPToml {
    struct Table {
        var strings: [String: String] = [:]
        var arrays: [String: [String]] = [:]
        var bools: [String: Bool] = [:]
        var tables: [String: [String: String]] = [:]
        /// Written as `name = { … }` under `[mcp_servers]`.
        var inline = false
    }

    static func parse(_ text: String) -> [(String, Table)] {
        var order: [String] = []
        var tables: [String: Table] = [:]
        var current: (name: String, sub: String?)?
        // Directly under `[mcp_servers]`, where servers are inline tables.
        var inServers = false
        var pendingKey: String?
        var pending = ""
        func add(_ name: String) {
            if tables[name] == nil { tables[name] = Table(); order.append(name) }
        }
        for raw in text.components(separatedBy: "\n") {
            let line = withoutComment(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if let key = pendingKey {
                pending += " " + line
                if line.contains("]"), let name = current?.name {
                    tables[name]?.arrays[key] = strings(in: pending)
                    pendingKey = nil
                }
                continue
            }
            if let parts = headerParts(line) {
                inServers = parts == ["mcp_servers"]
                if parts.count >= 2, parts[0] == "mcp_servers" {
                    add(parts[1])
                    current = (parts[1], parts.count > 2 ? parts[2] : nil)
                } else {
                    current = nil
                }
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = unquote(String(line[..<eq]).trimmingCharacters(in: .whitespaces))
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if inServers, value.hasPrefix("{") {
                add(key)
                tables[key]?.inline = true
                for (k, v) in inlinePairs(value) { assign(v, to: unquote(k), in: &tables[key]!) }
                continue
            }
            guard let current else { continue }
            if let sub = current.sub {
                tables[current.name]?.tables[sub, default: [:]][key] = strings(in: value).first ?? value
            } else if value.hasPrefix("[") && !value.contains("]") {
                pendingKey = key; pending = value
            } else {
                assign(value, to: key, in: &tables[current.name]!)
            }
        }
        return order.map { ($0, tables[$0]!) }
    }

    /// Stores the raw TOML `value` of `key` in `table`.
    private static func assign(_ value: String, to key: String, in table: inout Table) {
        if value.hasPrefix("{") {
            table.tables[key] = inlineTable(value)
        } else if value.hasPrefix("[") {
            table.arrays[key] = strings(in: value)
        } else if value == "true" || value == "false" {
            table.bools[key] = value == "true"
        } else if let s = strings(in: value).first {
            table.strings[key] = s
        }
    }

    /// Calls `visit` with each index of `s` and whether it is inside a
    /// quoted string (quotes included); stops when `visit` returns false.
    private static func scan(_ s: String, _ visit: (String.Index, Bool) -> Bool) {
        var quote: Character?, escaped = false
        for i in s.indices {
            let c = s[i]
            var quoted = quote != nil
            if let q = quote {
                if escaped { escaped = false }
                else if q == "\"" && c == "\\" { escaped = true }
                else if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c; quoted = true
            }
            if !visit(i, quoted) { return }
        }
    }

    /// `line` without a trailing `# comment`.
    private static func withoutComment(_ line: String) -> String {
        var end = line.endIndex
        scan(line) { i, quoted in
            if !quoted && line[i] == "#" { end = i; return false }
            return true
        }
        return String(line[..<end])
    }

    /// The key of a `[table]` header line, split at its dots; nil for any
    /// other line, including `[[array]]` headers.
    private static func headerParts(_ line: String) -> [String]? {
        let t = withoutComment(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("["), !t.hasPrefix("[[") else { return nil }
        let inner = String(t.dropFirst())
        var end: String.Index?
        scan(inner) { i, quoted in
            if !quoted && inner[i] == "]" { end = i; return false }
            return true
        }
        return end.map { splitKey(String(inner[..<$0])) }
    }

    /// `a.b."c.d".'e.f'` → ["a", "b", "c.d", "e.f"]
    private static func splitKey(_ s: String) -> [String] {
        var parts: [String] = [], cur = ""
        var quote: Character?, escaped = false
        for c in s {
            if let q = quote {
                if escaped { cur.append(c); escaped = false }
                else if q == "\"" && c == "\\" { escaped = true }
                else if c == q { quote = nil }
                else { cur.append(c) }
                continue
            }
            if c == "\"" || c == "'" { quote = c; continue }
            if c == "." { parts.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; continue }
            cur.append(c)
        }
        parts.append(cur.trimmingCharacters(in: .whitespaces))
        return parts
    }

    /// The `key = value` pairs of an inline table, values left as raw TOML.
    private static func inlinePairs(_ s: String) -> [(String, String)] {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("{"), t.hasSuffix("}") else { return [] }
        let body = String(t.dropFirst().dropLast())
        var pairs: [(String, String)] = []
        var start = body.startIndex, depth = 0
        func flush(_ end: String.Index) {
            let pair = body[start..<end]
            guard let eq = pair.firstIndex(of: "=") else { return }
            pairs.append((String(pair[..<eq]).trimmingCharacters(in: .whitespaces),
                          String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces)))
        }
        scan(body) { i, quoted in
            guard !quoted else { return true }
            switch body[i] {
            case "[", "{": depth += 1
            case "]", "}": depth -= 1
            case "," where depth == 0: flush(i); start = body.index(after: i)
            default: break
            }
            return true
        }
        flush(body.endIndex)
        return pairs
    }

    private static func unquote(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func strings(in s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)"|'([^']*)'"#)
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            if let r = Range(m.range(at: 1), in: s) {
                return String(s[r]).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
            return Range(m.range(at: 2), in: s).map { String(s[$0]) }
        }
    }

    private static func inlineTable(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in inlinePairs(s) { out[unquote(k)] = strings(in: v).first ?? v }
        return out
    }

    /// `text` without the `[mcp_servers.<name>]` table and its sub-tables.
    static func removing(_ name: String, from text: String) -> String {
        var out: [String] = []
        var dropped: [String] = []
        var skipping = false
        for line in text.components(separatedBy: "\n") {
            if let parts = headerParts(line) {
                let starts = parts.count >= 2 && parts[0] == "mcp_servers" && parts[1] == name
                // The blank lines after the table go with it; the one before
                // stays, and so do comments right above the next table.
                if skipping && !starts {
                    out += dropped.reversed().prefix { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.reversed()
                }
                dropped = []
                skipping = starts
            }
            if skipping { dropped.append(line) } else { out.append(line) }
        }
        var result = out.joined(separator: "\n")
        if text.hasSuffix("\n") && !result.hasSuffix("\n") { result += "\n" }
        return result
    }

    /// The `[mcp_servers.<name>]` table with `key` set to the raw TOML
    /// `value`, or removed when nil. Nil when there is no such table.
    static func setting(_ key: String, to value: String?, in name: String, text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard let header = lines.firstIndex(where: { isHeader($0, of: name, sub: false) }) else { return nil }
        var end = header + 1
        while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
        if let i = (header + 1..<end).first(where: { keyOf(lines[$0]) == key }) {
            if let value { lines[i] = "\(key) = \(value)" } else { lines.remove(at: i) }
        } else if let value {
            // After the last setting, before the blank lines that end the table.
            var at = end
            while at > header + 1, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
            lines.insert("\(key) = \(value)", at: at)
        }
        return lines.joined(separator: "\n")
    }

    /// Lines of the server's main table that the form doesn't own.
    static func otherLines(of name: String, in text: String) -> [String] {
        let owned: Set<String> = ["command", "args", "env", "url", "http_headers", "enabled"]
        let lines = text.components(separatedBy: "\n")
        guard let header = lines.firstIndex(where: { isHeader($0, of: name, sub: false) }) else { return [] }
        var out: [String] = []
        var i = header + 1
        // Inside a multi-line array: whether its lines are kept.
        var keepingArray: Bool?
        while i < lines.count, keepingArray != nil || !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            let line = lines[i]
            i += 1
            if let keep = keepingArray {
                if keep { out.append(line) }
                if line.contains("]") { keepingArray = nil }
                continue
            }
            guard let k = keyOf(line) else { continue }
            let keep = !owned.contains(k)
            if keep { out.append(line) }
            if line.contains("[") && !line.contains("]") { keepingArray = keep }
        }
        return out
    }

    /// `text` with the server's tables replaced by `table`, in the same place.
    static func replacingTable(_ name: String, with table: String, in text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { isHeader($0, of: name, sub: true) }) else { return text + table }
        let without = removing(name, from: text).components(separatedBy: "\n")
        var out = Array(without[..<min(first, without.count)])
        out += table.components(separatedBy: "\n").dropLast()
        if first < without.count, without[first...].contains(where: { !$0.isEmpty }) {
            out.append("")
            out += without[first...]
        }
        var result = out.joined(separator: "\n")
        if text.hasSuffix("\n") && !result.hasSuffix("\n") { result += "\n" }
        return result
    }

    /// Whether `text` has a `[mcp_servers.<name>]` table, the only form
    /// BrainFog edits (not `name = { … }` under `[mcp_servers]`).
    static func hasTable(_ name: String, in text: String) -> Bool {
        text.components(separatedBy: "\n").contains { isHeader($0, of: name, sub: false) }
    }

    private static func isHeader(_ line: String, of name: String, sub: Bool) -> Bool {
        guard let parts = headerParts(line) else { return false }
        return parts.count >= 2 && parts[0] == "mcp_servers" && parts[1] == name && (sub || parts.count == 2)
    }

    private static func keyOf(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return nil }
        return unquote(String(t[..<eq]).trimmingCharacters(in: .whitespaces))
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func key(_ s: String) -> String {
        s.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil ? s : quote(s)
    }

    static func table(for s: MCPServer) -> String {
        var lines = ["[mcp_servers.\(key(s.name))]"]
        if let url = s.url {
            lines.append("url = \(quote(url))")
            if !s.headers.isEmpty {
                lines.append("http_headers = { " + s.headers.sorted { $0.key < $1.key }
                    .map { "\(key($0.key)) = \(quote($0.value))" }.joined(separator: ", ") + " }")
            }
        } else {
            lines.append("command = \(quote(s.command ?? ""))")
            if !s.args.isEmpty { lines.append("args = [" + s.args.map(quote).joined(separator: ", ") + "]") }
            if !s.env.isEmpty {
                lines.append("env = { " + s.env.sorted { $0.key < $1.key }
                    .map { "\(key($0.key)) = \(quote($0.value))" }.joined(separator: ", ") + " }")
            }
        }
        if !s.enabled { lines.append("enabled = false") }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: Inserting into JSON without disturbing it

extension JSONC {
    /// Adds `"member": value` to the top-level object `key` of `text`,
    /// creating that object if it is missing.
    static func inserting(member: String, value: Any, intoObject key: String, in text: String) -> String? {
        inserting(member: member, value: value, at: [key], in: text)
    }

    static func removing(member: String, fromObject key: String, in text: String) -> String? {
        removing(member: member, at: [key], in: text)
    }

    /// Adds `"member": value` as the first member of the object at `path`
    /// (keys from the root), creating missing objects on the way, and leaves
    /// every other character (comments, order, spacing) as it was. Nil when
    /// `text` has no root object.
    static func inserting(member: String, value: Any, at path: [String], in text: String) -> String? {
        let chars = Array(text)
        guard let open = objectStart(path, in: chars) else {
            guard let last = path.last else { return nil }
            // Replaces a non-object (`"mcpServers": null`) rather than adding a second key.
            return setting(member: last, value: [member: value], at: Array(path.dropLast()), in: text)
        }
        let indent = detectIndent(chars)
        let newline = lineEnding(chars)
        let level = path.count + 1
        let body = serialize(value, indent: indent, level: level, newline: newline)
        let next = firstCode(in: chars, from: open + 1)
        let empty = next.map { chars[$0] == "}" } ?? true
        let pad = String(repeating: indent, count: level)
        if empty, let close = next {
            return String(chars[...open]) + newline + pad + quoteKey(member) + ": " + body + newline
                + String(repeating: indent, count: level - 1) + String(chars[close...])
        }
        return String(chars[...open]) + newline + pad + quoteKey(member) + ": " + body + "," + String(chars[(open + 1)...])
    }

    /// Sets `member` of the object at `path` to `value`: in place when it
    /// exists, else added.
    static func setting(member: String, value: Any, at path: [String], in text: String) -> String? {
        let chars = Array(text)
        guard let open = objectStart(path, in: chars), let span = memberSpan(member, in: open, chars) else {
            return inserting(member: member, value: value, at: path, in: text)
        }
        let body = serialize(value, indent: detectIndent(chars), level: path.count + 1, newline: lineEnding(chars))
        return String(chars[..<span.value]) + body + String(chars[span.valueEnd...])
    }

    /// Removes `"member": …` from the object at `path`, taking its comma and
    /// line with it. Nil when there is no such member.
    static func removing(member: String, at path: [String], in text: String) -> String? {
        let chars = Array(text)
        guard let open = objectStart(path, in: chars), let span = memberSpan(member, in: open, chars) else { return nil }
        var start = span.key, end = span.valueEnd
        if let comma = span.comma {
            end = comma + 1
        } else if let previous = span.previousComma {
            start = previous
        }
        // Whole lines go when the member had them to itself.
        // isNewline throughout: "\r\n" is one Character, and not "\n".
        let lineStart = (chars[..<start].lastIndex(where: \.isNewline) ?? -1) + 1
        if start != span.previousComma, chars[lineStart..<start].allSatisfy({ $0 == " " || $0 == "\t" }) {
            var j = end
            while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
            if j < chars.count, chars[j].isNewline { start = lineStart; end = j + 1 }
        }
        return String(chars[..<start]) + String(chars[end...])
    }

    /// The value of `member` in the object at `path`, parsed.
    static func value(of member: String, at path: [String], in text: String) -> Any? {
        var node: Any? = object(from: text)
        for key in path + [member] { node = (node as? [String: Any])?[key] }
        return node
    }

    private struct MemberSpan {
        var key: Int, value: Int, valueEnd: Int
        var comma: Int?, previousComma: Int?
    }

    /// Where `member` of the object opening at `open` sits.
    private static func memberSpan(_ member: String, in open: Int, _ chars: [Character]) -> MemberSpan? {
        var i = open + 1
        var previousComma: Int?
        while let k = firstCode(in: chars, from: i), chars[k] == "\"" {
            let keyEnd = skipString(chars, k)
            guard let colon = firstCode(in: chars, from: keyEnd), chars[colon] == ":",
                  let v = firstCode(in: chars, from: colon + 1) else { return nil }
            let valueEnd = skipValue(chars, v)
            let comma = firstCode(in: chars, from: valueEnd).flatMap { chars[$0] == "," ? $0 : nil }
            let name = (try? JSONSerialization.jsonObject(with: Data(String(chars[k..<keyEnd]).utf8),
                                                          options: .fragmentsAllowed)) as? String
            if name == member {
                return MemberSpan(key: k, value: v, valueEnd: valueEnd, comma: comma, previousComma: previousComma)
            }
            guard let comma else { return nil }
            previousComma = comma
            i = comma + 1
        }
        return nil
    }

    /// Index of the `{` that opens the object at `path`; the root for [].
    private static func objectStart(_ path: [String], in chars: [Character]) -> Int? {
        guard var open = firstCode(in: chars, from: 0), chars[open] == "{" else { return nil }
        for key in path {
            guard let span = memberSpan(key, in: open, chars), chars[span.value] == "{" else { return nil }
            open = span.value
        }
        return open
    }

    /// Index just past the JSON value starting at `i`.
    private static func skipValue(_ chars: [Character], _ i: Int) -> Int {
        if chars[i] == "\"" { return skipString(chars, i) }
        if chars[i] == "{" || chars[i] == "[" {
            var depth = 0, j = i
            while j < chars.count {
                let c = chars[j]
                if c == "\"" { j = skipString(chars, j); continue }
                if c == "/" && j + 1 < chars.count && (chars[j + 1] == "/" || chars[j + 1] == "*") { j = skipComment(chars, j); continue }
                if c == "{" || c == "[" { depth += 1 }
                if c == "}" || c == "]" { depth -= 1; if depth == 0 { return j + 1 } }
                j += 1
            }
            return j
        }
        var j = i
        while j < chars.count, !chars[j].isWhitespace, !",}]/".contains(chars[j]) { j += 1 }
        return j
    }

    private static func quoteKey(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data()
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    private static func serialize(_ value: Any, indent: String, level: Int, newline: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value,
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])) ?? Data("{}".utf8)
        // It prints empty containers as "[\n\n  ]"; strings never hold a raw newline.
        let lines = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: #"\[\n\n *\]"#, with: "[]", options: .regularExpression)
            .replacingOccurrences(of: #"\{\n\n *\}"#, with: "{}", options: .regularExpression)
            .components(separatedBy: "\n")
        // JSONSerialization indents by two spaces; re-indent to match the file.
        return lines.enumerated().map { n, line in
            let spaces = line.prefix { $0 == " " }.count
            var rest = Array(line.dropFirst(spaces))
            // `"key" : value` → `"key": value`, looking only just past the key.
            if rest.first == "\"" {
                let keyEnd = skipString(rest, 0)
                if rest[keyEnd...].starts(with: [" ", ":"]) { rest.remove(at: keyEnd) }
            }
            let body = String(repeating: indent, count: spaces / 2) + String(rest)
            return n == 0 ? body : String(repeating: indent, count: level) + body
        }.joined(separator: newline)
    }

    /// "\r\n" when the file uses Windows line endings, else "\n".
    private static func lineEnding(_ chars: [Character]) -> String {
        chars.contains("\r\n") ? "\r\n" : "\n"
    }

    private static func detectIndent(_ chars: [Character]) -> String {
        let text = String(chars)
        for line in text.components(separatedBy: "\n").dropFirst() {
            let lead = line.prefix { $0 == " " || $0 == "\t" }
            if !lead.isEmpty { return lead.hasPrefix("\t") ? "\t" : String(lead) }
        }
        return "  "
    }

    /// Index of the first character at or after `i` that is not whitespace or a comment.
    private static func firstCode(in chars: [Character], from i: Int) -> Int? {
        var i = i
        while i < chars.count {
            if chars[i].isWhitespace || chars[i] == "\u{FEFF}" { i += 1; continue }
            if chars[i] == "/" && i + 1 < chars.count && (chars[i + 1] == "/" || chars[i + 1] == "*") {
                i = skipComment(chars, i); continue
            }
            return i
        }
        return nil
    }

    private static func skipComment(_ chars: [Character], _ i: Int) -> Int {
        var j = i + 2
        if chars[i + 1] == "/" {
            while j < chars.count && !chars[j].isNewline { j += 1 }
            return j
        }
        while j + 1 < chars.count && !(chars[j] == "*" && chars[j + 1] == "/") { j += 1 }
        return min(j + 2, chars.count)
    }

    /// Index just past the closing quote of the string starting at `i`.
    private static func skipString(_ chars: [Character], _ i: Int) -> Int {
        var j = i + 1
        while j < chars.count {
            if chars[j] == "\\" { j += 2; continue }
            if chars[j] == "\"" { return j + 1 }
            j += 1
        }
        return j
    }
}
