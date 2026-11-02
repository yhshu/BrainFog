import AppKit
import SwiftUI
import BrainFogCore

enum LensMode: String, CaseIterable {
    case context, skills, mcp, timeline
    var title: String {
        switch self {
        case .context: "Instructions & Memory"
        case .skills: "Skills"
        case .mcp: "MCP Servers"
        case .timeline: "Timeline"
        }
    }
    var symbol: String {
        switch self {
        case .context: "text.book.closed"
        case .skills: "puzzlepiece.extension"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .timeline: "clock.arrow.circlepath"
        }
    }
}

/// Centers an empty state in the room left under the page header, since a
/// scroll view would otherwise shrink it to its content.
struct EmptyStateFrame: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity, minHeight: 360)
    }
}

/// Reads the sidebar's visibility in a view of its own, so toggling it
/// doesn't re-evaluate the whole lens in the first frame of the slide.
private struct SidebarToggle: View {
    @Binding var columns: NavigationSplitViewVisibility

    var body: some View {
        let hidden = columns == .detailOnly
        Button(hidden ? "Show Sidebar" : "Hide Sidebar", systemImage: "sidebar.left") {
            withAnimation { columns = hidden ? .all : .detailOnly }
        }
        .help(hidden ? "Show Sidebar" : "Hide Sidebar")
    }
}

