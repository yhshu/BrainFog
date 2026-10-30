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
    var selection: Place? = .global
    var contexts: [ResolvedContext] = []
    var selectedEntry: ContextEntry?
    var isResolving = false

    private let addedKey = "addedProjects"
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
        projects = list.sorted {
            $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }

    func addProject(_ url: URL) {
        var added = UserDefaults.standard.stringArray(forKey: addedKey) ?? []
        if !added.contains(url.path) { added.append(url.path) }
        UserDefaults.standard.set(added, forKey: addedKey)
        reloadProjects()
        selection = .project(url.standardizedFileURL)
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
                selectedEntry = result.flatMap(\.entries).first { $0.url == current.url && $0.agent == current.agent }
            }
        }
    }

    nonisolated private static func contexts(for place: Place) -> [ResolvedContext] {
        switch place {
        case .project(let url):
            return Resolvers.resolveAll(workingDirectory: url)
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
                ctx.diagnostics = ctx.diagnostics.filter { !$0.message.contains("No git root") }
                return ctx
            }
        }
    }
}
