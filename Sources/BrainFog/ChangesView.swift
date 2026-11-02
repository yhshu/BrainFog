import SwiftUI
import BrainFogCore

/// Shows exactly what a change will write, file by file, before it happens.
struct ChangePreview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    let change: ChangeSet

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(change.title).font(.title2.weight(.semibold))
                Text(change.detail).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error {
                    Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).font(.callout)
                }
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(change.edits) { DiffView(edit: $0) }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Text("Earlier versions stay in each file’s History.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(change.edits.count == 1 ? "Apply Change" : "Apply \(change.edits.count) Changes") {
                    do {
                        try model.apply(change)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 360, idealHeight: 520)
    }
}

/// One file's change as a unified diff, folding long unchanged stretches.
struct DiffView: View {
    let edit: FileEdit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: edit.isNewFile ? "doc.badge.plus" : "pencil.line")
                Text(displayPath(edit.url)).font(.callout.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                Text(edit.isNewFile ? "New file" : "Changed")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    switch row {
                    case .line(let line): lineView(line)
                    case .gap(let n):
                        Text("⋯ \(n) unchanged \(n == 1 ? "line" : "lines")")
                            .font(.caption).foregroundStyle(.tertiary)
                            .padding(.vertical, 3).padding(.horizontal, 8)
                    }
                }
            }
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 8))
        }
    }

    private enum Row { case line(LineDiff.Line), gap(Int) }

    /// Changed lines with three lines of context around them.
    private var rows: [Row] {
        let lines = LineDiff.diff(edit.before ?? "", edit.after)
        let changed = lines.indices.filter { if case .same = lines[$0] { false } else { true } }
        var keep = Set<Int>()
        for i in changed { for j in max(0, i - 3)...min(lines.count - 1, i + 3) { keep.insert(j) } }
        var out: [Row] = []
        var skipped = 0
        for i in lines.indices {
            if keep.contains(i) {
                if skipped > 0 { out.append(.gap(skipped)); skipped = 0 }
                out.append(.line(lines[i]))
            } else {
                skipped += 1
            }
        }
        if skipped > 0 { out.append(.gap(skipped)) }
        return out
    }

    @ViewBuilder private func lineView(_ line: LineDiff.Line) -> some View {
        let (mark, text, color): (String, String, Color) = switch line {
        case .same(let t): (" ", t, .clear)
        case .added(let t): ("+", t, .green)
        case .removed(let t): ("−", t, .red)
        }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(mark).foregroundStyle(color == .clear ? .secondary : color).frame(width: 10)
            Text(text.isEmpty ? " " : text).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8).padding(.vertical, 1)
        .background(color.opacity(0.12))
    }
}

/// On a project page: does every agent read the shared AGENTS.md?
struct SharingCard: View {
    @Environment(AppModel.self) private var model
    let report: SharingReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Shared instructions", systemImage: "doc.on.doc")
                    .font(.headline)
                Text(summary).foregroundStyle(.secondary).font(.subheadline)
                Spacer()
                if let setup = report.setup {
                    Button(setup.title) { model.pendingChange = setup }
                        .buttonStyle(.borderedProminent)
                } else if let all = report.fixAll {
                    Button("Fix All…") { model.pendingChange = all }
                        .buttonStyle(.bordered)
                }
            }
            if report.exists {
                FlowLayout(spacing: 6) {
                    ForEach(report.statuses) { status in
                        AgentStatusChip(status: status) {
                            if let fix = status.fix { model.pendingChange = fix }
                        }
                    }
                }
            } else {
                Text("No AGENTS.md here. Codex, OpenCode, Cursor, Copilot, Devin, and Cline all read it, so one file can serve every agent.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .modifier(CardChrome())
    }

    private var summary: String {
        guard report.exists else { return "" }
        let n = report.statuses.filter(\.reads).count
        return "AGENTS.md is read by \(n) of \(report.statuses.count) agents"
    }
}

struct AgentStatusChip: View {
    let status: SharingReport.Status
    let fix: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.reads ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(status.reads ? status.agent.tint : .secondary)
            Text(status.agent.displayName).font(.callout)
            if status.fix != nil {
                Button("Fix…", action: fix).buttonStyle(.link).font(.callout)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.quaternary.opacity(status.reads ? 0.6 : 0.3), in: .capsule)
        .help(status.detail.prefix(1).capitalized + status.detail.dropFirst())
    }
}

