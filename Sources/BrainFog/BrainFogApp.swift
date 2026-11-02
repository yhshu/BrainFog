import CoreImage
import AppKit
import SwiftUI
import BrainFogCore

@main
struct BrainFogApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        // A single window: a second one would share the model but keep its
        // own editor, so closing it would clear the other's unsaved state.
        Window("BrainFog", id: "main") {
            ContentView()
                .environment(model)
                .onAppear { delegate.model = model }
                .frame(minWidth: 1100, minHeight: 680)
        }
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .importExport) { PackMenuItems(model: model) }
            CommandGroup(after: .toolbar) {
                Button("Reload Files") { model.reloadProjects(); model.resolve() }
                    .keyboardShortcut("r")
                GlobalItemsToggle(model: model)
            }
        }
    }
}

// Menu items that read the model are views of their own, so a change only
// updates them. Read in `commands` itself, every change (a refresh starting
// as the app comes forward, say) rebuilds the menus, and the View menu loses
// the Enter Full Screen item AppKit adds to it.

private struct PackMenuItems: View {
    let model: AppModel

    var body: some View {
        // Not while a change is under review, which importing would
        // replace, nor while the page is still loading, so a pack
        // never mixes one page's name with another's files.
        Button("Import Agent Pack…") { model.importPack() }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(model.pendingChange != nil)
        Button("Export Agent Pack…") { model.exportPack() }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(model.isResolving || model.pendingChange != nil)
    }
}

private struct GlobalItemsToggle: View {
    @Bindable var model: AppModel

    var body: some View {
        Toggle("Show Global Items in Projects", isOn: $model.showGlobalInProjects)
            .keyboardShortcut("g", modifiers: [.command, .shift])
    }
}

