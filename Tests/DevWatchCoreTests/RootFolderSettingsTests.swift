import Foundation
import XCTest
@testable import DevWatchCore

final class RootFolderSettingsTests: XCTestCase {
    func testAbsentSettingsReturnDefaultsWithoutCreatingFile() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("roots.json")
        let storage = RootFolderSettingsStorage(fileURL: file)
        XCTAssertEqual(try storage.load(), RootFolderSettings())
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testRoundtripAndReplacementPreservePaths() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("nested/roots.json")
        let storage = RootFolderSettingsStorage(fileURL: file)
        let original = RootFolderSettings(paths: ["/Users/example/My Projects", "/tmp/äöü"],
                                          hiddenRepositoryPaths: ["/Users/example/My Projects/old"])
        try storage.save(original)
        XCTAssertEqual(try RootFolderSettingsStorage(fileURL: file).load(), original)
        let replacement = RootFolderSettings(paths: ["/new-root"])
        try storage.save(replacement)
        XCTAssertEqual(try storage.load(), replacement)
    }

    func testCorruptSettingsThrowAndRemainUntouched() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("roots.json")
        let invalid = Data("not valid JSON".utf8)
        try invalid.write(to: file)
        XCTAssertThrowsError(try RootFolderSettingsStorage(fileURL: file).load())
        XCTAssertEqual(try Data(contentsOf: file), invalid)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("devwatch-settings-" + UUID().uuidString)
    }
}