/// On the global page: do the agents' global instructions come from one file?
struct GlobalSyncCard: View {
    @Environment(AppModel.self) private var model
    let report: GlobalSyncReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Shared global instructions", systemImage: "doc.on.doc")
                    .font(.headline)
                Text(summary).foregroundStyle(.secondary).font(.subheadline)
                Spacer()
                if let source = report.source, report.targets.contains(where: { $0.state == .drifted }),
                   let change = report.sync(from: source) {
                    Button("Sync All…") { model.pendingChange = change }
                        .buttonStyle(.borderedProminent)
                }
                sourceMenu
            }
            if report.source == nil {
                Text("Each agent has its own global file. Pick one to be the source: Claude Code imports it and the others get a copy that BrainFog keeps in step.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FlowLayout(spacing: 6) {
                // Agents that aren't installed take no part, so they aren't listed.
                ForEach(report.targets.filter { $0.state != .notInstalled }) { SyncChip(target: $0) }
            }
        }
        .modifier(CardChrome())
    }

    private var summary: String {
        guard let source = report.source else { return "not shared" }
        let synced = report.targets.filter { $0.state == .synced || $0.state == .source }.count
        let total = report.targets.filter { $0.state != .unsupported && $0.state != .notInstalled }.count
        return "from \(displayPath(source)) · \(synced) of \(total) agents in step"
    }

    private var sourceMenu: some View {
        Menu(report.source == nil ? "Use One File for All" : "Change Source") {
            ForEach(report.candidates, id: \.self) { file in
                Button {
                    model.pendingChange = report.sync(from: file)
                } label: {
                    Text(displayPath(file))
                    Text(report.targets.filter { $0.file == file }.map(\.agent.displayName).joined(separator: ", "))
                }
            }
            if report.candidates.isEmpty {
                Text("No agent has global instructions yet")
            }
        }
        .fixedSize()
    }
}

private struct SyncChip: View {
    let target: GlobalSyncReport.Target

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(target.agent.displayName).font(.callout)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: .capsule)
        .help(help)
    }

    private var symbol: String {
        switch target.state {
        case .source: "star.circle.fill"
        case .synced: "checkmark.circle.fill"
        case .drifted: "exclamationmark.triangle.fill"
        case .separate: "circle"
        case .missing, .notInstalled: "circle.dashed"
        case .unsupported: "minus.circle"
        }
    }

    private var color: Color {
        switch target.state {
        case .source, .synced: target.agent.tint
        case .drifted: .orange
        default: .secondary
        }
    }

    private var help: String {
        let file = target.file.map(displayPath) ?? ""
        return switch target.state {
        case .source: "\(file) is the source"
        case .synced: "\(file) is in step with the source"
        case .drifted: "\(file) no longer matches the source"
        case .separate: "\(file) has its own text"
        case .missing: "No \(file) yet"
        case .notInstalled: "Not installed here"
        case .unsupported: "Keeps global rules in its settings, not in a file"
        }
    }
}

/// Problems found across all agents, each with its fix when there is one.
struct HealthCard: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = false
    let issues: [HealthIssue]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack {
                    Label("Health", systemImage: "stethoscope").font(.headline)
                    Text(summary).font(.subheadline).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(issues) { issue in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(issue.severity)).foregroundStyle(color(issue.severity))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.title).font(.callout.weight(.medium))
                            Text(issue.detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if let fix = issue.fix {
                            Button("Fix…") { model.pendingChange = fix }.controlSize(.small)
                        }
                        if let url = issue.url {
                            Button("Open") {
                                let agent = issue.agents.first ?? .claudeCode
                                model.whenEditsAreSafe {
                                    model.selectedEntry = ContextEntry(agent: agent, url: url, scope: .project, timing: .launch)
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .modifier(CardChrome())
    }

    private var summary: String {
        let errors = issues.filter { $0.severity == .error }.count
        let warnings = issues.filter { $0.severity == .warning }.count
        var parts: [String] = []
        if errors > 0 { parts.append("\(errors) \(errors == 1 ? "problem" : "problems")") }
        if warnings > 0 { parts.append("\(warnings) \(warnings == 1 ? "warning" : "warnings")") }
        let rest = issues.count - errors - warnings
        if rest > 0 { parts.append("\(rest) \(rest == 1 ? "note" : "notes")") }
        return parts.joined(separator: " · ")
    }

    private func icon(_ s: Diagnostic.Severity) -> String {
        switch s { case .info: "info.circle"; case .warning: "exclamationmark.triangle"; case .error: "xmark.octagon" }
    }

    private func color(_ s: Diagnostic.Severity) -> Color {
        switch s { case .info: .secondary; case .warning: .orange; case .error: .red }
    }
}

/// Lays children out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