/// What each agent loads for the selected place, one section per agent.
struct ContextLensView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("lensMode") private var mode = LensMode.context
    /// The agent whose section fills the top of the view with its own
    /// header scrolled away, so a pinned copy of the header says whose it is.
    @State private var pinned: AgentID?
    /// Window y of the bottom of the pinned-header bar, where content stops
    /// being covered.
    @State private var visibleTop: CGFloat = 0
    @State private var scroll = ScrollPosition()
    @State private var query = ""
    @Binding var columns: NavigationSplitViewVisibility

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if mode == .context {
                        if let sharing = model.sharing { SharingCard(report: sharing) }
                        if let sync = model.globalSync { GlobalSyncCard(report: sync) }
                        if !model.health.isEmpty { HealthCard(issues: model.health) }
                    }
                    if mode == .timeline {
                        TimelineList(query: query)
                    } else {
                        // One full-width section per agent, stacked top to bottom.
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(model.contexts.filter { shows($0) }, id: \.agent) { ctx in
                                AgentSection(context: ctx, mode: mode, query: query)
                                    .id(ctx.agent)
                                    .onGeometryChange(for: Bool.self) { geo in
                                        // Its title row is out of sight but the rest isn't.
                                        let f = geo.frame(in: .global)
                                        return f.minY < visibleTop - 40 && f.maxY > visibleTop + 60
                                    } action: { covers in
                                        if covers { pinned = ctx.agent } else if pinned == ctx.agent { pinned = nil }
                                    }
                            }
                            if !query.isEmpty, !model.contexts.contains(where: shows) {
                                ContentUnavailableView.search(text: query)
                                    .modifier(EmptyStateFrame())
                            }
                        }
                    }
                }
                .padding([.horizontal, .bottom], 24)
            }
            .scrollPosition($scroll)
            .onAppear {
                // Development aid for BRAINFOG_SNAPSHOT: start scrolled down.
                if let y = ProcessInfo.processInfo.environment["BRAINFOG_SNAPSHOT_Y"].flatMap(Double.init) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { scroll.scrollTo(y: y) }
                }
            }
            // A bar of fixed height under the toolbar, so the content's
            // insets never change as a header comes and goes. Content scrolls
            // under it and the toolbar's soft edge blurs both, the way a
            // list's sticky section header sits, rather than a second layer
            // of glass floating over the cards.
            .safeAreaBar(edge: .top) {
                ZStack(alignment: .leading) {
                    if let agent = pinned, let ctx = model.contexts.first(where: { $0.agent == agent }) {
                        PinnedAgentHeader(context: ctx, summary: pinnedSummary(ctx)) {
                            withAnimation { proxy.scrollTo(agent, anchor: .top) }
                        }
                        .transition(.opacity)
                    }
                }
                // Lined up with the section headers inside the cards.
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { visibleTop = $0 }
                .animation(.easeOut(duration: 0.15), value: pinned)
            }
            .searchable(text: $query, placement: .toolbar, prompt: Text(searchPrompt))
            .onChange(of: query) { pinned = nil }
            .onChange(of: mode) { pinned = nil }
            .onChange(of: model.selection) { pinned = nil }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(model.selection?.title ?? "BrainFog")
        .toolbar(removing: .title)
        .toolbar {
            // The sidebar's own toggle lives in the sidebar column, which
            // starts too narrow to hold it as the sidebar opens; for that
            // frame the toolbar overflows (a ">>" and a collapsed search
            // field). Here it always has room. Out of the switcher's shared
            // capsule, which a spacer alone doesn't split.
            ToolbarItem(placement: .navigation) { SidebarToggle(columns: $columns) }
                .sharedBackgroundVisibility(.hidden)
            // Toolbar toggles, so they take the toolbar's own size and capsule.
            ToolbarItemGroup(placement: .navigation) {
                ForEach(LensMode.allCases, id: \.self) { m in
                    Toggle(isOn: Binding(get: { mode == m }, set: { if $0 { mode = m } })) {
                        Label(m.title, systemImage: m.symbol)
                    }
                    .help(m.title)
                }
            }
            // Right after the switcher, so it stays put when the editor
            // opens and widens the window.
            ToolbarSpacer(.fixed, placement: .navigation)
            DefaultToolbarItem(kind: .search, placement: .navigation)
        }
    }

    private var searchPrompt: String {
        switch mode {
        case .context, .timeline: "Search files"
        case .skills: "Search skills"
        case .mcp: "Search servers"
        }
    }

    /// While filtering, an agent is shown if its name matches or anything in
    /// the current view does.
    private func shows(_ ctx: ResolvedContext) -> Bool {
        guard !query.isEmpty else { return true }
        if Search.matches(query, ctx.agent.displayName) { return true }
        return switch mode {
        case .context: model.shownEntries(ctx).contains { Search.matches(query, $0) }
        case .skills: model.shownSkills(ctx).contains { Search.matches(query, $0) }
        case .mcp: model.shownServers(ctx.agent).contains { Search.matches(query, $0) }
        case .timeline: true
        }
    }

    private func pinnedSummary(_ ctx: ResolvedContext) -> String {
        switch mode {
        case .context:
            "\(model.shownEntries(ctx).count) \(model.shownEntries(ctx).count == 1 ? "file" : "files") · about \(ctx.launchTokens.tokenLabel) tokens at launch"
        case .skills:
            "\(model.shownSkills(ctx).count) \(model.shownSkills(ctx).count == 1 ? "skill" : "skills")"
        case .mcp:
            "\(model.shownServers(ctx.agent).count) MCP \(model.shownServers(ctx.agent).count == 1 ? "server" : "servers")"
        case .timeline: ""
        }
    }

    private var description: String {
        switch (mode, model.selection == .global) {
        case (.context, true): "Instructions and memory every agent reads in every project."
        case (.context, false): model.showGlobalInProjects
            ? "What each agent reads when started in this folder, in the order it enters the context."
            : "What each agent reads from this folder, in the order it enters the context. Global files are on the Global page."
        case (.skills, true): "Skills available to each agent in every project."
        case (.skills, false): model.showGlobalInProjects
            ? "Skills each agent can use when started in this folder, including global ones."
            : "Skills this folder adds for each agent. Global ones are on the Global page."
        case (.mcp, true): "MCP servers each agent can use in every project."
        case (.mcp, false): model.showGlobalInProjects
            ? "MCP servers each agent can use in this folder. Right-click one to copy it to another agent."
            : "MCP servers this folder adds for each agent; global ones are on the Global page. Right-click one to copy it to another agent."
        case (.timeline, true): "Every change to the global files the agents read, newest first, including what agents write to their own memory while BrainFog is open."
        case (.timeline, false): "Every change to the files the agents read in this folder, newest first, including what agents write to their own memory while BrainFog is open."
        }
    }

    private var subtitle: String {
        if case .project(let url) = model.selection { return url.path }
        return "Your home folder settings for every agent"
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
}

struct AgentSection: View {
    @Environment(AppModel.self) private var model
    @State private var showUnused = false
    @State private var addingServer = false
    @State private var showGlobalSkills = false
    @State private var isDropTarget = false
    @State private var pendingCopy: PendingCopy?
    @State private var copyError: String?
    @State private var namePrompt: NamePrompt?
    @State private var newName = ""
    let context: ResolvedContext
    let mode: LensMode
    var query = ""

