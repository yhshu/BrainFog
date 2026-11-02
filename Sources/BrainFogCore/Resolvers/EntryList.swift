import Foundation

/// Accumulates entries for one agent in prompt order, de-duplicating by path.
struct EntryList {
    let agent: AgentID
    private(set) var entries: [ContextEntry] = []
    var diagnostics: [Diagnostic] = []
    private var seen = Set<String>()

    init(agent: AgentID) { self.agent = agent }

    func contains(_ url: URL) -> Bool { seen.contains(url.standardizedFileURL.path) }

    /// Adds `url` if it is an existing file not yet listed. `visible` trims
    /// the text to what actually reaches the context and reports truncation.
    @discardableResult
    mutating func add(_ url: URL, scope: Scope, timing: LoadTiming = .launch,
                      note: String? = nil, importedBy: URL? = nil,
                      visible: ((String) -> (String, Bool))? = nil) -> String? {
        let url = url.standardizedFileURL
        guard FileSupport.isFile(url), !seen.contains(url.path) else { return nil }
        seen.insert(url.path)
        let text = FileSupport.read(url) ?? ""
        let (shown, truncated) = visible?(text) ?? (text, false)
        entries.append(ContextEntry(
            agent: agent, url: url, scope: scope, timing: timing, order: entries.count,
            tokens: TokenEstimator.estimate(shown),
            truncated: truncated, importedBy: importedBy, note: note))
        return text
    }

    /// Marks an entry already listed as loaded at launch through an import.
    /// Returns its text when it was not loaded at launch before.
    mutating func promote(_ url: URL, importedBy: URL) -> String? {
        let path = url.standardizedFileURL.path
        guard let i = entries.firstIndex(where: { $0.url.path == path }),
              !entries[i].timing.isLoadedAtLaunch else { return nil }
        entries[i].timing = .launch
        entries[i].importedBy = importedBy
        return FileSupport.read(url) ?? ""
    }

    /// Lists something that is not a local file, such as a remote URL.
    mutating func addRemote(_ url: URL, scope: Scope, timing: LoadTiming, note: String) {
        guard !seen.contains(url.absoluteString) else { return }
        seen.insert(url.absoluteString)
        entries.append(ContextEntry(agent: agent, url: url, scope: scope, timing: timing,
                                    order: entries.count, note: note))
    }

    func finish(workingDirectory: URL, projectRoot: URL?) -> ResolvedContext {
        ResolvedContext(agent: agent, workingDirectory: workingDirectory, projectRoot: projectRoot,
                        entries: entries, diagnostics: diagnostics)
    }
}

enum Limits {
    /// Keeps the first `lines` lines, then cuts to `bytes` bytes.
    static func head(lines: Int, bytes: Int) -> (String) -> (String, Bool) {
        { text in
            var kept = text.components(separatedBy: "\n")
            var truncated = false
            if kept.count > lines { kept = Array(kept.prefix(lines)); truncated = true }
            var result = kept.joined(separator: "\n")
            if result.utf8.count > bytes {
                result = String(decoding: result.utf8.prefix(bytes), as: UTF8.self)
                truncated = true
            }
            return (result, truncated)
        }
    }

    static func bytes(_ max: Int) -> (String) -> (String, Bool) {
        { text in
            text.utf8.count > max
                ? (String(decoding: text.utf8.prefix(max), as: UTF8.self), true)
                : (text, false)
        }
    }
}
