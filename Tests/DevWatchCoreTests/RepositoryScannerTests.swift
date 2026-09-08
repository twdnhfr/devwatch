import Foundation
import XCTest
@testable import DevWatchCore

final class RepositoryScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevWatchScannerTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func repository(_ relative: String, gitFile: Bool = false, manifest: String? = #"{"scripts":{"dev":"vite"},"packageManager":"bun@1"}"#) throws -> URL {
        let directory = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appendingPathComponent(".git")
        if gitFile {
            try Data("gitdir: ../main/.git/worktrees/example\n".utf8).write(to: marker)
        } else {
            try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        }
        if let manifest {
            try Data(manifest.utf8).write(to: directory.appendingPathComponent("package.json"))
        }
        return directory
    }

    func testFindsOrdinaryNestedAndHiddenWorktreeRepositories() throws {
        let main = try repository("main")
        let nested = try repository("main/nested", gitFile: true)
        let worktree = try repository(".worktrees/feature", gitFile: true)
        let result = RepositoryScanner.scan(roots: [root.path])
        XCTAssertEqual(Set(result.repositories.map(\.directoryPath)), Set([main.path, nested.path, worktree.path]))
        XCTAssertTrue(result.repositories.allSatisfy { $0.project?.executable == "bun" && $0.issue == nil })
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testDependencyBuildAndGitDirectoriesAreSkipped() throws {
        for directory in ["vendor", "node_modules", "storage", "dist", "build", ".build", ".swiftpm", ".cache", ".git"] {
            try repository("\(directory)/hidden-repository")
        }
        let visible = try repository("visible")
        let result = RepositoryScanner.scan(roots: [root.path])
        // The root itself contains .git and therefore is also a repository.
        XCTAssertEqual(Set(result.repositories.map(\.directoryPath)), Set([root.path, visible.path]))
    }

    func testGitRepositoriesWithoutSupportedScriptRemainVisibleWithIssue() throws {
        try repository("no-package", manifest: nil)
        try repository("no-dev", manifest: #"{"scripts":{"test":"vitest"}}"#)
        let result = RepositoryScanner.scan(roots: [root.path])
        XCTAssertEqual(result.repositories.count, 2)
        XCTAssertTrue(result.repositories.allSatisfy { $0.project == nil && $0.issue?.isEmpty == false })
    }

    func testOverlappingAndSymlinkRootsAreDeduplicatedWithoutFollowingNestedSymlinks() throws {
        let parent = try repository("parent")
        let child = try repository("parent/child")
        let externalRoot = root.appendingPathComponent("external", isDirectory: true)
        let external = try repository("external/elsewhere")
        try FileManager.default.createSymbolicLink(at: parent.appendingPathComponent("linked"), withDestinationURL: externalRoot)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)
        let result = RepositoryScanner.scan(roots: [parent.path, child.path, alias.path])
        XCTAssertEqual(Set(result.repositories.map(\.directoryPath)), Set([parent.path, child.path]))
        XCTAssertFalse(result.repositories.contains { $0.directoryPath == external.path })
    }

    func testMissingAndNonDirectoryRootsProduceWarnings() throws {
        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        let result = RepositoryScanner.scan(roots: [root.appendingPathComponent("missing").path, file.path])
        XCTAssertTrue(result.repositories.isEmpty)
        XCTAssertEqual(result.warnings.count, 2)
    }

    func testInvalidGitMarkerIsNotRecognizedAndIsReported() throws {
        let invalid = root.appendingPathComponent(".git")
        try Data("not a gitdir marker".utf8).write(to: invalid)
        let result = RepositoryScanner.scan(roots: [root.path])
        XCTAssertTrue(result.repositories.isEmpty)
        XCTAssertEqual(result.warnings.count, 1)
    }
}
