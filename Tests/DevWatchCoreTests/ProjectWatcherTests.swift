import Foundation
import XCTest
@testable import DevWatchCore

final class ProjectWatcherTests: XCTestCase {
    @MainActor
    func testInitialFilesAndExcludedChangesDoNotTrigger() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("app.php", in: root)
        var callbacks: [[String]] = []
        var errors: [String] = []
        let watcher = ProjectWatcher(directory: root, onChange: { callbacks.append($0) }, onError: { errors.append($0) })
        try watcher.start()
        defer { watcher.stop() }
        try await pause(2)
        XCTAssertTrue(callbacks.isEmpty, "Existing files must not trigger startup")
        for path in [".git/index", "node_modules/vite/index.js", "vendor/a.php", "storage/logs/a.log",
                     "bootstrap/cache/a.php", "public/build/a.js", "public/hot", "dist/a.js",
                     ".DS_Store", ".app.php.swp", "app.php~", "scratch.tmp"] {
            try write(path, in: root)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try await pause(2)
        XCTAssertTrue(callbacks.isEmpty, "Generated files and plain directory creation must be ignored")
        XCTAssertTrue(errors.isEmpty)
    }

    @MainActor
    func testBurstIncludesSourceRenameAndDeletionInOneCallback() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var callbacks: [[String]] = []
        var errors: [String] = []
        let watcher = ProjectWatcher(directory: root, onChange: { callbacks.append($0) }, onError: { errors.append($0) })
        try watcher.start()
        defer { watcher.stop() }
        try write("resources/views/start.blade.php", in: root)
        try write("vite.config.js", in: root)
        try write("remove.php", in: root)
        try FileManager.default.moveItem(at: root.appendingPathComponent("resources/views/start.blade.php"),
                                         to: root.appendingPathComponent("resources/views/end.blade.php"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("remove.php"))
        try await pause(2.5)
        XCTAssertEqual(callbacks.count, 1)
        let paths = callbacks.flatMap { $0 }
        XCTAssertTrue(paths.contains("resources/views/end.blade.php"))
        XCTAssertTrue(paths.contains("remove.php"))
        XCTAssertTrue(paths.contains("vite.config.js"))
        XCTAssertTrue(errors.isEmpty)
    }

    @MainActor
    func testStopCancelsPendingDebounceAndRestartHasNoReplay() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var callbacks: [[String]] = []
        let watcher = ProjectWatcher(directory: root, onChange: { callbacks.append($0) }, onError: { XCTFail($0) })
        try watcher.start()
        defer { watcher.stop() }
        try write("app.php", in: root)
        try await pause(0.4)
        watcher.stop()
        try await pause(1.5)
        XCTAssertTrue(callbacks.isEmpty)
        try watcher.start()
        try await pause(1.5)
        XCTAssertTrue(callbacks.isEmpty)
        try write("new.php", in: root)
        try await pause(2)
        XCTAssertEqual(callbacks.count, 1)
        XCTAssertEqual(callbacks.first, ["new.php"])
    }

    @MainActor
    func testMovingRootPausesInsteadOfReportingChanges() async throws {
        let parent = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var callbacks: [[String]] = []
        var errors: [String] = []
        let watcher = ProjectWatcher(directory: root, onChange: { callbacks.append($0) }, onError: { errors.append($0) })
        try watcher.start()
        defer { watcher.stop() }
        try FileManager.default.moveItem(at: root, to: parent.appendingPathComponent("moved"))
        try await pause(2)
        XCTAssertTrue(callbacks.isEmpty)
        XCTAssertEqual(errors.count, 1)
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