    /// Asks for a name before creating a rule file or a skill.
    struct NamePrompt {
        var title: String
        var create: (String) throws -> URL
    }

    struct PendingCopy {
        var source: URL
        var plan: CopyPlan
    }

    /// A filter that matches the agent's own name keeps everything.
    private var filtering: Bool { !query.isEmpty && !Search.matches(query, context.agent.displayName) }
    private var entries: [ContextEntry] {
        let all = model.shownEntries(context)
        return filtering ? all.filter { Search.matches(query, $0) } : all
    }
    private var skills: [Skill] {
        let all = model.shownSkills(context)
        return filtering ? all.filter { Search.matches(query, $0) } : all
    }
    /// Global files read at launch that this page leaves out.
    private var hiddenGlobal: [ContextEntry] {
        guard model.hidesGlobal, !filtering else { return [] }
        let shown = Set(model.shownEntries(context).map(\.url))
        return context.entries.filter { $0.timing.isLoadedAtLaunch && !shown.contains($0.url) }
    }
    private var launched: [ContextEntry] { entries.filter { $0.timing.isLoadedAtLaunch } }
    private var onDemand: [ContextEntry] {
        entries.filter { if case .onDemand = $0.timing { true } else { false } }
    }
    private var unused: [ContextEntry] {
        entries.filter { if case .skipped = $0.timing { true } else { false } }
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

    private var servers: [MCPServer] {
        let all = model.shownServers(context.agent)
        return filtering ? all.filter { Search.matches(query, $0) } : all
    }

    private var hasItems: Bool {
        switch mode {
        case .context: !entries.isEmpty
        case .skills: !skills.isEmpty
        case .mcp: !servers.isEmpty
        case .timeline: false
        }
    }
    /// Not installed and nothing here: just the header, saying so.
    private var isAbsent: Bool { !hasItems && !model.installed.contains(context.agent) }
    private var isCollapsed: Bool { query.isEmpty && hasItems && collapsedAgents.split(separator: ",").contains(Substring(context.agent.rawValue)) }

    private func toggleCollapsed() {
        var set = Set(collapsedAgents.split(separator: ",").map(String.init))
        if set.remove(context.agent.rawValue) == nil { set.insert(context.agent.rawValue) }
        withAnimation { collapsedAgents = set.sorted().joined(separator: ",") }
    }

    /// What a folded section still says about itself.
    private var summary: String {
        if mode == .skills {
            let n = skills.count
            return "\(n) \(n == 1 ? "skill" : "skills")"
        }
        if mode == .mcp {
            let n = servers.count
            return "\(n) \(n == 1 ? "server" : "servers")"
        }
        let n = entries.count
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
                        if isAbsent {
                            Text("not found on this Mac").font(.subheadline).foregroundStyle(.tertiary)
                        } else if isCollapsed {
                            Text(summary).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .allowsHitTesting(hasItems)
                .help(isCollapsed ? "Show \(context.agent.displayName)’s files" : "Fold \(context.agent.displayName)’s section")
                if mode == .mcp {
                    Button("New", systemImage: "plus") { addingServer = true }
                        .help("Add an MCP server to \(context.agent.displayName)")
                } else if mode == .skills || !newFileOptions.isEmpty || !globalFileOptions.isEmpty {
                    addMenu
                }
            }
            if !isCollapsed && !isAbsent {
                switch mode {
                case .context: contextGroups
                case .skills: skillGroups
                case .mcp: serverGroups
                case .timeline: EmptyView()
                }
            }
            ForEach(context.diagnostics.filter { $0.severity != .info }) { DiagnosticRow(diagnostic: $0) }
        }
        .modifier(SectionChrome(agent: context.agent, isDropTarget: isDropTarget))
        .dropDestination(for: URL.self) { urls, _ in
            mode == .context && prepareCopy(urls)
        } isTargeted: { isDropTarget = $0 && mode == .context }
        .sheet(isPresented: $addingServer) {
            ServerForm(agent: context.agent, project: project, existing: nil)
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
            let entry = ContextEntry(agent: context.agent, url: url.standardizedFileURL,
                                     scope: isInProject(url) ? .project : .user, timing: .launch)
            model.whenEditsAreSafe { model.selectedEntry = entry }
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
        let tokens = model.hidesGlobal ? launched.reduce(0) { $0 + $1.tokens } : context.launchTokens
        GroupHeader(title: "Every session",
                    detail: launched.isEmpty ? "no files"
                        : "\(launched.count) \(launched.count == 1 ? "file" : "files") · about \(tokens.tokenLabel) tokens")
            .help("Read in full at the start of every session. \(tokenHelp)")
        if launched.count > 1 { TokenBar(entries: launched, tint: context.agent.tint) }
        ForEach(launched) { EntryCard(entry: $0) }
        if !hiddenGlobal.isEmpty {
            let n = hiddenGlobal.count
            NoteText(text: "Also reads \(n) global \(n == 1 ? "file" : "files"), about \(hiddenGlobal.reduce(0) { $0 + $1.tokens }.tokenLabel) tokens, listed on the Global page. View → Show Global Items in Projects lists \(n == 1 ? "it" : "them") here too.")
        }
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
                        .rotationEffect(.degrees(showUnused || !query.isEmpty ? 90 : 0))
                    Spacer()
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Files on disk that this agent ignores, and why")
            .padding(.top, 6)
            if showUnused || !query.isEmpty { ForEach(unused) { EntryCard(entry: $0) } }
        }
    }

