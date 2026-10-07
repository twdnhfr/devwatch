import CoreServices
import Foundation

/// Reports changes in root folders that can add, remove or reconfigure a repository,
/// so discovery does not have to walk every root on a timer.
@MainActor
public final class RootFolderWatcher {
    private let roots: [String]
    private let latency: CFTimeInterval
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "DevWatch.RootFolderWatcher", qos: .utility)

    public init(roots: [String], latency: CFTimeInterval = 2, onChange: @escaping () -> Void) {
        // FSEvents reports physical paths, see ProjectWatcher.
        self.roots = roots.map { root in
            guard let physical = realpath(root, nil) else { return root }
            defer { free(physical) }
            return String(cString: physical)
        }
        self.latency = latency
        self.onChange = onChange
    }

    public func start() throws {
        guard stream == nil else { return }
        guard !roots.isEmpty else { return }
        let contextBox = RootWatcherContext(self, roots: roots)
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(contextBox).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<RootWatcherContext>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                if let pointer { Unmanaged<RootWatcherContext>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<RootWatcherContext>.fromOpaque(info).takeUnretainedValue()
            let values = unsafeBitCast(paths, to: NSArray.self) as! [String]
            let eventFlags = UnsafeBufferPointer(start: flags, count: count)
            // Filter off the main thread: installs and builds report thousands of irrelevant paths.
            guard zip(values, eventFlags).contains(where: { box.requiresRescan(path: $0, flags: $1) }) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { box.watcher?.deliver() }
            }
        }, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency, flags) else {
            throw WatcherError(L10n.text("Could not set up file watching."))
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            throw WatcherError(L10n.text("Could not start file watching."))
        }
        stream = created
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func deliver() {
        guard stream != nil else { return }
        onChange()
    }

    nonisolated private static let manifests: Set<String> = [
        "package.json", "bun.lock", "bun.lockb", "package-lock.json", "npm-shrinkwrap.json",
        "yarn.lock", "pnpm-lock.yaml"
    ]

    /// `relativePath` is relative to the root folder; an empty path is the root itself.
    nonisolated static func requiresRescan(relativePath: String, flags: FSEventStreamEventFlags) -> Bool {
        // The affected subtree is unknown, so only a full scan can tell what changed.
        let unknown = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs |
            kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
            kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged)
        if flags & unknown != 0 { return true }
        let parts = relativePath.split(separator: "/").map(String.init)
        guard let name = parts.last else { return false }
        // The scanner never enters these folders, including the internals of .git.
        if parts.dropLast().contains(where: { RepositoryScanner.excludedDirectories.contains($0) }) { return false }
        let entryChanges = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated |
            kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
        if name == ".git" { return flags & entryChanges != 0 }
        if manifests.contains(name) {
            return flags & (entryChanges | FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)) != 0
        }
        // A moved or deleted folder may hold repositories without reporting their .git entries.
        guard flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0,
              !RepositoryScanner.excludedDirectories.contains(name) else { return false }
        return flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed |
            kFSEventStreamEventFlagItemRemoved) != 0
    }
}

private final class RootWatcherContext: @unchecked Sendable {
    /// Read on the main thread only.
    weak var watcher: RootFolderWatcher?
    private let roots: [String]
    private let startedAt = Date().timeIntervalSince1970

    init(_ watcher: RootFolderWatcher, roots: [String]) {
        self.watcher = watcher
        self.roots = roots
    }

    func requiresRescan(path: String, flags: FSEventStreamEventFlags) -> Bool {
        guard let root = roots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
            return flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
        }
        let relative = path == root ? "" : String(path.dropFirst(root.count + 1))
        guard RootFolderWatcher.requiresRescan(relativePath: relative, flags: flags) else { return false }
        // fseventsd may still deliver a pre-start change, even with SinceNow. Only item
        // events name a path whose metadata tells; a removed path is always news.
        let item = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemIsFile)
        var metadata = stat()
        guard flags & item != 0, lstat(path, &metadata) == 0 else { return true }
        let modified = Double(metadata.st_mtimespec.tv_sec) + Double(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
        let changed = Double(metadata.st_ctimespec.tv_sec) + Double(metadata.st_ctimespec.tv_nsec) / 1_000_000_000
        return max(modified, changed) >= startedAt
    }
}

private struct WatcherError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
