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

    public static let shared = History(directory: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BrainFog/History"))

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
    /// the plan was made. Old and new texts both go into `history`.
    public func apply(history: History = .shared) throws {
        for edit in edits where FileSupport.read(edit.url) != edit.before {
            throw ApplyError.changedOnDisk(edit.url)
        }
        for edit in edits {
            try FileWriter.write(edit.after, to: edit.url, history: history)
        }
    }
}

/// The one way BrainFog writes a file: the old text is kept in History first.
public enum FileWriter {
    public static func write(_ text: String, to url: URL, history: History = .shared) throws {
        if let old = FileSupport.read(url) {
            history.record(url, text: old, origin: .beforeChange)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        history.record(url, text: text, origin: .brainFog)
    }
}
