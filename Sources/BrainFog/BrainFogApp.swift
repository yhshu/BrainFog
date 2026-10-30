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
                .onAppear { delegate.model = model }
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
    weak var model: AppModel?

    /// Quitting with the editor dirty asks first, like closing it does.
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.hasUnsavedEdits == true, NSApp.windows.contains(where: \.isVisible) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Discard unsaved changes?"
        alert.informativeText = "The file in the editor has edits that aren’t saved yet."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard and Quit").hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if ProcessInfo.processInfo.environment["BRAINFOG_SNAPSHOT_DARK"] != nil {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
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
        case .geminiCLI: Color(red: 0.93, green: 0.70, blue: 0.20)
        case .copilot: Color(red: 0.88, green: 0.36, blue: 0.62)
        case .devin: Color(red: 0.10, green: 0.70, blue: 0.72)
        case .cline: Color(red: 0.55, green: 0.58, blue: 0.66)
        }
    }

    var symbol: String {
        switch self {
        case .claudeCode: "asterisk"
        case .codex: "hexagon"
        case .openCode: "chevron.left.forwardslash.chevron.right"
        case .cursor: "cursorarrow"
        case .geminiCLI: "sparkle"
        case .copilot: "person.crop.circle"
        case .devin: "d.circle"
        case .cline: "c.circle"
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
        if let image = Self.appIcon(for: agent) ?? InstalledArtwork.icon(for: agent) {
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
        let (bundleID, name): (String, String)
        switch agent {
        case .claudeCode: (bundleID, name) = ("com.anthropic.claudefordesktop", "Claude.app")
        case .codex: (bundleID, name) = ("com.openai.codex", "Codex.app")
        case .openCode: (bundleID, name) = ("ai.opencode.desktop", "OpenCode.app")
        case .cursor: (bundleID, name) = ("com.todesktop.230313mzl4w4u92", "Cursor.app")
        // Windsurf became Devin Desktop and kept its bundle ID.
        case .devin: (bundleID, name) = ("com.exafunction.windsurf", "Devin.app")
        case .cline: (bundleID, name) = ("bot.cline.app", "Cline.app")
        // These live inside a terminal or VS Code, whose icon would mislead.
        case .geminiCLI, .copilot:
            cache[agent] = .some(nil)
            return nil
        }
        let dirs = ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
            ?? dirs.map { $0 + "/" + name }.first { FileManager.default.fileExists(atPath: $0) }
        let icon = path.map { NSWorkspace.shared.icon(forFile: $0) }
        cache[agent] = icon
        return icon
    }
}

/// Artwork an agent installs alongside itself, read at runtime like the app
/// icons above, so BrainFog ships no copy of it.
enum InstalledArtwork {
    @MainActor private static var cache: [AgentID: NSImage?] = [:]

    /// A one-colour glyph to draw on the agent's squircle.
    @MainActor static func glyph(for agent: AgentID) -> NSImage? {
        if let hit = cache[agent] { return hit }
        let image = find(agent)
        image?.isTemplate = true
        cache[agent] = image
        return image
    }

    /// A full-colour icon used instead of the squircle.
    @MainActor static func icon(for agent: AgentID) -> NSImage? {
        guard agent == .cline else { return nil }
        // The Cline extension's marketplace icon.
        return newest(extension: "saoudrizwan.claude-dev", files: ["assets/icons/icon.png", "assets/icon.png", "icon.png"])
            .flatMap(NSImage.init(contentsOf:))
    }

    @MainActor private static func find(_ agent: AgentID) -> NSImage? {
        switch agent {
        case .copilot:
            // The Copilot extension's own glyph, in VS Code or Cursor.
            for id in ["github.copilot", "github.copilot-chat"] {
                if let url = newest(extension: id, files: ["assets/font-icons/Github-Copilot.svg",
                                                           "assets/font-icons/GitHub-Copilot.svg"]) {
                    return NSImage(contentsOf: url)
                }
            }
            return nil
        default:
            return nil
        }
    }

    /// The first of `files` inside the newest installed version of a VS Code
    /// (or Cursor, or VS Code Insiders) extension.
    private static func newest(extension id: String, files: [String]) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [".vscode/extensions", ".vscode-insiders/extensions", ".cursor/extensions"].map { home.appendingPathComponent($0) }
        for root in roots {
            let folders = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
                .filter { $0.lowercased().hasPrefix(id + "-") }
                .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            for folder in folders {
                for file in files {
                    let url = root.appendingPathComponent(folder).appendingPathComponent(file)
                    if FileManager.default.fileExists(atPath: url.path) { return url }
                }
            }
        }
        return nil
    }
}

/// BrainFog's own stand-in mark for an agent: not the vendor's logo, just a
/// squircle in the agent's colours with a glyph for how it's used. Sized to
/// the macOS icon grid (824/1024 body) so it sits level with real app icons.
/// Where the agent installs its own glyph (Copilot), that is drawn instead;
/// where it doesn't, the mark is the agent's initials rather than a guess.
struct AgentMark: View {
    let agent: AgentID
    var size: CGFloat = 34

    private var body_: CGFloat { size * 824 / 1024 }

    var body: some View {
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
        case .openCode: [Color(red: 0.09, green: 0.08, blue: 0.08), Color(red: 0.05, green: 0.04, blue: 0.04)]
        case .cursor: [Color(white: 0.26), Color(white: 0.12)]
        case .geminiCLI: [Color(white: 1), Color(white: 0.94)]
        case .copilot: [Color(white: 0.20), Color(white: 0.08)]
        case .devin: [Color(white: 0.20), Color(white: 0.08)]
        case .cline: [Color(white: 0.20), Color(white: 0.08)]
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
            // The "O" of OpenCode's pixel wordmark: a 24×30 block with a
            // 12×18 opening whose lower two thirds are filled grey.
            let u = body_ * 0.48 / 30
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.white).frame(width: 24 * u, height: 30 * u)
                Rectangle().fill(Color(red: 0.07, green: 0.06, blue: 0.06))
                    .frame(width: 12 * u, height: 6 * u).offset(x: 6 * u, y: 6 * u)
                Rectangle().fill(Color(white: 0.42))
                    .frame(width: 12 * u, height: 12 * u).offset(x: 6 * u, y: 12 * u)
            }
            .frame(width: 24 * u, height: 30 * u)
        case .cursor:
            Image(systemName: "cursorarrow")
                .font(.system(size: body_ * 0.48, weight: .bold))
                .foregroundStyle(.white, agent.tint)
        case .geminiCLI:
            // Gemini's mark is a four-pointed star with curved sides, in a
            // blue gradient; SF Symbols' sparkle has the same outline.
            Image(systemName: "sparkle")
                .font(.system(size: body_ * 0.56, weight: .regular))
                .foregroundStyle(LinearGradient(colors: [Color(red: 0.26, green: 0.52, blue: 0.96), Color(red: 0.56, green: 0.42, blue: 0.93)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
        case .copilot:
            if let glyph = InstalledArtwork.glyph(for: .copilot) {
                Image(nsImage: glyph).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: body_ * 0.56)
                    .foregroundStyle(.white)
            } else {
                initials("Co")
            }
        case .devin: initials("D")
        case .cline: initials("Cl")
        }
    }

    private func initials(_ text: String) -> some View {
        Text(text)
            .font(.system(size: body_ * (text.count > 1 ? 0.38 : 0.46), weight: .bold, design: .rounded))
            .foregroundStyle(.white)
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
