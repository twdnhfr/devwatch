import CoreServices
import Foundation

/// Watches only future changes. It does not scan the initial contents or follow symlink targets.
@MainActor
public final class ProjectWatcher {
    private let directory: URL
    private let watchedPath: String
    private let onChange: ([String]) -> Void
    private let onError: (String) -> Void
    private var stream: FSEventStreamRef?
    private var pendingPaths = Set<String>()
    private var delivery: DispatchWorkItem?
    private var generation = UUID()
    private var startedAt: TimeInterval = 0

    public init(directory: URL, onChange: @escaping ([String]) -> Void,
                onError: @escaping (String) -> Void) {
        self.directory = directory.resolvingSymlinksInPath().standardizedFileURL
        // URL.path may normalize /private/var back to /var, while FSEvents uses
        // the physical path. Keep realpath's string without another URL roundtrip.
        if let physical = realpath(directory.path, nil) {
            watchedPath = String(cString: physical)
            free(physical)
        } else {
            watchedPath = directory.standardizedFileURL.path
        }
        self.onChange = onChange
        self.onError = onError
    }

    public func start() throws {
        guard stream == nil else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WatcherError("Projektordner ist nicht mehr vorhanden.")
        }
        generation = UUID()
        startedAt = Date().timeIntervalSince1970
        let contextBox = WatcherContext(self)
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(contextBox).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<WatcherContext>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                if let pointer { Unmanaged<WatcherContext>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(nil, { source, info, count, paths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<WatcherContext>.fromOpaque(info).takeUnretainedValue()
            let values = unsafeBitCast(paths, to: NSArray.self) as! [String]
            let eventFlags = Array(UnsafeBufferPointer(start: flags, count: count))
            // FSEvents is explicitly scheduled on DispatchQueue.main below.
            MainActor.assumeIsolated {
                box.watcher?.receive(source: source, paths: values, flags: eventFlags)
            }
        }, &context, [watchedPath] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.15, flags) else {
            throw WatcherError("Dateibeobachtung konnte nicht eingerichtet werden.")
        }
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            throw WatcherError("Dateibeobachtung konnte nicht gestartet werden.")
        }
        stream = created
    }

    public func stop() {
        generation = UUID()
        delivery?.cancel()
        delivery = nil
        pendingPaths.removeAll()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    deinit {
        delivery?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func receive(source: ConstFSEventStreamRef, paths: [String], flags: [FSEventStreamEventFlags]) {
        guard let stream, source == stream else { return }
        let invalid = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs |
            kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
            kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged |
            kFSEventStreamEventFlagUnmount)
        if flags.contains(where: { $0 & invalid != 0 }) {
            fail("Dateibeobachtung pausiert: Projektordner wurde verschoben oder Dateiänderungen konnten nicht vollständig erfasst werden. Bitte Projekt prüfen und erneut aktivieren.")
            return
        }
        let prefix = watchedPath + "/"
        let changes = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated |
            kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed |
            kFSEventStreamEventFlagItemModified)
        var hasRelevantEvent = false
        for (path, eventFlags) in zip(paths, flags) {
            guard path.hasPrefix(prefix), eventFlags & changes != 0 else { continue }
            let relative = String(path.dropFirst(prefix.count))
            guard !Self.isExcluded(relative) else { continue }
            // fseventsd may still deliver a pre-start write from its current batch,
            // even with SinceNow. Check only reported paths (no initial tree scan).
            guard changedSinceStart(path) else { continue }
            if eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
                // Renaming/removing a subtree can affect source files without individual
                // file events. Treat those conservatively, but ignore plain mkdir/metadata.
                let subtreeChanges = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed |
                    kFSEventStreamEventFlagItemRemoved)
                guard eventFlags & subtreeChanges != 0 else { continue }
            }
            pendingPaths.insert(relative)
            hasRelevantEvent = true
        }
        guard hasRelevantEvent else { return }
        delivery?.cancel()
        let token = UUID()
        generation = token
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.stream != nil, self.generation == token else { return }
            let paths = self.pendingPaths.sorted()
            self.pendingPaths.removeAll()
            self.delivery = nil
            self.onChange(paths)
        }
        delivery = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func fail(_ message: String) {
        stop()
        onError(message)
    }

    private func changedSinceStart(_ path: String) -> Bool {
        var candidate = path
        while candidate.hasPrefix(watchedPath) {
            var metadata = stat()
            if lstat(candidate, &metadata) == 0 {
                let modified = Double(metadata.st_mtimespec.tv_sec) + Double(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
                let changed = Double(metadata.st_ctimespec.tv_sec) + Double(metadata.st_ctimespec.tv_nsec) / 1_000_000_000
                return max(modified, changed) >= startedAt
            }
            // A removed/renamed path is absent; its nearest surviving parent's
            // metadata records the directory-entry change instead.
            guard candidate != watchedPath,
                  let slash = candidate.lastIndex(of: "/") else { break }
            candidate = String(candidate[..<slash])
        }
        return false
    }

    private static func isExcluded(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/").map(String.init)
        let ignored: Set<String> = [".git", "node_modules", "vendor", "storage", "dist"]
        if parts.contains(where: { ignored.contains($0) }) { return true }
        for path in ["bootstrap/cache", "public/build", "public/hot"] {
            if relative == path || relative.hasPrefix(path + "/") { return true }
        }
        guard let name = parts.last else { return true }
        return name == ".DS_Store" || name.hasPrefix(".#") || name.hasPrefix("~$") ||
            (name.hasPrefix("#") && name.hasSuffix("#")) || name.hasSuffix("~") ||
            [".swp", ".swo", ".swx", ".tmp", ".temp"].contains { name.hasSuffix($0) }
    }
}

private final class WatcherContext {
    weak var watcher: ProjectWatcher?
    init(_ watcher: ProjectWatcher) { self.watcher = watcher }
}

private struct WatcherError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
