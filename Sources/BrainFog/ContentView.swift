import AppKit
import SwiftUI
import BrainFogCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var window: NSWindow?
    @State private var closeGuard: CloseGuard?
    /// How much the window grew to make room for the editor, given back on close.
    @State private var grownBy: CGFloat = 0
    @AppStorage("editorWidth") private var editorWidth = 480.0
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            // The editor is a plain column inside the detail rather than an
            // inspector: an inspector re-sections the toolbar as it opens,
            // which flashes the top bar.
            HStack(spacing: 0) {
                ContextLensView(columns: $columns)
                    .frame(minWidth: 560)
                if let entry = model.selectedEntry {
                    ColumnResizer(width: $editorWidth, range: 360...760)
                    // Keyed by file, not by list position, so a reload that
                    // reorders the list keeps the editor and its edits.
                    EditorView(entry: entry)
                        .id(entry.agent.rawValue + entry.url.path)
                        .frame(width: editorWidth)
                        .background(.background)
                }
            }
        }
        // The window grows in the same frame the editor appears, so a slide-in
        // would only show the lens widening and then narrowing again.
        .transaction(value: model.selectedEntry != nil) {
            $0.animation = nil
            $0.disablesAnimations = true
        }
        .background(WindowReader(window: $window))
        .sheet(item: Binding(get: { model.pendingChange }, set: { model.pendingChange = $0 })) { change in
            ChangePreview(change: change)
        }
        .alert("Discard unsaved changes?", isPresented: Binding(
            get: { model.pendingDiscard != nil }, set: { if !$0 { model.pendingDiscard = nil } }
        )) {
            Button("Discard", role: .destructive) {
                let action = model.pendingDiscard
                model.pendingDiscard = nil
                model.hasUnsavedEdits = false
                action?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file in the editor has edits that aren’t saved yet.")
        }
        .onChange(of: window) {
            guard let window, !(window.delegate is CloseGuard) else { return }
            let guard_ = CloseGuard(model: model, inner: window.delegate)
            window.delegate = guard_
            closeGuard = guard_
            // The toolbar is filled in after the window appears.
            DispatchQueue.main.async { fitSearchField(in: window) }
        }
        .onChange(of: model.selectedEntry != nil) { _, open in
            resizeForEditor(open: open)
        }
        .onChange(of: model.selection) {
            model.selectedEntry = nil
            model.resolve()
        }
        .task {
            // Pick up edits made elsewhere (by an agent or another editor)
            // whenever the user comes back to the app.
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                model.reloadProjects()
                model.resolve()
            }
        }
    }

    /// Opening the editor widens the window instead of squeezing the lens,
    /// growing rightward and sliding left only when the screen runs out.
    private func resizeForEditor(open: Bool) {
        guard let window, !window.styleMask.contains(.fullScreen), !window.isZoomed,
              let screen = window.screen?.visibleFrame else { return }
        var frame = window.frame
        if open {
            let room = screen.width - frame.width
            grownBy = min(editorWidth + 1, max(0, room))
            guard grownBy > 0 else { return }
            frame.size.width += grownBy
            frame.origin.x = min(frame.origin.x, screen.maxX - frame.width)
            frame.origin.x = max(frame.origin.x, screen.minX)
        } else {
            guard grownBy > 0 else { return }
            frame.size.width = max(window.minSize.width, frame.width - grownBy)
            grownBy = 0
        }
        // Animating the frame blocks the main thread until it ends, which
        // holds back the editor's contents; a single jump reads better.
        // Drawing is left to the pending SwiftUI update so the wider window
        // and the editor reach the screen together, and the toolbar's glass
        // doesn't morph through the in-between sizes.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.setFrame(frame, display: false, animate: false)
        CATransaction.commit()
    }
}

/// The toolbar's search field takes AppKit's default width, which bears no
/// relation to anything around it; make it as wide as the buttons to its
/// left so the two capsules read as a pair.
@MainActor private func fitSearchField(in window: NSWindow) {
    guard let items = window.toolbar?.items,
          let search = items.first(where: { $0 is NSSearchToolbarItem }) as? NSSearchToolbarItem else { return }
    let frames = items.compactMap { item in item.view.map { $0.convert($0.bounds, to: nil) } }
    guard let minX = frames.map(\.minX).min(), let maxX = frames.map(\.maxX).max() else { return }
    let width = maxX - minX
    search.preferredWidthForSearchField = width
    // The item caches its maximum width when it is first laid out, so
    // the preferred width alone only shows after the next toolbar rebuild.
    if let box = search.searchField.superview {
        for c in box.constraints where c.firstItem === box && c.firstAttribute == .width && c.relation == .lessThanOrEqual {
            c.constant = width
        }
    }
}

/// The divider between the lens and the editor; drag it to resize the editor.
private struct ColumnResizer: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var start: Double?

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(.rect)
                    .pointerStyle(.columnResize)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { drag in
                            let from = start ?? width
                            start = from
                            width = min(max(from - drag.translation.width, range.lowerBound), range.upperBound)
                        }
                        .onEnded { _ in start = nil })
            }
    }
}

/// Closing the window with unsaved edits asks first, as quitting does.
/// It stands in for SwiftUI's own window delegate and passes everything
/// else on to it.
@MainActor final class CloseGuard: NSObject, NSWindowDelegate {
    let model: AppModel
    weak var inner: NSWindowDelegate?

    init(model: AppModel, inner: NSWindowDelegate?) {
        self.model = model
        self.inner = inner
    }

    func windowShouldClose(_ window: NSWindow) -> Bool {
        guard model.hasUnsavedEdits else { return inner?.windowShouldClose?(window) ?? true }
        model.whenEditsAreSafe { [weak window] in window?.close() }
        return false
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || inner?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        inner?.responds(to: selector) == true ? inner : nil
    }
}

/// Hands the hosting NSWindow to SwiftUI.
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if window !== view.window { DispatchQueue.main.async { window = view.window } }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Leaving the page closes the editor, so ask first about unsaved edits.
        // ⌘-clicking the selected row would clear it and leave a blank page,
        // so there is always a page selected.
        List(selection: Binding(get: { model.selection }, set: { place in
            guard let place else { return }
            model.whenEditsAreSafe { model.selection = place }
        })) {
            Label("Global", systemImage: "globe").tag(Place.global)
            Section("Projects") {
                ForEach(model.projects, id: \.url) { project in
                    Text(project.url.lastPathComponent)
                        .lineLimit(1)
                        .help(project.url.path)
                        .tag(Place.project(project.url))
                        .contextMenu { menu(for: project.url) }
                }
            }
        }
        // At the foot of the sidebar, as in Finder and Mail, rather than in
        // the toolbar: a toolbar item in the sidebar column has to morph
        // away with the column, which stalls every frame of hiding it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button("Add Project", systemImage: "plus") { pickFolder() }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderless)
                    .help("Add a project folder")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder private func menu(for url: URL) -> some View {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Divider()
        // Only BrainFog forgets the project; nothing on disk changes, and
        // adding the folder again brings it back.
        Button("Remove from BrainFog") { model.removeProject(url) }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        if panel.runModal() == .OK, let url = panel.url { model.addProject(url) }
    }
}