    // MARK: Skills

    /// On a project page, the project's own skills come first and the global
    /// ones (which the agent also lists there) fold away below them.
    @ViewBuilder private var skillGroups: some View {
        let listed = skills.filter { $0.timing.isLoadedAtLaunch }
        let tokens = listed.reduce(0) { $0 + $1.tokens }
        GroupHeader(title: "Listed every session",
                    detail: listed.isEmpty ? "no skills"
                        : "\(listed.count) \(listed.count == 1 ? "skill" : "skills") · about \(tokens.tokenLabel) tokens")
            .help("Each skill’s name and description are listed at the start of every session; the rest of SKILL.md is read only when the skill is used. Skills a higher-priority one replaces are dimmed. \(tokenHelp)")
        if let project {
            let own = skills.filter { $0.scope == .project }
            let shared = skills.filter { $0.scope != .project }
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
                            .rotationEffect(.degrees(showGlobalSkills || !query.isEmpty ? 90 : 0))
                        Spacer()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Skills from your home folder and the agent itself, also listed in this project")
                .padding(.top, 6)
                if showGlobalSkills || !query.isEmpty { ForEach(shared) { SkillRow(skill: $0) } }
            }
        } else {
            ForEach(listed) { SkillRow(skill: $0) }
            ForEach(skills.filter { !$0.timing.isLoadedAtLaunch }) { SkillRow(skill: $0) }
        }
    }

    // MARK: MCP servers

    @ViewBuilder private var serverGroups: some View {
        if servers.isEmpty {
            NoteText(text: "No MCP servers. Use New to add one, or right-click a server under another agent to copy it here.")
        }
        ForEach(servers) { ServerRow(server: $0) }
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
        guard let plan = CopyPlan(source: source, to: context.agent, project: project, from: from),
              let text = try? String(contentsOf: source, encoding: .utf8) else { return false }
        pendingCopy = PendingCopy(source: source, plan: plan)
        model.pendingChange = ChangeSet(title: copyTitle, detail: copyMessage,
                                        edits: [plan.edit(text: text, source: source)])
        pendingCopy = nil
        return true
    }

    private var copyTitle: String {
        guard let pendingCopy else { return "" }
        return "Copy \(pendingCopy.source.lastPathComponent) to \(context.agent.displayName)?"
    }

    private var copyMessage: String {
        guard let plan = pendingCopy?.plan else { return "" }
        let path = displayPath(plan.destination)
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

}

/// The card behind each agent section, lit up while a file is dragged over
/// it. Cards hold content, so they are a plain grouped fill rather than
/// Liquid Glass, which the Human Interface Guidelines keep for controls and
/// navigation.
struct SectionChrome: ViewModifier {
    let agent: AgentID
    let isDropTarget: Bool

    func body(content: Content) -> some View {
        content.modifier(CardChrome(fill: isDropTarget ? AnyShapeStyle(agent.tint.opacity(0.12)) : nil))
            .overlay {
                if isDropTarget {
                    RoundedRectangle(cornerRadius: cardRadius, style: .continuous).strokeBorder(agent.tint, lineWidth: 2)
                }
            }
    }
}