/// A SwiftPM executable starts as a background process; make it a regular
/// foreground app with a Dock icon and focused window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    /// Quitting with the editor dirty asks first, like closing it does.
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.hasUnsavedEdits == true,
              NSApp.isHidden || NSApp.windows.contains(where: { $0.isVisible || $0.isMiniaturized }) else { return .terminateNow }
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
        // Antigravity, Google's agentic IDE; the CLIs share its ~/.gemini.
        case .geminiCLI: (bundleID, name) = ("com.google.antigravity", "Antigravity.app")
        // Lives inside a terminal or VS Code, whose icon would mislead.
        case .copilot:
            cache[agent] = .some(nil)
            return nil
        }
        let dirs = ["/Applications", ResolverEnvironment.defaultHome.appendingPathComponent("Applications").path]
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
        if let hit = iconCache[agent] { return hit }
        // The Cline extension's marketplace icon.
        let image = newest(extension: "saoudrizwan.claude-dev", files: ["assets/icons/icon.png", "assets/icon.png", "icon.png"])
            .flatMap(NSImage.init(contentsOf:))
        iconCache[agent] = image
        return image
    }
    @MainActor private static var iconCache: [AgentID: NSImage?] = [:]

    @MainActor private static func find(_ agent: AgentID) -> NSImage? {
        switch agent {
        case .copilot:
            // VS Code now ships Copilot built in, with its current mark; older
            // installs have it in a Copilot extension instead.
            let builtIn = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"].lazy
                .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                .map { $0.appendingPathComponent("Contents/Resources/app/extensions/copilot/assets/copilot.png") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
            let url = builtIn
                ?? newest(extension: "github.copilot-chat", files: ["assets/copilot.png"])
                ?? newest(extension: "github.copilot", files: ["assets/copilot.png"])
            // Dark strokes on an opaque white face: keep only the strokes.
            return url.flatMap(darkStrokes)
        default:
            return nil
        }
    }

    /// The dark parts of an image as an opaque mask, so a dark-on-white
    /// icon can be drawn as a one-colour template.
    private static func darkStrokes(_ url: URL) -> NSImage? {
        guard let input = CIImage(contentsOf: url) else { return nil }
        let white = CIImage(color: .white).cropped(to: input.extent)
        let mask = input.composited(over: white)
            .applyingFilter("CIColorInvert")
            .applyingFilter("CIMaskToAlpha")
        guard let cg = CIContext().createCGImage(mask, from: input.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: input.extent.width, height: input.extent.height))
    }

    /// The first of `files` inside the newest installed version of a VS Code
    /// (or Cursor, or VS Code Insiders) extension. Versions the editor has
    /// uninstalled but not yet deleted are listed in `.obsolete` and skipped.
    private static func newest(extension id: String, files: [String]) -> URL? {
        let home = ResolverEnvironment.defaultHome
        let roots = [".vscode/extensions", ".vscode-insiders/extensions", ".cursor/extensions"].map { home.appendingPathComponent($0) }
        for root in roots {
            let obsolete = (try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(".obsolete"))))
                as? [String: Any] ?? [:]
            let folders = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
                .filter { $0.lowercased().hasPrefix(id + "-") && obsolete[$0] == nil }
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
/// The glyph is a simple drawing in the spirit of the agent's mark, so every
/// agent is recognisable even when it isn't installed; Copilot uses the
/// glyph VS Code ships when VS Code is there.
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
        case .devin: [Color(red: 0.09, green: 0.10, blue: 0.12), Color(red: 0.04, green: 0.05, blue: 0.07)]
        case .cline: [Color(red: 0.27, green: 0.30, blue: 0.34), Color(red: 0.19, green: 0.21, blue: 0.25)]
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
                // The artwork leaves about 15% empty on each side.
                Image(nsImage: glyph).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: body_ * 0.8)
                    .foregroundStyle(.white)
            } else {
                copilotMark
            }
        case .devin: devinMark
        case .cline: clineMark
        }
    }

    /// Devin's mark: three hexagons, two stacked on the left and one between
    /// them on the right, in white.
    private var devinMark: some View {
        Canvas { ctx, size in
            let r = size.width * 0.5 / 4.2
            let w = r * 3.squareRoot() / 2
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            var path = Path()
            for c in [CGPoint(x: mid.x - w * 1.05, y: mid.y - r * 1.15), CGPoint(x: mid.x - w * 1.05, y: mid.y + r * 1.15),
                      CGPoint(x: mid.x + w * 0.95, y: mid.y)] {
                let corners = (0..<6).map { i -> CGPoint in
                    let a = Double(i) * .pi / 3 - .pi / 2
                    return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                }
                path.addLines(corners)
                path.closeSubpath()
            }
            ctx.fill(path, with: .color(.white))
            ctx.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: r * 0.18, lineJoin: .round))
        }
        .frame(width: body_, height: body_)
    }

    /// Cline's robot in white line art: a rounded head with an antenna,
    /// angle-bracket ears and two upright eyes. Drawn on a 128-point grid.
    private var clineMark: some View {
        Canvas { ctx, size in
            let u = size.width / 128
            func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * u, y: y * u) }
            let line = StrokeStyle(lineWidth: 7 * u, lineCap: .round, lineJoin: .round)
            ctx.stroke(Path(roundedRect: CGRect(x: 36 * u, y: 41 * u, width: 56 * u, height: 48 * u),
                            cornerRadius: 13 * u, style: .continuous), with: .color(.white), style: line)
            ctx.fill(Path(roundedRect: CGRect(x: 56 * u, y: 25 * u, width: 16 * u, height: 13 * u), cornerRadius: 4 * u),
                     with: .color(.white))
            var ears = Path()
            ears.addLines([pt(32, 56), pt(25, 65), pt(32, 74)])
            ears.move(to: pt(96, 56))
            ears.addLines([pt(96, 56), pt(103, 65), pt(96, 74)])
            ctx.stroke(ears, with: .color(.white), style: line)
            for x in [55.0, 73.0] {
                ctx.fill(Path(roundedRect: CGRect(x: (x - 3.5) * u, y: 56 * u, width: 7 * u, height: 18 * u), cornerRadius: 3.5 * u),
                         with: .color(.white))
            }
        }
        .frame(width: body_, height: body_)
    }

    /// Copilot's pilot in white line art, for Macs without VS Code: two
    /// goggles over a rounded face with two eyes. Drawn on a 128-point grid.
    private var copilotMark: some View {
        Canvas { ctx, size in
            let u = size.width / 128
            let line = StrokeStyle(lineWidth: 7 * u, lineCap: .round, lineJoin: .round)
            for x in [33.0, 65.0] {
                ctx.stroke(Path(roundedRect: CGRect(x: x * u, y: 34 * u, width: 30 * u, height: 24 * u),
                                cornerRadius: 11 * u, style: .continuous), with: .color(.white), style: line)
            }
            var face = Path()
            face.move(to: CGPoint(x: 30 * u, y: 62 * u))
            face.addLine(to: CGPoint(x: 30 * u, y: 80 * u))
            face.addQuadCurve(to: CGPoint(x: 98 * u, y: 80 * u), control: CGPoint(x: 64 * u, y: 104 * u))
            face.addLine(to: CGPoint(x: 98 * u, y: 62 * u))
            face.move(to: CGPoint(x: 30 * u, y: 66 * u))
            face.addQuadCurve(to: CGPoint(x: 22 * u, y: 76 * u), control: CGPoint(x: 22 * u, y: 66 * u))
            face.move(to: CGPoint(x: 98 * u, y: 66 * u))
            face.addQuadCurve(to: CGPoint(x: 106 * u, y: 76 * u), control: CGPoint(x: 106 * u, y: 66 * u))
            ctx.stroke(face, with: .color(.white), style: line)
            for x in [55.0, 73.0] {
                ctx.fill(Path(roundedRect: CGRect(x: (x - 3.5) * u, y: 68 * u, width: 7 * u, height: 14 * u), cornerRadius: 3.5 * u),
                         with: .color(.white))
            }
        }
        .frame(width: body_, height: body_)
    }
}

extension Scope {
    var symbol: String {
        switch self {
        case .managed: "building.columns"
        case .user: "globe"
        case .project: "folder"
        case .local: "person.crop.circle"
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
