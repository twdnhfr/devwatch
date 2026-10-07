import CoreServices
import Foundation
import XCTest
@testable import DevWatchCore

final class RootFolderWatcherTests: XCTestCase {
    @MainActor
    func testSourceAndDependencyChangesDoNotTriggerButNewRepositoryDoes() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("app/.git"), withIntermediateDirectories: true)
        try write("app/package.json", in: root)
        var callbacks = 0
        let watcher = RootFolderWatcher(roots: [root.path], latency: 0.2) { callbacks += 1 }
        try watcher.start()
        defer { watcher.stop() }
        try await pause(1.5)
        XCTAssertEqual(callbacks, 0, "Existing repositories must not trigger a rescan")
        for path in ["app/src/main.js", "app/.git/index", "app/node_modules/vite/package.json",
                     "app/vendor/a.php", "app/storage/logs/a.log", "app/dist/a.js"] {
            try write(path, in: root)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("app/empty"), withIntermediateDirectories: true)
        try await pause(1.5)
        XCTAssertEqual(callbacks, 0, "Source edits and generated files must not trigger a rescan")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("clone/.git"), withIntermediateDirectories: true)
        try await pause(1.5)
        XCTAssertGreaterThan(callbacks, 0, "A new repository must trigger a rescan")
    }

    @MainActor
    func testManifestChangeTriggers() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("app/.git"), withIntermediateDirectories: true)
        var callbacks = 0
        let watcher = RootFolderWatcher(roots: [root.path], latency: 0.2) { callbacks += 1 }
        try watcher.start()
        defer { watcher.stop() }
        try write("app/package.json", in: root)
        try await pause(1.5)
        XCTAssertGreaterThan(callbacks, 0)
    }

    func testMovedFoldersAndDroppedEventsRequireRescan() {
        let isDir = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
        let renamed = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
        let created = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        XCTAssertTrue(RootFolderWatcher.requiresRescan(relativePath: "clients/shop", flags: isDir | renamed))
        XCTAssertFalse(RootFolderWatcher.requiresRescan(relativePath: "clients/shop", flags: isDir | created))
        XCTAssertFalse(RootFolderWatcher.requiresRescan(relativePath: "shop/node_modules/.vite", flags: isDir | renamed))
        XCTAssertTrue(RootFolderWatcher.requiresRescan(relativePath: "shop",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)))
    }

    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("devwatch-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.resolvingSymlinksInPath()
    }

    private func write(_ path: String, in root: URL) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "fixture".write(to: file, atomically: false, encoding: .utf8)
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
