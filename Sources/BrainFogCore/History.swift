import CryptoKit
import Foundation

/// Every version of a context file BrainFog has seen or written, so any of
/// them can be brought back. Contents are stored once per hash under
/// `objects/`, and each file has a small JSON log under `files/`.
public final class History: @unchecked Sendable {
    public enum Origin: String, Codable, Sendable {
        /// Found on disk when BrainFog looked, e.g. after an agent wrote it.
        case observed
        /// Written by BrainFog (the editor, a copy, a fix).
        case brainFog
        /// The text a file had just before BrainFog changed it.
        case beforeChange
    }

    public struct Version: Codable, Sendable, Hashable, Identifiable {
        public var id: String { hash + String(date.timeIntervalSince1970) }
        public var hash: String
        public var date: Date
        public var origin: Origin
        public var bytes: Int
    }

    /// One change to a file: a version and the one before it.
    public struct Change: Sendable, Hashable, Identifiable {
        public var id: String { url.path + version.id }
        public var url: URL
        public var version: Version
        public var previous: Version
    }

    public static let shared = History(directory: ResolverEnvironment.defaultHome
        .appendingPathComponent("Library/Application Support/BrainFog/History"))

    /// Versions kept per file; the oldest go first.
    public static let maxVersions = 200
    /// Larger files are not recorded.
    public static let maxBytes = 1 << 20

    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    /// Adds `text` as the newest version of `url` unless it already is.
    @discardableResult
    public func record(_ url: URL, text: String, origin: Origin, date: Date = Date()) -> Version? {
        let data = Data(text.utf8)
        guard data.count <= Self.maxBytes else { return nil }
        let hash = Self.hash(data)
        lock.lock()
        defer { lock.unlock() }
        var log = load(url)
        if let last = log.last, last.hash == hash {
            // Saving what was already there says more than having seen it.
            if origin == .brainFog, last.origin != .brainFog {
                log[log.count - 1].origin = .brainFog
                save(log, for: url)
            }
            return nil
        }
        let object = objectURL(hash)
        if !FileManager.default.fileExists(atPath: object.path) {
            try? FileManager.default.createDirectory(at: object.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: object, options: .atomic)
        }
        let version = Version(hash: hash, date: date, origin: origin, bytes: data.count)
        log.append(version)
        if log.count > Self.maxVersions { log.removeFirst(log.count - Self.maxVersions) }
        save(log, for: url)
        return version
    }

    /// Records what is on disk now, if it is a readable text file.
    public func observe(_ url: URL) {
        guard url.isFileURL, FileSupport.size(url) <= Self.maxBytes, let text = FileSupport.read(url) else { return }
        record(url, text: text, origin: .observed)
    }

    /// Newest first.
    public func versions(of url: URL) -> [Version] {
        lock.lock()
        defer { lock.unlock() }
        return load(url).reversed()
    }

    /// Changes to the given files, newest first. A file's first version
    /// is where its history starts, not a change, and a copy kept just
    /// before BrainFog wrote is only the "before" of the write after it.
    public func changes(to urls: Set<URL>, limit: Int = 300) -> [Change] {
        var out: [Change] = []
        lock.lock()
        defer { lock.unlock() }
        for url in urls {
            let log = load(url)
            for i in log.indices.dropFirst() where log[i].origin != .beforeChange {
                out.append(Change(url: url, version: log[i], previous: log[i - 1]))
            }
        }
        // Later in a log is newer even when the clock reads the same.
        let sorted = out.enumerated().sorted { ($0.element.version.date, $0.offset) > ($1.element.version.date, $1.offset) }
        return Array(sorted.map(\.element).prefix(limit))
    }

    /// Puts a file back the way it was before `change`, as a change to
    /// review. Nil when its old text is gone or the file already has it.
    public func undo(_ change: Change) -> ChangeSet? {
        guard let old = text(of: change.previous) else { return nil }
        let now = FileSupport.read(change.url)
        guard now != old else { return nil }
        let name = change.url.lastPathComponent
        return ChangeSet(title: "Undo the change to \(name)?",
                         detail: "\(name) goes back to how it was before \(change.version.date.formatted(date: .abbreviated, time: .shortened)). Anything written to it since is replaced too, and stays in its History.",
                         edits: [FileEdit(url: change.url, before: now, after: old)])
    }

