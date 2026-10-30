import AppKit
import SwiftUI
import BrainFogCore

@main
struct BrainFogApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("BrainFog") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 680)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Rescan") { model.reloadProjects(); model.resolve() }
                    .keyboardShortcut("r")
            }
        }
    }
}

/// A SwiftPM executable starts as a background process; make it a regular
/// foreground app with a Dock icon and focused window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if let path = ProcessInfo.processInfo.environment["BRAINFOG_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Self.snapshot(to: path) }
        }
    }

    /// Development aid: writes the main window to a PNG, then quits. Renders
    /// in-process, so it needs no screen recording permission.
    @MainActor private static func snapshot(to path: String) {
        guard let view = NSApp.windows.first(where: \.isVisible)?.contentView?.superview,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

extension AgentID {
    var tint: Color {
        switch self {
        case .claudeCode: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.36, green: 0.55, blue: 0.98)
        case .openCode: Color(red: 0.30, green: 0.75, blue: 0.55)
        }
    }

    var symbol: String {
        switch self {
        case .claudeCode: "asterisk"
        case .codex: "hexagon"
        case .openCode: "chevron.left.forwardslash.chevron.right"
        }
    }
}

extension Scope {
    var symbol: String {
        switch self {
        case .managed: "building.columns"
        case .user: "globe"
        case .project: "folder"
        case .local: "person.crop.circle"
        case .directory: "folder.badge.gearshape"
        case .rule: "list.bullet.rectangle"
        case .autoMemory: "brain"
        case .extra: "plus.rectangle.on.rectangle"
        case .imported: "arrow.turn.down.right"
        }
    }
}

extension Int {
    var tokenLabel: String {
        self >= 1000 ? String(format: "%.1fk", Double(self) / 1000) : "\(self)"
    }
}
