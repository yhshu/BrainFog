import AppKit
import SwiftUI
import BrainFogCore

enum LensMode: String, CaseIterable {
    case context, skills
    var title: String { self == .context ? "Instructions & Memory" : "Skills" }
    var symbol: String { self == .context ? "text.book.closed" : "puzzlepiece.extension" }
}

/// What each agent loads for the selected place, one section per agent.
struct ContextLensView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("lensMode") private var mode = LensMode.context

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                // One full-width section per agent, stacked top to bottom.
                GlassEffectContainer(spacing: 16) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(model.contexts, id: \.agent) { ctx in
                            AgentSection(context: ctx, mode: mode)
                        }
                    }
                }
            }
            .padding(24)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(backdrop)
        .navigationTitle(model.selection?.title ?? "BrainFog")
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $mode) {
                    ForEach(LensMode.allCases, id: \.self) {
                        Label($0.title, systemImage: $0.symbol).help($0.title).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .fixedSize()
            }
        }
    }

    private var description: String {
        switch (mode, model.selection == .global) {
        case (.context, true): "Instructions and memory every agent reads in every project."
        case (.context, false): "What each agent reads when started in this folder, in the order it enters the context."
        case (.skills, true): "Skills available to each agent in every project."
        case (.skills, false): "Skills each agent can use when started in this folder, including global ones."
        }
    }

    private var subtitle: String {
        if case .project(let url) = model.selection { return url.path }
        return "Your home folder settings for Claude Code, Codex, OpenCode, and Cursor"
    }

    @ViewBuilder private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(model.selection?.title ?? "BrainFog")
                .font(.largeTitle.weight(.semibold))
            if model.isResolving { ProgressView().controlSize(.small) }
            Spacer()
        }
        VStack(alignment: .leading, spacing: 4) {
            Text(description)
                .foregroundStyle(.secondary)
            Text(subtitle).font(.caption).foregroundStyle(.tertiary)
                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
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
                    .offset(x: (CGFloat(i) - CGFloat(AgentID.allCases.count - 1) / 2) * 380, y: -160)
            }
        }
        .ignoresSafeArea()
    }
}

struct AgentSection: View {
    @Environment(AppModel.self) private var model
    @State private var showUnused = false
    @State private var showGlobalSkills = false
    @State private var isDropTarget = false
    @State private var pendingCopy: PendingCopy?
    @State private var copyError: String?
    @State private var namePrompt: NamePrompt?
    @State private var newName = ""
    let context: ResolvedContext
    let mode: LensMode

    /// Asks for a name before creating a rule file or a skill.
    struct NamePrompt {
        var title: String
        var create: (String) throws -> URL
    }

    struct PendingCopy {
        var source: URL
        var plan: CopyPlan
    }

    private var launched: [ContextEntry] { context.entries.filter { $0.timing.isLoadedAtLaunch } }
    private var onDemand: [ContextEntry] {
        context.entries.filter { if case .onDemand = $0.timing { true } else { false } }
    }
    private var unused: [ContextEntry] {
        context.entries.filter { if case .skipped = $0.timing { true } else { false } }
    }
    private func notes(_ topic: Diagnostic.Topic) -> [Diagnostic] {
        context.diagnostics.filter { $0.severity == .info && $0.topic == topic }
    }

    private var project: URL? {
        if case .project(let url) = model.selection { return url }
        return nil
    }

    /// Agents whose sections are folded, kept across launches as
    /// comma-separated raw values.
    @AppStorage("collapsedAgents") private var collapsedAgents = ""

    private var hasItems: Bool { mode == .context ? !context.entries.isEmpty : !context.skills.isEmpty }
    private var isCollapsed: Bool { hasItems && collapsedAgents.split(separator: ",").contains(Substring(context.agent.rawValue)) }

    private func toggleCollapsed() {
        var set = Set(collapsedAgents.split(separator: ",").map(String.init))
        if set.remove(context.agent.rawValue) == nil { set.insert(context.agent.rawValue) }
        withAnimation { collapsedAgents = set.sorted().joined(separator: ",") }
    }

