import SwiftUI
import BrainFogCore

/// Every recorded change to the files the lens shows for this place, newest
/// first and grouped by day. A change opens to its diff and can be undone.
struct TimelineList: View {
    @Environment(AppModel.self) private var model
    let query: String
    @State private var items: [Item] = []
    @State private var loaded = false
    @State private var open: String?

    /// A change with what it did, worked out once when the list loads.
    struct Item: Identifiable {
        var change: History.Change
        var before: String
        var after: String
        var added: Int
        var removed: Int
        var id: String { change.id }
    }

    var body: some View {
        let shown = items.filter { query.isEmpty || Search.matches(query, $0.change.url.path) }
        VStack(alignment: .leading, spacing: 20) {
            if shown.isEmpty, loaded {
                if query.isEmpty {
                    ContentUnavailableView("No Changes Yet", systemImage: "clock.arrow.circlepath",
                                           description: Text("Changes show up here as you or the agents edit these files."))
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
            ForEach(days(shown), id: \.day) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(dayTitle(group.day)).font(.headline)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(group.items) { item in
                            ChangeRow(item: item, agents: agents(reading: item.change.url),
                                      isOpen: open == item.id) {
                                withAnimation { open = open == item.id ? nil : item.id }
                            }
                        }
                    }
                    .modifier(CardChrome())
                }
            }
        }
        .task(id: model.historyRevision) {
            let files = model.shownFiles
            items = await Task.detached(priority: .userInitiated) { Self.load(files) }.value
            loaded = true
        }
    }

    nonisolated private static func load(_ files: Set<URL>) -> [Item] {
        History.shared.changes(to: files).map { change in
            let before = History.shared.text(of: change.previous) ?? ""
            let after = History.shared.text(of: change.version) ?? ""
            var added = 0, removed = 0
            for line in LineDiff.diff(before, after) {
                switch line {
                case .added: added += 1
                case .removed: removed += 1
                case .same: break
                }
            }
            return Item(change: change, before: before, after: after, added: added, removed: removed)
        }
    }

    private func days(_ items: [Item]) -> [(day: Date, items: [Item])] {
        let groups = Dictionary(grouping: items) { Calendar.current.startOfDay(for: $0.change.version.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!) }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month().day().year())
    }

    private func agents(reading url: URL) -> [AgentID] {
        model.contexts.filter { ctx in
            ctx.entries.contains { $0.url.standardizedFileURL == url } || ctx.skills.contains { $0.url.standardizedFileURL == url }
        }.map(\.agent)
    }
}

private struct ChangeRow: View {
    @Environment(AppModel.self) private var model
    let item: TimelineList.Item
    let agents: [AgentID]
    let isOpen: Bool
    let toggle: () -> Void

    private var change: History.Change { item.change }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: change.version.origin == .brainFog ? "pencil" : "sparkles")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                        .padding(.top, 2)
                        .help(origin)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(change.url.lastPathComponent).font(.body.weight(.medium))
                            HStack(spacing: 2) {
                                ForEach(agents) { AgentIcon(agent: $0, size: 18).help($0.displayName) }
                            }
                            Spacer(minLength: 0)
                            Text(change.version.date.formatted(date: .omitted, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        HStack(spacing: 6) {
                            Text(displayPath(change.url, in: model.project))
                                .lineLimit(1).truncationMode(.middle)
                            Text("·")
                            Text(origin)
                            if item.added > 0 { Text("+\(item.added)").foregroundStyle(.green) }
                            if item.removed > 0 { Text("−\(item.removed)").foregroundStyle(.red) }
                        }
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(rowShape)
            }
            .buttonStyle(.plain)
            .modifier(RowChrome(tint: agents.first?.tint ?? .accentColor, isSelected: isOpen))
            if isOpen {
                DiffView(edit: FileEdit(url: change.url, before: item.before, after: item.after))
                HStack {
                    Spacer()
                    Button("Open File") {
                        model.whenEditsAreSafe {
                            model.selectedEntry = ContextEntry(agent: agents.first ?? .claudeCode, url: change.url,
                                                               scope: .project, timing: .launch)
                        }
                    }
                    Button("Undo This Change…") {
                        model.pendingChange = History.shared.undo(change)
                    }
                    .disabled(History.shared.undo(change) == nil)
                    .help("Put the file back the way it was before this change")
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
    }

    private var origin: String {
        switch change.version.origin {
        case .brainFog: "Saved in BrainFog"
        case .observed, .beforeChange: "Changed outside BrainFog"
        }
    }
}
