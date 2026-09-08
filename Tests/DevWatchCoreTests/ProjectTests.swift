import Foundation
import XCTest
@testable import DevWatchCore

final class ProjectTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevWatchProjectTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func write(_ filename: String, _ contents: String = "") throws {
        try Data(contents.utf8).write(to: directory.appendingPathComponent(filename))
    }

    func testExplicitPackageManagerTakesPriorityOverConflictingLockfiles() throws {
        try write("package.json", #"{"scripts":{"dev":"vite"},"packageManager":"pnpm@9.0.0"}"#)
        try write("yarn.lock")
        try write("package-lock.json")
        let project = try ProjectDiscovery.inspect(directory: directory)
        XCTAssertEqual(project.executable, "pnpm")
        XCTAssertEqual(project.arguments, ["run", "dev"])
        XCTAssertEqual(project.directoryPath, directory.resolvingSymlinksInPath().path)
    }

    func testBunLockfileFormatsCountAsOneManager() throws {
        try write("package.json", #"{"scripts":{"dev":"vite"}}"#)
        try write("bun.lock")
        try write("bun.lockb")
        XCTAssertEqual(try ProjectDiscovery.inspect(directory: directory).executable, "bun")
    }

    func testConflictingLockfilesRequireResolution() throws {
        try write("package.json", #"{"scripts":{"dev":"vite"}}"#)
        try write("bun.lock")
        try write("pnpm-lock.yaml")
        XCTAssertThrowsError(try ProjectDiscovery.inspect(directory: directory)) { error in
            XCTAssertEqual(error as? ProjectDiscovery.DiscoveryError, .ambiguousLockfiles(["bun", "pnpm"]))
        }
    }

    func testMissingOrBlankDevScriptIsRejected() throws {
        for manifest in [#"{}"#, #"{"scripts":{"build":"vite build"}}"#, #"{"scripts":{"dev":"  "}}"#] {
            try write("package.json", manifest)
            XCTAssertThrowsError(try ProjectDiscovery.inspect(directory: directory)) { error in
                XCTAssertEqual(error as? ProjectDiscovery.DiscoveryError, .missingDevScript)
            }
        }
    }

    func testUnsupportedManagerDoesNotFallBackToLockfiles() throws {
        try write("package.json", #"{"scripts":{"dev":"vite"},"packageManager":"unknown@1"}"#)
        try write("bun.lock")
        XCTAssertThrowsError(try ProjectDiscovery.inspect(directory: directory)) { error in
            XCTAssertEqual(error as? ProjectDiscovery.DiscoveryError, .unsupportedPackageManager("unknown@1"))
        }
    }

    func testNoManagerHintSuggestsNpm() throws {
        try write("package.json", #"{"scripts":{"dev":"vite"}}"#)
        XCTAssertEqual(try ProjectDiscovery.inspect(directory: directory).executable, "npm")
    }

    func testStorageRoundTripAndReplacement() throws {
        let storage = ProjectStorage(fileURL: directory.appendingPathComponent("settings/projects.json"))
        XCTAssertEqual(try storage.load(), [])
        let projects = [DevProject(directoryPath: directory.path, executable: "pnpm", arguments: ["run", "dev", "--", "--host"])]
        try storage.save(projects)
        XCTAssertEqual(try storage.load(), projects)
        try storage.save([])
        XCTAssertEqual(try storage.load(), [])
    }

    func testCorruptStorageIsReportedInsteadOfDiscarded() throws {
        try write("projects.json", "not json")
        let storage = ProjectStorage(fileURL: directory.appendingPathComponent("projects.json"))
        XCTAssertThrowsError(try storage.load())
    }
}
