import CoreServices
import Foundation

/// Watches the folders that hold the agents' files and calls back, at most
/// once per `latency`, when one of those files, or a new file that could be
/// one, changes. This is what lets the timeline catch an agent writing its
/// memory while BrainFog is open, not only on the next refresh.
@MainActor final class FileWatcher {
    private var stream: FSEventStreamRef?
    private var files: Set<String> = []
    private var folders: [String] = []
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    /// Starts watching the folders of `urls`; does nothing when they are
    /// the same as last time.
    func watch(_ urls: Set<URL>) {
        let files = Set(urls.filter(\.isFileURL).map { $0.resolvingSymlinksInPath().path })
        // A folder inside another watched folder is already covered.
        let dirs = Set(files.map { ($0 as NSString).deletingLastPathComponent }).sorted()
        let folders = dirs.filter { d in !dirs.contains { d != $0 && d.hasPrefix($0 + "/") } }
        guard folders != self.folders else { self.files = files; return }
        stop()
        self.files = files
        self.folders = folders
        guard !folders.isEmpty else { return }

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        // Events arrive on the main queue, set below.
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            MainActor.assumeIsolated {
                let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
                if list.prefix(count).contains(where: watcher.matters) { watcher.onChange() }
            }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                           | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, folders as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               0.5, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// A known file, or a new text or config file outside build and VCS
    /// folders. Watched folders are often whole repositories, so most
    /// events there are noise.
    private func matters(_ path: String) -> Bool {
        if files.contains(path) { return true }
        if ["/.git/", "/node_modules/", "/.build/", "/build/", "/DerivedData/", "/Library/"].contains(where: path.contains) { return false }
        return ["md", "mdc", "txt", "json", "jsonc", "toml"].contains((path as NSString).pathExtension.lowercased())
    }
}