let cardRadius: CGFloat = 16

/// A grouped-content card, like a section of a grouped form in System Settings.
struct CardChrome: ViewModifier {
    var fill: AnyShapeStyle?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(fill ?? AnyShapeStyle(.background.secondary), in: shape)
            .overlay { shape.strokeBorder(.separator.opacity(0.6), lineWidth: 0.5) }
            .containerShape(shape)
    }
}

/// The background of a clickable row inside a card: nothing at rest, a
/// light fill on hover, and the agent's colour while its file is open.
struct RowChrome: ViewModifier {
    let tint: Color
    let isSelected: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(isSelected ? AnyShapeStyle(tint.opacity(0.18))
                        : isHovered ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear),
                        in: rowShape)
            .onHover { isHovered = $0 }
    }
}

/// Rows inside a section card round concentrically with the card, as the
/// Human Interface Guidelines ask of nested shapes.
let rowShape = ConcentricRectangle(corners: .concentric(minimum: 8), isUniform: true)

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
                Text(displayPath(skill.folder, in: model.project)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if let why = reason {
                    Text(why).font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(rowShape)
        }
        .buttonStyle(.plain)
        .modifier(RowChrome(tint: skill.agent.tint, isSelected: isSelected))
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
    let home = FileManager.default.homeDirectoryForCurrentUser.path + "/"
    return url.path.hasPrefix(home) ? "~/" + url.path.dropFirst(home.count) : url.path
}

/// A path as a row shows it: relative to the project when it is inside it,
/// since every such row would otherwise repeat the project's own path.
func displayPath(_ url: URL, in project: URL?) -> String {
    guard url.isFileURL, let project else { return displayPath(url) }
    // Resolve links on both sides, so /tmp and /private/tmp compare equal.
    let root = project.resolvingSymlinksInPath().path + "/"
    let path = url.resolvingSymlinksInPath().path
    return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : displayPath(url)
}

extension AppModel {
    /// The folder of the project page, or nil on the global page.
    var project: URL? {
        if case .project(let url) = selection { return url }
        return nil
    }
}

/// Moves a file or folder to the Trash, then closes it in the editor.
/// Unsaved edits to it are asked about first.
@MainActor func moveToTrash(_ url: URL, model: AppModel) {
    let path = url.standardizedFileURL.path
    let isOpen = model.selectedEntry.map {
        let open = $0.url.standardizedFileURL.path
        return open == path || open.hasPrefix(path + "/")
    } ?? false
    let trash = {
        NSWorkspace.shared.recycle([url]) { _, error in
            Task { @MainActor in
                if error == nil, isOpen { model.selectedEntry = nil }
                model.resolve()
            }
        }
    }
    if isOpen { model.whenEditsAreSafe(trash) } else { trash() }
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
                    Text(displayPath(entry.url, in: model.project)).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(rowShape)
        }
        .buttonStyle(.plain)
        .modifier(RowChrome(tint: entry.agent.tint, isSelected: isSelected))
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

