import AppKit
import SwiftUI
import BrainFogCore

@main
struct BrainFogApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()
    @AppStorage("autoSave") private var autoSave = false

    var body: some Scene {
        WindowGroup("BrainFog") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 680)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .saveItem) {
                Toggle("Auto Save", isOn: $autoSave)
            }
            CommandGroup(after: .toolbar) {
                Button("Reload Files") { model.reloadProjects(); model.resolve() }
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
        case .cursor: Color(red: 0.62, green: 0.50, blue: 0.92)
        }
    }

    var symbol: String {
        switch self {
        case .claudeCode: "asterisk"
        case .codex: "hexagon"
        case .openCode: "chevron.left.forwardslash.chevron.right"
        case .cursor: "cursorarrow"
        }
    }
}

/// The agent's own icon, taken from its installed Mac app so BrainFog
/// ships no copies of other products' logos. CLI-only installs fall back
/// to an `AgentMark` drawn on the same app-icon grid.
struct AgentIcon: View {
    let agent: AgentID
    var size: CGFloat = 34

    var body: some View {
        if let image = Self.appIcon(for: agent) {
            Image(nsImage: image).resizable().interpolation(.high)
                .frame(width: size, height: size)
        } else {
            AgentMark(agent: agent, size: size)
        }
    }

    @MainActor private static var cache: [AgentID: NSImage?] = [:]

    @MainActor static func appIcon(for agent: AgentID) -> NSImage? {
        if let hit = cache[agent] { return hit }
        // Bundle IDs survive renames (the Codex app now installs as ChatGPT.app);
        // the file name is a fallback for builds Launch Services hasn't seen.
        let (bundleID, name) = switch agent {
        case .claudeCode: ("com.anthropic.claudefordesktop", "Claude.app")
        case .codex: ("com.openai.codex", "Codex.app")
        case .openCode: ("ai.opencode.desktop", "OpenCode.app")
        case .cursor: ("com.todesktop.230313mzl4w4u92", "Cursor.app")
        }
        let dirs = ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
            ?? dirs.map { $0 + "/" + name }.first { FileManager.default.fileExists(atPath: $0) }
        let icon = path.map { NSWorkspace.shared.icon(forFile: $0) }
        cache[agent] = icon
        return icon
    }
}

/// BrainFog's own stand-in mark for an agent: not the vendor's logo, just a
/// squircle in the agent's colours with a glyph for how it's used (a plain
/// O in a circle for OpenCode, matching its mark). Sized to
/// the macOS icon grid (824/1024 body) so it sits level with real app icons.
struct AgentMark: View {
    let agent: AgentID
    var size: CGFloat = 34

    private var body_: CGFloat { size * 824 / 1024 }

    var body: some View {
        if agent == .openCode { openCodeMark } else { squircle }
    }

    /// OpenCode's own shape: a white O inside a black circle.
    private var openCodeMark: some View {
        Circle()
            .fill(Color(white: 0.08))
            .overlay {
                Circle().strokeBorder(.white.opacity(0.18), lineWidth: max(0.5, size / 64))
            }
            .overlay {
                Circle()
                    .strokeBorder(.white, lineWidth: body_ * 0.12)
                    .padding(body_ * 0.26)
            }
            .frame(width: body_, height: body_)
            .shadow(color: .black.opacity(0.25), radius: size / 40, y: size / 80)
            .frame(width: size, height: size)
    }

    private var squircle: some View {
        RoundedRectangle(cornerRadius: body_ * 0.225, style: .continuous)
            .fill(background)
            .overlay {
                RoundedRectangle(cornerRadius: body_ * 0.225, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: max(0.5, size / 64))
            }
            .overlay { glyph }
            .frame(width: body_, height: body_)
            .shadow(color: .black.opacity(0.25), radius: size / 40, y: size / 80)
            .frame(width: size, height: size)
    }

    private var background: LinearGradient {
        let colors: [Color] = switch agent {
        case .claudeCode: [Color(red: 0.89, green: 0.53, blue: 0.40), Color(red: 0.78, green: 0.39, blue: 0.27)]
        case .codex: [Color(white: 1), Color(white: 0.93)]
        case .openCode: [Color(white: 0.12), Color(white: 0.04)]
        case .cursor: [Color(white: 0.26), Color(white: 0.12)]
        }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    @ViewBuilder private var glyph: some View {
        switch agent {
        case .claudeCode:
            Image(systemName: "asterisk")
                .font(.system(size: body_ * 0.5, weight: .bold))
                .foregroundStyle(.white)
        case .codex:
            // A terminal prompt in the black on white Codex shares with ChatGPT.
            Text(">_")
                .font(.system(size: body_ * 0.42, weight: .heavy, design: .rounded))
                .foregroundStyle(.black)
                .offset(y: -body_ * 0.03)
        case .openCode:
            EmptyView() // drawn by openCodeMark
        case .cursor:
            Image(systemName: "cursorarrow")
                .font(.system(size: body_ * 0.48, weight: .bold))
                .foregroundStyle(.white, agent.tint)
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
        case .bundled: "shippingbox"
        }
    }
}

extension Int {
    var tokenLabel: String {
        self >= 1000 ? String(format: "%.1fk", Double(self) / 1000) : "\(self)"
    }
}
