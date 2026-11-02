import AppKit
import Foundation
import UniformTypeIdentifiers
import Observation
import BrainFogCore

enum Place: Hashable, Identifiable {
    case global
    case project(URL)

    var id: String {
        switch self {
        case .global: "global"
        case .project(let url): url.path
        }
    }

    var title: String {
        switch self {
        case .global: "Global"
        case .project(let url): url.lastPathComponent
        }
    }
}

@MainActor @Observable
final class AppModel {
    var projects: [ProjectDiscovery.Project] = []
    var selection: Place? = .global
    /// One per agent, installed agents first.
    var contexts: [ResolvedContext] = []
    /// Agents used on this Mac; the rest show as a single line until they have files.
    var installed: Set<AgentID> = []
    /// MCP servers per agent for the selected place.
    var servers: [AgentID: [MCPServer]] = [:]
    /// Whether every agent reads the project's AGENTS.md; nil on the global page.
    var sharing: SharingReport?
    /// Whether the agents' global instructions come from one file; nil on a project page.
    var globalSync: GlobalSyncReport?
    var health: [HealthIssue] = []
    var selectedEntry: ContextEntry?
    /// A change waiting for the user to review it.
    var pendingChange: ChangeSet?
    var isResolving = false
    /// The editor has text that isn't on disk yet.
    var hasUnsavedEdits = false
    /// Whether project pages also list the global files, skills and servers
    /// every project shares. Off by default, so each project shows only what
    /// is its own instead of repeating the Global page.
    var showGlobalInProjects = UserDefaults.standard.bool(forKey: "showGlobalInProjects") {
        didSet { UserDefaults.standard.set(showGlobalInProjects, forKey: "showGlobalInProjects") }
    }
    /// What to do once the user agrees to drop unsaved edits.
    var pendingDiscard: (() -> Void)?
    /// Goes up after every resolve, which records new versions in History.
    var historyRevision = 0
    /// Every file the lens shows for the selected place, including the MCP
    /// config files BrainFog can edit, so their changes reach the Timeline.
    var shownFiles: Set<URL> {
        Self.files(contexts, configFiles)
    }
    /// The MCP config files BrainFog can edit here that exist, even with no
    /// servers left in them, and the agents that read each. Files only an
    /// agent's own CLI changes (like ~/.claude.json) are left out: they are
    /// rewritten constantly.
    var configFiles: [URL: [AgentID]] = [:]

    nonisolated static func files(_ contexts: [ResolvedContext], _ configs: [URL: [AgentID]]) -> Set<URL> {
        let instructions = contexts.flatMap { $0.entries.map(\.url) + $0.skills.map(\.url) }
        return Set(instructions.filter(\.isFileURL).map(\.standardizedFileURL)).union(configs.keys)
    }

    nonisolated static func configFiles(project: URL?) -> [URL: [AgentID]] {
        var out: [URL: [AgentID]] = [:]
        for agent in AgentID.allCases {
            for file in MCPResolver.editableFiles(for: agent, project: project).map(\.file)
            where FileManager.default.fileExists(atPath: file.path) {
                out[file.standardizedFileURL, default: []].append(agent)
            }
        }
        return out
    }

    private let addedKey = "addedProjects"
    /// Projects hidden by earlier versions, which now count as removed.
    private let hiddenKey = "hiddenProjects"
    private let removedKey = "removedProjects"
    private var resolveTask: Task<Void, Never>?
    @ObservationIgnored private lazy var watcher = FileWatcher { [weak self] in self?.resolve() }

    init() {
        reloadProjects()
        // Development aid for BRAINFOG_SNAPSHOT: open on a given folder.
        if let path = ProcessInfo.processInfo.environment["BRAINFOG_SNAPSHOT_PROJECT"] {
            selection = .project(URL(fileURLWithPath: path))
        }
        resolve()
    }

