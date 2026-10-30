import AppKit
import SwiftUI
import BrainFogCore

/// Side-by-side view of what each agent loads for the selected place.
struct ContextLensView: View {
    @Environment(AppModel.self) private var model
    @State private var showOnDemand = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                GlassEffectContainer(spacing: 16) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(model.contexts, id: \.agent) { ctx in
                            AgentColumn(context: ctx, showOnDemand: showOnDemand)
                        }
                    }
                }
            }
            .padding(24)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(backdrop)
        .navigationTitle(model.selection?.title ?? "BrainFog")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $showOnDemand) {
                    Label("Show on-demand and unloaded", systemImage: "line.3.horizontal.decrease")
                }
                .help("Show files loaded on demand and files not loaded (shadowed or cut off)")
                Button("Rescan", systemImage: "arrow.clockwise") { model.resolve() }
            }
        }
    }

    private var subtitle: String {
        if case .project(let url) = model.selection { return url.path }
        return "Instructions and memory shared by every project"
    }

    @ViewBuilder private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(model.selection == .global ? "Global layer" : "Launch context")
                .font(.largeTitle.weight(.semibold))
            if model.isResolving { ProgressView().controlSize(.small) }
            Spacer()
        }
        Text(model.selection == .global
             ? "These files apply in every project."
             : "What each agent reads when started in this folder, in the order it enters the context.")
            .foregroundStyle(.secondary)
    }

    /// Soft agent-colored glow behind the glass so it has something to refract.
    private var backdrop: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            ForEach(Array(AgentID.allCases.enumerated()), id: \.offset) { i, agent in
                Circle()
                    .fill(agent.tint.opacity(0.18))
                    .frame(width: 520, height: 520)
                    .blur(radius: 120)
                    .offset(x: CGFloat(i - 1) * 380, y: -160)
            }
        }
        .ignoresSafeArea()
    }
}

struct AgentColumn: View {
    @Environment(AppModel.self) private var model
    let context: ResolvedContext
    let showOnDemand: Bool

    private var launched: [ContextEntry] { context.entries.filter { $0.timing.isLoadedAtLaunch } }
    private var deferred: [ContextEntry] { context.entries.filter { !$0.timing.isLoadedAtLaunch } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: context.agent.symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(context.agent.tint)
                    .frame(width: 34, height: 34)
                    .glassEffect(.regular.tint(context.agent.tint.opacity(0.25)), in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(context.agent.displayName).font(.headline)
                    Text("\(launched.count) \(launched.count == 1 ? "file" : "files") · ≈\(context.launchTokens.tokenLabel) tokens")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
            }

            TokenBar(entries: launched, tint: context.agent.tint)

            if launched.isEmpty {
                Text("No instruction files load at launch")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
            ForEach(launched) { EntryCard(entry: $0) }

            if showOnDemand && !deferred.isEmpty {
                Text("On demand / not loaded").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.top, 6)
                ForEach(deferred) { EntryCard(entry: $0) }
            }

            ForEach(context.diagnostics) { DiagnosticRow(diagnostic: $0) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

/// Each launched file's share of the agent's starting context.
struct TokenBar: View {
    let entries: [ContextEntry]
    let tint: Color

    var body: some View {
        let total = max(entries.reduce(0) { $0 + $1.tokens }, 1)
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(tint.opacity(1 - Double(i % 4) * 0.2))
                        .frame(width: max(3, geo.size.width * CGFloat(e.tokens) / CGFloat(total) - 2))
                        .help("\(e.url.lastPathComponent) · \(e.tokens.tokenLabel) tokens")
                }
            }
        }
        .frame(height: 6)
        .opacity(entries.isEmpty ? 0 : 1)
    }
}

struct EntryCard: View {
    @Environment(AppModel.self) private var model
    let entry: ContextEntry

    private var isSelected: Bool { model.selectedEntry?.id == entry.id && model.selectedEntry?.agent == entry.agent }

    var body: some View {
        Button {
            model.selectedEntry = isSelected ? nil : entry
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: entry.scope.symbol)
                    .foregroundStyle(entry.agent.tint)
                    .frame(width: 18)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.url.lastPathComponent).font(.body.weight(.medium))
                            .strikethrough(isSkipped)
                        ScopeChip(scope: entry.scope)
                        if entry.truncated {
                            Image(systemName: "scissors").font(.caption).foregroundStyle(.orange)
                                .help("Content is cut off")
                        }
                        Spacer(minLength: 0)
                        if entry.tokens > 0 {
                            Text(entry.tokens.tokenLabel).font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(displayPath).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .glassEffect(isSelected ? .regular.tint(entry.agent.tint.opacity(0.35)).interactive()
                                : .regular.interactive(),
                     in: .rect(cornerRadius: 14))
        .opacity(isSkipped ? 0.55 : 1)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.url.path, forType: .string)
            }
        }
    }

    private var isSkipped: Bool {
        if case .skipped = entry.timing { return true }
        return false
    }

    private var displayPath: String {
        guard entry.url.isFileURL else { return entry.url.absoluteString }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return entry.url.path.replacingOccurrences(of: home, with: "~")
    }

    private var detail: String? {
        var parts: [String] = []
        switch entry.timing {
        case .launch: break
        case .onDemand(let why): parts.append("On demand: \(why)")
        case .skipped(let why): parts.append("Not loaded: \(why)")
        }
        if let by = entry.importedBy { parts.append("imported by \(by.lastPathComponent)") }
        if let note = entry.note { parts.append(note) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct ScopeChip: View {
    let scope: Scope
    var body: some View {
        Text(scope.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: .capsule)
    }
}

struct DiagnosticRow: View {
    let diagnostic: Diagnostic

    var body: some View {
        Label {
            Text(diagnostic.message).font(.caption).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon).foregroundStyle(color)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: .rect(cornerRadius: 12))
    }

    private var icon: String {
        switch diagnostic.severity {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    private var color: Color {
        switch diagnostic.severity {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}