    /// What a folded section still says about itself.
    private var summary: String {
        if mode == .skills {
            let n = context.skills.count
            return "\(n) \(n == 1 ? "skill" : "skills")"
        }
        let n = context.entries.count
        return "\(n) \(n == 1 ? "file" : "files") · about \(context.launchTokens.tokenLabel) tokens at launch"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button(action: toggleCollapsed) {
                    HStack(spacing: 10) {
                        AgentIcon(agent: context.agent)
                        Text(context.agent.displayName).font(.title3.weight(.semibold))
                        if hasItems {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        }
                        if isCollapsed {
                            Text(summary).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .allowsHitTesting(hasItems)
                .help(isCollapsed ? "Show \(context.agent.displayName)’s files" : "Fold \(context.agent.displayName)’s section")
                if mode == .skills || !newFileOptions.isEmpty || !globalFileOptions.isEmpty { addMenu }
            }
            if !isCollapsed {
                if mode == .context { contextGroups } else { skillGroups }
            }
            ForEach(context.diagnostics.filter { $0.severity != .info }) { DiagnosticRow(diagnostic: $0) }
        }
        .modifier(SectionChrome(agent: context.agent, isDropTarget: isDropTarget))
        .dropDestination(for: URL.self) { urls, _ in
            mode == .context && prepareCopy(urls)
        } isTargeted: { isDropTarget = $0 && mode == .context }
        .confirmationDialog(copyTitle, isPresented: Binding(
            get: { pendingCopy != nil }, set: { if !$0 { pendingCopy = nil } }
        ), titleVisibility: .visible) {
            Button("Copy") { performCopy() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(copyMessage)
        }
        .alert(namePrompt?.title ?? "", isPresented: Binding(
            get: { namePrompt != nil }, set: { if !$0 { namePrompt = nil } }
        )) {
            TextField("Name", text: $newName)
            Button("Create") { if let prompt = namePrompt { create { try prompt.create(newName) } } }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn’t do that", isPresented: Binding(
            get: { copyError != nil }, set: { if !$0 { copyError = nil } }
        )) {} message: {
            Text(copyError ?? "")
        }
    }

    // MARK: Creating files

    /// Nothing to offer for a layer the agent keeps outside files (Cursor's
    /// global rules), so the menu is hidden then.
    private var newFileOptions: [NewFileOption] {
        NewFileOption.options(for: context.agent, project: project)
    }

    /// On a project page, the global files too, so either layer can be
    /// started from here.
    private var globalFileOptions: [NewFileOption] {
        project == nil ? [] : NewFileOption.options(for: context.agent, project: nil)
    }

    /// "+" menu: new instruction files where this agent reads them, or a new skill.
    private var addMenu: some View {
        Menu {
            if mode == .context {
                if globalFileOptions.isEmpty {
                    fileButtons(newFileOptions)
                } else {
                    Section("This Project") { fileButtons(newFileOptions) }
                    Section("Global (Every Project)") { fileButtons(globalFileOptions) }
                }
            } else {
                if let project {
                    // A project page offers both layers, saying where each goes.
                    skillButton("Project Skill…", detail: "Only in this project, in \(skillDir(project))", project: project)
                    skillButton("Global Skill…", detail: "In every project, in \(skillDir(nil))", project: nil)
                } else {
                    skillButton("New Skill…", detail: "In every project, in \(skillDir(nil))", project: nil)
                }
            }
        } label: {
            Label("New", systemImage: "plus")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(mode == .context ? "Create an instruction file \(context.agent.displayName) reads"
                               : "Create a skill for \(context.agent.displayName)")
    }

    @ViewBuilder private func fileButtons(_ options: [NewFileOption]) -> some View {
        ForEach(options) { option in
            Button {
                if option.needsName {
                    let title = project != nil && !isInProject(option.url) ? "New Global Rule File" : "New Rule File"
                    model.whenEditsAreSafe { ask(title) { try option.create(name: $0) } }
                } else {
                    model.whenEditsAreSafe { create { try option.create() } }
                }
            } label: {
                Text(option.title + (option.exists ? " (already exists)" : ""))
                Text(option.detail)
            }
            .disabled(option.exists)
        }
    }

    /// Where a new skill for this agent goes, shown relative to the project or home.
    private func skillDir(_ project: URL?) -> String {
        let folder = SkillResolver.newSkillFolder(named: "", agent: context.agent, project: project)
        guard let project else { return displayPath(folder) }
        return String(folder.path.dropFirst(project.path.count + 1))
    }

    private func skillButton(_ title: String, detail: String, project: URL?) -> some View {
        Button {
            model.whenEditsAreSafe { ask(project == nil ? "New Global Skill" : "New Project Skill") { name in
                // The name becomes a folder, so it must be a single path component.
                let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.contains("/"), !name.hasPrefix(".") else {
                    throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: name])
                }
                let folder = SkillResolver.newSkillFolder(named: name, agent: context.agent, project: project)
                let file = folder.appendingPathComponent("SKILL.md")
                if FileManager.default.fileExists(atPath: file.path) {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: file.path])
                }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try SkillResolver.template(name: name).write(to: file, atomically: true, encoding: .utf8)
                return file
            } }
        } label: {
            Text(title)
            Text(detail)
        }
    }

    private func ask(_ title: String, _ create: @escaping (String) throws -> URL) {
        newName = ""
        namePrompt = NamePrompt(title: title, create: create)
    }

    /// Creates the file, then opens it in the editor.
    private func create(_ make: () throws -> URL) {
        do {
            let url = try make()
            model.selectedEntry = ContextEntry(agent: context.agent, url: url.standardizedFileURL,
                                               scope: isInProject(url) ? .project : .user, timing: .launch)
            model.resolve()
        } catch {
            copyError = error.localizedDescription
        }
    }

    private func isInProject(_ url: URL) -> Bool {
        guard let project else { return false }
        return url.standardizedFileURL.path.hasPrefix(project.standardizedFileURL.path + "/")
    }

    // MARK: Instructions & memory

    /// Three groups, each answering one question: what is read at the start
    /// of every session, what is read only when relevant, and what is ignored.
    @ViewBuilder private var contextGroups: some View {
        GroupHeader(title: "Every session",
                    detail: launched.isEmpty ? "no files"
                        : "\(launched.count) \(launched.count == 1 ? "file" : "files") · about \(context.launchTokens.tokenLabel) tokens")
            .help("Read in full at the start of every session. \(tokenHelp)")
        TokenBar(entries: launched, tint: context.agent.tint)
        ForEach(launched) { EntryCard(entry: $0) }
        ForEach(notes(.launch)) { NoteText(text: $0.message) }

        if !onDemand.isEmpty || !notes(.onDemand).isEmpty {
            GroupHeader(title: "When relevant",
                        detail: onDemand.isEmpty ? nil : "\(onDemand.count) \(onDemand.count == 1 ? "file" : "files")")
                .help("Read only when the agent works on matching files or needs it")
                .padding(.top, 6)
            ForEach(onDemand) { EntryCard(entry: $0) }
            ForEach(notes(.onDemand)) { NoteText(text: $0.message) }
        }

        if !unused.isEmpty {
            Button {
                withAnimation { showUnused.toggle() }
            } label: {
                HStack(spacing: 6) {
                    GroupHeader(title: "Not used", detail: "\(unused.count) \(unused.count == 1 ? "file" : "files")")
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showUnused ? 90 : 0))
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Files on disk that this agent ignores, and why")
            .padding(.top, 6)
            if showUnused { ForEach(unused) { EntryCard(entry: $0) } }
        }
    }

    // MARK: Skills

    /// On a project page, the project's own skills come first and the global
    /// ones (which the agent also lists there) fold away below them.
    @ViewBuilder private var skillGroups: some View {
        let listed = context.skills.filter { $0.timing.isLoadedAtLaunch }
        let tokens = listed.reduce(0) { $0 + $1.tokens }
        GroupHeader(title: "Listed every session",
                    detail: listed.isEmpty ? "no skills"
                        : "\(listed.count) \(listed.count == 1 ? "skill" : "skills") · about \(tokens.tokenLabel) tokens")
            .help("Each skill’s name and description are listed at the start of every session; the rest of SKILL.md is read only when the skill is used. Skills a higher-priority one replaces are dimmed. \(tokenHelp)")
        if let project {
            let own = context.skills.filter { $0.scope == .project }
            let shared = context.skills.filter { $0.scope != .project }
            GroupHeader(title: "This project", detail: "\(own.count) \(own.count == 1 ? "skill" : "skills")")
                .padding(.top, 6)
            if own.isEmpty {
                NoteText(text: "None yet. New → Project Skill adds one in \(skillDir(project)), only for this project.")
            }
            ForEach(own) { SkillRow(skill: $0) }
            if !shared.isEmpty {
                Button {
                    withAnimation { showGlobalSkills.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        GroupHeader(title: "Global", detail: "\(shared.count) \(shared.count == 1 ? "skill" : "skills") · shared by every project")
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showGlobalSkills ? 90 : 0))
                        Spacer()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Skills from your home folder and the agent itself, also listed in this project")
                .padding(.top, 6)
                if showGlobalSkills { ForEach(shared) { SkillRow(skill: $0) } }
            }
        } else {
            ForEach(listed) { SkillRow(skill: $0) }
            ForEach(context.skills.filter { !$0.timing.isLoadedAtLaunch }) { SkillRow(skill: $0) }
        }
    }

    // MARK: Copying a dropped file to this agent

    /// Accepts one local file that this agent doesn't already read.
    private func prepareCopy(_ urls: [URL]) -> Bool {
        guard let source = urls.first, urls.count == 1, source.isFileURL,
              !context.entries.contains(where: { $0.url.standardizedFileURL == source.standardizedFileURL })
        else { return false }
        var project: URL?
        if case .project(let url) = model.selection { project = url }
        let from = model.contexts.first { ctx in
            ctx.entries.contains { $0.url.standardizedFileURL == source.standardizedFileURL }
        }?.agent
        guard let plan = CopyPlan(source: source, to: context.agent, project: project, from: from) else { return false }
        pendingCopy = PendingCopy(source: source, plan: plan)
        return true
    }

    private var copyTitle: String {
        guard let pendingCopy else { return "" }
        return "Copy \(pendingCopy.source.lastPathComponent) to \(context.agent.displayName)?"
    }

    private var copyMessage: String {
        guard let plan = pendingCopy?.plan else { return "" }
        let path = plan.destination.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        var text = plan.mode == .newFile
            ? "It will be saved as a new file, \(path), which \(context.agent.displayName) reads at the start of every session."
            : "Its text will be added to the end of \(path), which \(context.agent.displayName) reads at the start of every session."
        if !plan.sharedWith.isEmpty {
            let names = plan.sharedWith.map(\.displayName)
            let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names.last! : names[0]
            text += " \(list) \(names.count > 1 ? "read" : "reads") this file too."
        }
        if !plan.lostScope.isEmpty {
            text += " The original applies only to \(plan.lostScope.joined(separator: ", ")); \(context.agent.displayName) can’t limit it that way, so the copy applies to every file."
        }
        return text + " The original file is not changed."
    }

    private func performCopy() {
        guard let pending = pendingCopy else { return }
        pendingCopy = nil
        do {
            let text = try String(contentsOf: pending.source, encoding: .utf8)
            try pending.plan.apply(text: text, source: pending.source)
            model.resolve()
        } catch {
            copyError = error.localizedDescription
        }
    }
}

