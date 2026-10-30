import AppKit
import SwiftUI
import BrainFogCore

/// Adds an MCP server to an agent, or changes one it has. The result is a
/// change the user reviews as a diff before anything is written.
struct ServerForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let agent: AgentID
    let project: URL?
    let existing: MCPServer?

    @State private var name = ""
    @State private var remote = false
    @State private var command = ""
    @State private var args = ""
    @State private var env = ""
    @State private var url = ""
    @State private var transport = "http"
    @State private var headers = ""
    @State private var enabled = true
    @State private var file: URL?
    @State private var error: String?
    @State private var files: [MCPConfigFile] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(existing == nil ? "New MCP Server for \(agent.displayName)" : "Edit \(existing!.name)")
                    .font(.title2.weight(.semibold))
                if let existing {
                    Text(displayPath(existing.file)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)

            Form {
                TextField("Name", text: $name, prompt: Text("github"))
                Picker("Runs", selection: $remote) {
                    Text("A command").tag(false)
                    Text("At a URL").tag(true)
                }
                .pickerStyle(.segmented)

                if remote {
                    TextField("URL", text: $url, prompt: Text("https://example.com/mcp"))
                    Picker("Transport", selection: $transport) {
                        Text("Streamable HTTP").tag("http")
                        Text("SSE").tag("sse")
                    }
                    LabeledLines(title: "Headers", hint: "One per line: Authorization: Bearer ${TOKEN}", text: $headers)
                } else {
                    TextField("Command", text: $command, prompt: Text("npx"))
                    LabeledLines(title: "Arguments", hint: "One per line", text: $args)
                    LabeledLines(title: "Environment", hint: "One per line: GITHUB_TOKEN=${GITHUB_TOKEN}", text: $env)
                }
                if existing?.canSwitch ?? [.codex, .openCode, .cline, .devin].contains(agent) {
                    Toggle("Enabled", isOn: $enabled)
                }

                if existing == nil {
                    if files.isEmpty {
                        Text(MCPEdit.Failure.noFile(agent).errorDescription ?? "")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Picker("Save in", selection: $file) {
                            ForEach(files) { f in
                                Text("\(f.scope.displayName) · \(displayPath(f.file))\(f.note.map { " (\($0))" } ?? "")")
                                    .tag(Optional(f.file))
                            }
                        }
                    }
                }
                if !draft.secretKeys.isEmpty {
                    Label("\(draft.secretKeys.joined(separator: ", ")) looks like a credential written out in full. A reference such as ${NAME} keeps it out of the file.",
                          systemImage: "key.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error {
                    Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).font(.callout)
                }
            }
            .formStyle(.grouped)

            HStack {
                if agent == .claudeCode {
                    Button("Copy `claude mcp add-json` Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(MCPCopy.claudeCommand(for: draft), forType: .string)
                    }
                    .disabled(!isValid)
                    .help("For Claude Code's global servers, which live in ~/.claude.json")
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Review Change…", action: review)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(!isValid || (existing == nil && file == nil))
            }
            .padding(16)
        }
        .frame(width: 560, height: 600)
        .onAppear(perform: load)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (remote ? !url.trimmingCharacters(in: .whitespaces).isEmpty
                       : !command.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// The server as the form describes it.
    private var draft: MCPServer {
        var s = existing ?? MCPServer(agent: agent, name: "", scope: .user, file: URL(fileURLWithPath: "/"))
        s.name = name.trimmingCharacters(in: .whitespaces)
        s.enabled = enabled
        if remote {
            s.url = url.trimmingCharacters(in: .whitespaces)
            s.transport = transport
            s.headers = pairs(headers, separator: ":")
            s.command = nil
            s.args = []
            s.env = [:]
        } else {
            s.command = command.trimmingCharacters(in: .whitespaces)
            s.args = lines(args)
            s.env = pairs(env, separator: "=")
            s.url = nil
            s.transport = nil
            s.headers = [:]
        }
        return s
    }

    private func load() {
        files = MCPResolver.editableFiles(for: agent, project: project)
        file = files.first?.file
        guard let s = existing else { return }
        name = s.name
        remote = s.isRemote
        command = s.command ?? ""
        args = s.args.joined(separator: "\n")
        env = s.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        url = s.url ?? ""
        transport = s.transport ?? "http"
        headers = s.headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        enabled = s.enabled
    }

    private func review() {
        do {
            let change = if let existing {
                try MCPEdit.replace(existing, with: draft)
            } else {
                try MCPEdit.add(draft, to: agent, file: file, project: project)
            }
            dismiss()
            // Let this sheet close before the preview opens.
            DispatchQueue.main.async { model.pendingChange = change }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func pairs(_ text: String, separator: Character) -> [String: String] {
        var out: [String: String] = [:]
        for line in lines(text) {
            guard let i = line.firstIndex(of: separator) else { continue }
            let key = line[..<i].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out[key] = value }
        }
        return out
    }
}

/// A small multi-line text field with a hint under it.
private struct LabeledLines: View {
    let title: String
    let hint: String
    @Binding var text: String

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .leading, spacing: 3) {
                TextEditor(text: $text)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 54, maxHeight: 90)
                    .scrollContentBackground(.hidden)
                    .background(.background.secondary, in: .rect(cornerRadius: 6))
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