struct ServerRow: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?
    @State private var editing = false
    let server: MCPServer

    var body: some View {
        Button {
            model.whenEditsAreSafe {
                model.selectedEntry = ContextEntry(agent: server.agent, url: server.file, scope: server.scope, timing: .launch)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: server.isRemote ? "network" : "terminal")
                        .foregroundStyle(server.agent.tint).frame(width: 18)
                    Text(server.name).font(.body.weight(.medium))
                    ScopeChip(scope: server.scope)
                    if !server.secretKeys.isEmpty {
                        Image(systemName: "key.fill").font(.caption).foregroundStyle(.orange)
                            .help("Holds credentials directly: \(server.secretKeys.joined(separator: ", "))")
                    }
                    Spacer(minLength: 0)
                }
                Text(server.summary).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text(([displayPath(server.file, in: model.project)] + [server.note].compactMap { $0 }).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(rowShape)
        }
        .buttonStyle(.plain)
        .modifier(RowChrome(tint: server.agent.tint, isSelected: false))
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 2) {
                if server.needsApproval {
                    Text("Asks first").font(.caption2).foregroundStyle(.secondary)
                        .help("Claude Code asks you to approve this project server when a session starts. Turn it on to approve it here.")
                }
                Toggle("On", isOn: Binding(get: { isOn }, set: { setEnabled($0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.mini)
                    .disabled(!server.canSwitch)
                    .help(server.canSwitch ? (isOn ? "On: turn off for new sessions" : "Off: turn on for new sessions")
                                           : (MCPEdit.Failure.noSwitch(server).errorDescription ?? ""))
                    .padding(.trailing, 6)
                Button("Edit", systemImage: "pencil") { editing = true }
                    .disabled(!server.editable)
                    .help(server.editable ? "Change this server" : notEditable)
                Button("Remove", systemImage: "trash") { remove() }
                    .help(server.editable ? "Remove this server" : notEditable)
                    .disabled(!server.editable)
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small)
            .padding(8)
        }
        .opacity(server.enabled ? 1 : 0.55)
        .help("Click to open its config file. Right-click to copy it to another agent.")
        .contextMenu {
            Button(isOn ? "Turn Off" : server.needsApproval ? "Approve…" : "Turn On…") { setEnabled(!isOn) }
                .disabled(!server.canSwitch)
            Button("Edit…") { editing = true }.disabled(!server.editable)
            Button("Remove…") { remove() }.disabled(!server.editable)
            if !server.editable, server.file.lastPathComponent == ".claude.json" {
                Button("Copy `claude mcp remove` Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(MCPCopy.claudeRemoveCommand(for: server), forType: .string)
                }
            }
            Divider()
            Menu("Copy to") {
                ForEach(AgentID.allCases.filter { $0 != server.agent }) { agent in
                    Button(agent.displayName) { copy(to: agent) }
                }
            }
            Button("Copy `claude mcp add-json` Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(MCPCopy.claudeCommand(for: server), forType: .string)
            }
            Divider()
            Button("Show Config in Finder") { NSWorkspace.shared.activateFileViewerSelecting([server.file]) }
        }
        .sheet(isPresented: $editing) {
            ServerForm(agent: server.agent, project: nil, existing: server)
        }
        .alert("Couldn’t change the server", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {} message: {
            Text(error ?? "")
        }
    }

    /// A project server Claude Code hasn't approved yet doesn't run, so its
    /// switch shows off until the user approves it.
    private var isOn: Bool { server.enabled && !server.needsApproval }

    private var notEditable: String {
        MCPEdit.Failure.notEditable(server).errorDescription ?? ""
    }

    /// Turning a server off happens at once. Turning one on lets it run a
    /// command, so that change is shown for review first.
    private func setEnabled(_ on: Bool) {
        do {
            let change = try MCPEdit.setEnabled(server, on)
            if on { model.pendingChange = change } else { try model.applyNow(change) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove() {
        do {
            model.pendingChange = try MCPEdit.remove(server)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func copy(to agent: AgentID) {
        var project: URL?
        if case .project(let url) = model.selection { project = url }
        do {
            model.pendingChange = try MCPCopy.plan(server, to: agent, project: project)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The header of the agent section being read, kept at the top of the view
/// while the section's own header is scrolled away. It is set like the
/// section's header, in the bar under the toolbar. Clicking it goes back to
/// the start of the section.
struct PinnedAgentHeader: View {
    let context: ResolvedContext
    let summary: String
    let jump: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: jump) {
            HStack(spacing: 8) {
                AgentIcon(agent: context.agent, size: 22)
                Text(context.agent.displayName).font(.headline)
                Text(summary).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                Image(systemName: "arrow.up").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .opacity(isHovered ? 1 : 0)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Back to the start of \(context.agent.displayName)’s section")
    }
}

/// Case- and diacritic-insensitive matching for the lens's filter field.
enum Search {
    static func matches(_ query: String, _ text: String) -> Bool {
        let terms = query.split(separator: " ")
        return terms.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    static func matches(_ query: String, _ entry: ContextEntry) -> Bool {
        matches(query, [entry.url.path, entry.scope.displayName, entry.note ?? ""].joined(separator: " "))
    }

    static func matches(_ query: String, _ skill: Skill) -> Bool {
        matches(query, [skill.name, skill.description, skill.url.path, skill.scope.displayName].joined(separator: " "))
    }

    static func matches(_ query: String, _ server: MCPServer) -> Bool {
        matches(query, [server.name, server.summary, server.file.path, server.scope.displayName].joined(separator: " "))
    }
}