/// The glass card behind each agent section, lit up while a file is dragged over it.
struct SectionChrome: ViewModifier {
    let agent: AgentID
    let isDropTarget: Bool

    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .glassEffect(isDropTarget ? .regular.tint(agent.tint.opacity(0.3)) : .regular,
                         in: .rect(cornerRadius: 24))
            .overlay {
                if isDropTarget {
                    RoundedRectangle(cornerRadius: 24).strokeBorder(agent.tint, lineWidth: 2)
                }
            }
    }
}

struct SkillRow: View {
    @Environment(AppModel.self) private var model
    @State private var confirmTrash = false
    let skill: Skill

    private var isSelected: Bool { model.selectedEntry?.url == skill.url && model.selectedEntry?.agent == skill.agent }

    var body: some View {
        Button {
            let next = isSelected ? nil : skill.entry
            model.whenEditsAreSafe { model.selectedEntry = next }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(skill.name).font(.body.weight(.medium))
                    ScopeChip(scope: skill.scope)
                    Spacer(minLength: 0)
                    Text("\(skill.tokens.tokenLabel) tokens").font(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help(tokenHelp)
                }
                if !skill.description.isEmpty {
                    Text(skill.description).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(displayPath(skill.folder)).font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                if let why = reason {
                    Text(why).font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .glassEffect(isSelected ? .regular.tint(skill.agent.tint.opacity(0.35)).interactive()
                                : .regular.interactive(),
                     in: .rect(cornerRadius: 14))
        .opacity(skill.timing.isLoadedAtLaunch ? 1 : 0.55)
        .help("Click to edit SKILL.md")
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([skill.folder]) }
            Divider()
            Button("Move to Trash…") { confirmTrash = true }
        }
        .confirmationDialog("Move the skill “\(skill.name)” to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { moveToTrash(skill.folder, model: model) }
        } message: {
            Text("The whole folder \(displayPath(skill.folder)) goes to the Trash. You can put it back from there.")
        }
    }

    private var reason: String? {
        var parts: [String] = []
        if case .skipped(let why) = skill.timing { parts.append(why.prefix(1).capitalized + why.dropFirst()) }
        if let note = skill.note { parts.append(note.prefix(1).capitalized + note.dropFirst()) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

func displayPath(_ url: URL) -> String {
    guard url.isFileURL else { return url.absoluteString }
    return url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
}

/// Moves a file or folder to the Trash, closing it in the editor first.
@MainActor func moveToTrash(_ url: URL, model: AppModel) {
    if let open = model.selectedEntry?.url.standardizedFileURL.path,
       open == url.standardizedFileURL.path || open.hasPrefix(url.standardizedFileURL.path + "/") {
        model.selectedEntry = nil
    }
    NSWorkspace.shared.recycle([url]) { _, _ in
        Task { @MainActor in model.resolve() }
    }
}

struct GroupHeader: View {
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

struct NoteText: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
                        .help("\(e.url.lastPathComponent) · about \(e.tokens.tokenLabel) tokens")
                }
            }
        }
        .frame(height: 6)
        .opacity(entries.isEmpty ? 0 : 1)
    }
}

