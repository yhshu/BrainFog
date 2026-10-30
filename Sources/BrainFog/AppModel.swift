import Foundation
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
    /// Projects the user hid from the sidebar; kept so they can be shown again.
    var hiddenProjects: [ProjectDiscovery.Project] = []
    var selection: Place? = .global
    var contexts: [ResolvedContext] = []
    var selectedEntry: ContextEntry?
    var isResolving = false

    private let addedKey = "addedProjects"
    private let hiddenKey = "hiddenProjects"
    private let removedKey = "removedProjects"
    private var resolveTask: Task<Void, Never>?

    init() {
        reloadProjects()
        resolve()
    }

    func reloadProjects() {
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
        let hidden = Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
        projects = list.filter { !hidden.contains($0.url.path) }
        hiddenProjects = list.filter { hidden.contains($0.url.path) }
    }

    func setHidden(_ url: URL, _ hide: Bool) {
        var hidden = UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []
        hidden.removeAll { $0 == url.path }
        if hide { hidden.append(url.path) }
        UserDefaults.standard.set(hidden, forKey: hiddenKey)
        if hide, selection == .project(url) { selection = .global }
        reloadProjects()
    }

    /// Drops a project from BrainFog without touching its files. Discovered
    /// projects stay out until the user adds them again.
    func removeProject(_ url: URL) {
        let defaults = UserDefaults.standard
        defaults.set((defaults.stringArray(forKey: addedKey) ?? []).filter { $0 != url.path }, forKey: addedKey)
        defaults.set((defaults.stringArray(forKey: hiddenKey) ?? []).filter { $0 != url.path }, forKey: hiddenKey)
        defaults.set((defaults.stringArray(forKey: removedKey) ?? []).filter { $0 != url.path } + [url.path], forKey: removedKey)
        if selection == .project(url) { selection = .global }
        reloadProjects()
    }

    func addProject(_ url: URL) {
        let url = url.standardizedFileURL
        let defaults = UserDefaults.standard
        defaults.set((defaults.stringArray(forKey: removedKey) ?? []).filter { $0 != url.path }, forKey: removedKey)
        var added = defaults.stringArray(forKey: addedKey) ?? []
        if !added.contains(url.path) { added.append(url.path) }
        defaults.set(added, forKey: addedKey)
        setHidden(url, false)
        selection = .project(url)
    }

    /// Re-runs every resolver for the selected place off the main actor.
    func resolve() {
        resolveTask?.cancel()
        guard let place = selection else { contexts = []; return }
        isResolving = true
        resolveTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.contexts(for: place)
            }.value
            guard !Task.isCancelled else { return }
            contexts = result
            isResolving = false
            if let current = selectedEntry {
                let all = result.flatMap { $0.entries + $0.skills.map(\.entry) }
                selectedEntry = all.first { $0.url == current.url && $0.agent == current.agent }
            }
        }
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
            let claudeHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
            return Resolvers.resolveAll(workingDirectory: probe).map { ctx in
                var ctx = ctx
                ctx.entries = ctx.entries.filter { e in
                    switch e.scope {
                    case .managed, .user: true
                    case .rule, .imported: e.url.path.hasPrefix(claudeHome)
                    case .autoMemory: e.agent == .codex
                    default: false
                    }
                }
                ctx.skills = SkillResolver.resolve(agent: ctx.agent, workingDirectory: nil)
                ctx.diagnostics = ctx.diagnostics.filter { !$0.message.contains("Not a git repository") }
                return ctx
            }
        }
    }
}