    public func text(of version: Version) -> String? {
        FileManager.default.contents(atPath: objectURL(version.hash).path).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: Storage

    private func logURL(_ url: URL) -> URL {
        directory.appendingPathComponent("files")
            .appendingPathComponent(Self.hash(Data(url.standardizedFileURL.path.utf8)) + ".json")
    }

    private func objectURL(_ hash: String) -> URL {
        directory.appendingPathComponent("objects").appendingPathComponent(String(hash.prefix(2)))
            .appendingPathComponent(hash)
    }

    private func load(_ url: URL) -> [Version] {
        guard let data = FileManager.default.contents(atPath: logURL(url).path) else { return [] }
        return (try? Self.decoder.decode([Version].self, from: data)) ?? []
    }

    private func save(_ log: [Version], for url: URL) {
        let file = logURL(url)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Self.encoder.encode(log).write(to: file, options: .atomic)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// One file change BrainFog proposes, shown to the user before it happens.
public struct FileEdit: Identifiable, Sendable, Hashable {
    public var id: String { url.path }
    public var url: URL
    /// The text the change was planned against; nil for a new file.
    public var before: String?
    public var after: String

    public init(url: URL, before: String?, after: String) {
        self.url = url.standardizedFileURL
        self.before = before
        self.after = after
    }

    /// A change that adds `text` to the end of `url`, creating it if needed.
    public static func append(_ text: String, to url: URL) -> FileEdit {
        let existing = FileSupport.read(url)
        var start = existing ?? ""
        if !start.isEmpty && !start.hasSuffix("\n") { start += "\n" }
        if !start.isEmpty { start += "\n" }
        return FileEdit(url: url, before: existing, after: start + text)
    }

    public var isNewFile: Bool { before == nil }
}

/// A set of file edits applied together, after the user has seen them.
public struct ChangeSet: Identifiable, Sendable, Hashable {
    public var id: String { title + edits.map(\.id).joined() }
    public var title: String
    public var detail: String
    public var edits: [FileEdit]

    public init(title: String, detail: String, edits: [FileEdit]) {
        self.title = title
        self.detail = detail
        self.edits = edits
    }

    public enum ApplyError: LocalizedError {
        case changedOnDisk(URL)
        public var errorDescription: String? {
            switch self {
            case .changedOnDisk(let url):
                "\(url.lastPathComponent) changed on disk after the change was prepared. Nothing was written."
            }
        }
    }

    /// Writes every edit, refusing all of them if any target changed since
    /// the plan was made. Old and new texts both go into `history`. If a
    /// write fails anyway, the edits already written are put back.
    public func apply(history: History = .shared) throws {
        let fm = FileManager.default
        for edit in edits {
            if FileSupport.read(edit.url) != edit.before { throw ApplyError.changedOnDisk(edit.url) }
            // The nearest folder that exists must be a folder, or the write can't happen.
            var dir = edit.url.deletingLastPathComponent()
            while !fm.fileExists(atPath: dir.path) && dir.path != "/" { dir = dir.deletingLastPathComponent() }
            if !FileSupport.isDirectory(dir) || FileSupport.isDirectory(edit.url) {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: edit.url.path])
            }
        }
        var written: [FileEdit] = []
        do {
            for edit in edits {
                try FileWriter.write(edit.after, to: edit.url, history: history)
                written.append(edit)
            }
        } catch {
            for edit in written.reversed() {
                if let before = edit.before {
                    try? before.write(to: edit.url.resolvingSymlinksInPath(), atomically: true, encoding: .utf8)
                } else {
                    try? fm.removeItem(at: edit.url)
                }
            }
            throw error
        }
    }
}

/// The one way BrainFog writes a file: the old text is kept in History first.
public enum FileWriter {
    public static func write(_ text: String, to url: URL, history: History = .shared) throws {
        if let old = FileSupport.read(url) {
            history.record(url, text: old, origin: .beforeChange)
        }
        // Write through a symlink (`ln -s AGENTS.md CLAUDE.md`) so the link stays.
        let target = url.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: target, atomically: true, encoding: .utf8)
        history.record(url, text: text, origin: .brainFog)
    }
}
