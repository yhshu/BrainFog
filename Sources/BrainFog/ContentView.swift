import AppKit
import SwiftUI
import BrainFogCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            ContextLensView()
        }
        .inspector(isPresented: Binding(
            get: { model.selectedEntry != nil },
            set: { if !$0 { model.selectedEntry = nil } }
        )) {
            if let entry = model.selectedEntry {
                EditorView(entry: entry)
                    .id(entry.id)
                    .inspectorColumnWidth(min: 360, ideal: 460, max: 760)
            }
        }
        .onChange(of: model.selection) {
            model.selectedEntry = nil
            model.resolve()
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section {
                Label("Global", systemImage: "globe").tag(Place.global)
            }
            Section("Projects") {
                ForEach(model.projects, id: \.url) { project in
                    HStack(spacing: 6) {
                        Label(project.url.lastPathComponent, systemImage: "folder")
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        ForEach(AgentID.allCases.filter(project.knownBy.contains)) { agent in
                            Circle().fill(agent.tint).frame(width: 6, height: 6)
                                .help("Used with \(agent.displayName)")
                        }
                    }
                    .help(project.url.path)
                    .tag(Place.project(project.url))
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Add Project", systemImage: "plus") { pickFolder() }
            }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        if panel.runModal() == .OK, let url = panel.url { model.addProject(url) }
    }
}