struct EntryCard: View {
    @Environment(AppModel.self) private var model
    @State private var confirmTrash = false
    let entry: ContextEntry

    private var isSelected: Bool { model.selectedEntry?.id == entry.id && model.selectedEntry?.agent == entry.agent }

    var body: some View {
        Button {
            let next = isSelected ? nil : entry
            model.whenEditsAreSafe { model.selectedEntry = next }
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
                            Text("\(entry.tokens.tokenLabel) tokens").font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary)
                                .help(tokenHelp)
                        }
                    }
                    Text(displayPath(entry.url)).font(.caption).foregroundStyle(.secondary)
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
        .draggable(entry.url)
        .help("Click to edit. Drag onto another agent to copy it there.")
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.url.path, forType: .string)
            }
            if entry.url.isFileURL {
                Divider()
                Button("Move to Trash…") { confirmTrash = true }
            }
        }
        .confirmationDialog("Move \(entry.url.lastPathComponent) to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { moveToTrash(entry.url, model: model) }
        } message: {
            Text("\(displayPath(entry.url)) goes to the Trash. You can put it back from there.")
        }
    }

    private var isSkipped: Bool {
        if case .skipped = entry.timing { return true }
        return false
    }

    private var detail: String? {
        var parts: [String] = []
        switch entry.timing {
        case .launch: break
        case .onDemand(let why): parts.append(why.prefix(1).capitalized + why.dropFirst())
        case .skipped(let why): parts.append(why.prefix(1).capitalized + why.dropFirst())
        }
        if let by = entry.importedBy { parts.append("imported by \(by.lastPathComponent)") }
        if let note = entry.note { parts.append(note) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Tokens are the units a model reads text in; the counts are estimates.
let tokenHelp = "Estimated share of the agent’s context window. A token is about 4 English characters or 1 CJK character."

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