    func reloadProjects() {
        let defaults = UserDefaults.standard
        if let hidden = defaults.stringArray(forKey: hiddenKey) {
            defaults.set((defaults.stringArray(forKey: removedKey) ?? []) + hidden, forKey: removedKey)
            defaults.removeObject(forKey: hiddenKey)
        }
        var list = ProjectDiscovery.discover()
        let added = (UserDefaults.standard.stringArray(forKey: addedKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { url in !list.contains { $0.url == url } }
        list += added.map { ProjectDiscovery.Project(url: $0, knownBy: []) }
        list.sort {
            $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        let removed = Set(UserDefaults.standard.stringArray(forKey: removedKey) ?? [])
        list.removeAll { removed.contains($0.url.path) }
        projects = list
    }

    /// Runs `action`, which closes or replaces the editor, right away, or
    /// after the user confirms dropping unsaved edits.
    func whenEditsAreSafe(_ action: @escaping () -> Void) {
        if hasUnsavedEdits { pendingDiscard = action } else { action() }
    }

    /// Drops a project from BrainFog without touching its files. Discovered
    /// projects stay out until the user adds them again.
    func removeProject(_ url: URL) {
        if selection == .project(url), hasUnsavedEdits {
            whenEditsAreSafe { [self] in removeProject(url) }
            return
        }
        let defaults = UserDefaults.standard
        defaults.set((defaults.stringArray(forKey: addedKey) ?? []).filter { $0 != url.path }, forKey: addedKey)
        defaults.set((defaults.stringArray(forKey: removedKey) ?? []).filter { $0 != url.path } + [url.path], forKey: removedKey)
        if selection == .project(url) { selection = .global }
        reloadProjects()
    }

    func addProject(_ url: URL) {
        if hasUnsavedEdits {
            whenEditsAreSafe { [self] in addProject(url) }
            return
        }
        let url = url.standardizedFileURL
        let defaults = UserDefaults.standard
        defaults.set((defaults.stringArray(forKey: removedKey) ?? []).filter { $0 != url.path }, forKey: removedKey)
        var added = defaults.stringArray(forKey: addedKey) ?? []
        if !added.contains(url.path) { added.append(url.path) }
        defaults.set(added, forKey: addedKey)
        reloadProjects()
        selection = .project(url)
    }

    /// Re-runs every resolver for the selected place off the main actor.
    func resolve() {
        resolveTask?.cancel()
        guard let place = selection else { contexts = []; return }
        isResolving = true
        resolveTask = Task {
            let (result, installed, servers, configs, sharing, globalSync, health) = await Task.detached(priority: .userInitiated) {
                let order = AgentID.ordered()
                let result = Self.contexts(for: place).sorted {
                    order.firstIndex(of: $0.agent)! < order.firstIndex(of: $1.agent)!
                }
                let installed = Set(AgentID.allCases.filter { $0.isInstalled() })
                let project: URL? = if case .project(let url) = place { url } else { nil }
                let servers = Dictionary(uniqueKeysWithValues: AgentID.allCases.map {
                    ($0, MCPResolver.resolve(agent: $0, project: project))
                })
                let sharing = project.map { SharingReport.analyze(project: $0, contexts: result) }
                let globalSync = project == nil ? GlobalSyncReport.analyze() : nil
                let health = HealthCheck.run(project: project, contexts: result,
                                             servers: servers.values.flatMap { $0 })
                    + HealthCheck.unreadable(project: project)
                    + (globalSync?.issues() ?? [])
                // Keep a version of every file as it is now, so changes made
                // by the agents themselves show up in each file's history.
                let configs = Self.configFiles(project: project)
                for url in Self.files(result, configs) {
                    History.shared.observe(url)
                }
                return (result, installed, servers, configs, sharing, globalSync, health)
            }.value
            guard !Task.isCancelled else { return }
            contexts = result
            self.installed = installed
            self.servers = servers
            configFiles = configs
            self.sharing = sharing
            self.globalSync = globalSync
            self.health = health
            isResolving = false
            historyRevision += 1
            watcher.watch(shownFiles.union(servers.values.flatMap { $0.map(\.file) }))
            if let current = selectedEntry {
                let all = result.flatMap { $0.entries + $0.skills.map(\.entry) }
                // A file the agent doesn't list (say, an empty one it skips)
                // stays open as long as it exists, or while it has unsaved
                // edits, so deleting it elsewhere doesn't lose them.
                selectedEntry = all.first { $0.url == current.url && $0.agent == current.agent }
                    ?? (hasUnsavedEdits || FileManager.default.fileExists(atPath: current.url.path) ? current : nil)
            }
        }
    }

    // MARK: What a page lists

    /// Global items are hidden only on a project page with the setting off.
    var hidesGlobal: Bool {
        if case .project = selection { !showGlobalInProjects } else { false }
    }

    /// The agent's files this page lists.
    func shownEntries(_ ctx: ResolvedContext) -> [ContextEntry] {
        guard hidesGlobal, case .project(let url) = selection else { return ctx.entries }
        let global = Self.globalFiles(ctx.entries, project: url)
        return ctx.entries.filter { !global.contains($0.url.path) }
    }

    func shownSkills(_ ctx: ResolvedContext) -> [Skill] {
        hidesGlobal ? ctx.skills.filter { $0.scope == .project } : ctx.skills
    }

    func shownServers(_ agent: AgentID) -> [MCPServer] {
        let all = servers[agent] ?? []
        return hidesGlobal ? all.filter { ![.managed, .user, .bundled].contains($0.scope) } : all
    }

    // MARK: Agent packs

    /// Saves this page's instructions, memory, skills and servers as a
    /// `.agentpack`, then says what was taken out.
    func exportPack() {
        let pack = AgentPack.export(project: project, contexts: contexts, servers: servers.values.flatMap { $0 })
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.packType]
        panel.nameFieldStringValue = "\(pack.source).\(AgentPack.fileExtension)"
        panel.message = "Packs the files the agents read here, their skills and their MCP servers. Credentials are taken out."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        do {
            try pack.encoded().write(to: url, options: .atomic)
            alert.messageText = "Exported \(pack.files.count) \(pack.files.count == 1 ? "file" : "files") and \(pack.servers.count) MCP \(pack.servers.count == 1 ? "server" : "servers")"
            alert.informativeText = pack.stripped.isEmpty ? "No credentials were found."
                : "Taken out:\n" + pack.stripped.map { "• " + $0 }.joined(separator: "\n")
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t export the pack"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }

    /// Reads a `.agentpack` and shows what importing it into this page
    /// would write.
    func importPack() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.packType]
        panel.message = "Choose a pack to import into \(selection?.title ?? "this page"). You’ll see every change first."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let change = try AgentPack.decode(Data(contentsOf: url)).importChange(project: project)
            guard !change.edits.isEmpty else {
                let alert = NSAlert()
                alert.messageText = "Nothing to import"
                alert.informativeText = "Everything in the pack is already here. " + change.detail
                alert.runModal()
                return
            }
            pendingChange = change
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t read the pack"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    static let packType = UTType(filenameExtension: AgentPack.fileExtension, conformingTo: .json) ?? .json

    /// Applies a reviewed change, then opens its first file unless the
    /// editor has unsaved edits.
    func apply(_ change: ChangeSet) throws {
        try change.apply()
        pendingChange = nil
        if let first = change.edits.first, !hasUnsavedEdits {
            selectedEntry = ContextEntry(agent: contexts.first { ctx in ctx.entries.contains { $0.url == first.url } }?.agent
                                            ?? .claudeCode,
                                         url: first.url, scope: .project, timing: .launch)
        }
        resolve()
    }

    /// Applies a small change the user made directly, like flipping a
    /// switch, without a preview. It is still checked for conflicts and
    /// kept in History.
    func applyNow(_ change: ChangeSet) throws {
        try change.apply()
        resolve()
    }

    /// The paths among `entries` that belong to the machine-wide layer every
    /// project shares, not to any one folder. `project`, when given, owns
    /// everything inside it.
    nonisolated static func globalFiles(_ entries: [ContextEntry], project: URL? = nil) -> Set<String> {
        let claudeHome = ResolverEnvironment.defaultHome.appendingPathComponent(".claude").path + "/"
        let inside = project.map { $0.standardizedFileURL.path + "/" }
        // Imports come right after the file that pulls them in, so one
        // pass keeps every import of a kept file, wherever it lives.
        var kept = Set<String>()
        for e in entries {
            if let inside, e.url.standardizedFileURL.path.hasPrefix(inside) { continue }
            let keep = switch e.scope {
            case .managed, .user, .bundled: true
            case .rule: e.url.path.hasPrefix(claudeHome)
            case .imported: e.importedBy.map { kept.contains($0.path) } ?? false
            case .autoMemory: e.agent == .codex
            default: false
            }
            if keep { kept.insert(e.url.path) }
        }
        return kept
    }

    nonisolated private static func contexts(for place: Place) -> [ResolvedContext] {
        switch place {
        case .project(let url):
            return Resolvers.resolveAll(workingDirectory: url).map { ctx in
                var ctx = ctx
                ctx.skills = SkillResolver.resolve(agent: ctx.agent, workingDirectory: url)
                return ctx
            }
        case .global:
            // Resolve from an empty folder so only machine-wide layers remain.
            let probe = FileManager.default.temporaryDirectory.appendingPathComponent("brainfog-global-probe")
            try? FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
            return Resolvers.resolveAll(workingDirectory: probe).map { ctx in
                var ctx = ctx
                let global = globalFiles(ctx.entries)
                ctx.entries = ctx.entries.filter { global.contains($0.url.path) }
                ctx.skills = SkillResolver.resolve(agent: ctx.agent, workingDirectory: nil)
                ctx.diagnostics = ctx.diagnostics.filter { !$0.message.contains("Not a git repository") }
                return ctx
            }
        }
    }
}
