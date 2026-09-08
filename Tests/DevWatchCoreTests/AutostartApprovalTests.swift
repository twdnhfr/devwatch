import Foundation
import XCTest
@testable import DevWatchCore

final class AutostartApprovalTests: XCTestCase {
    private var directory: URL!
    private var project: DevProject!
    private let manifest = #"{"scripts":{"dev":"vite","predev":"echo before","postdev":"echo after"}}"#

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevWatchApprovalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        project = DevProject(directoryPath: directory.path)
        try writeManifest(manifest)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func writeManifest(_ text: String) throws {
        try Data(text.utf8).write(to: directory.appendingPathComponent("package.json"))
    }

    func testUnchangedApprovalMatchesAndSurvivesCodableRoundTrip() throws {
        let approval = try AutostartApproval.capture(project: project)
        XCTAssertEqual(approval.fingerprint.count, 64)
        XCTAssertTrue(approval.matches(project: project))
        let restored = try JSONDecoder().decode(AutostartApproval.self, from: JSONEncoder().encode(approval))
        XCTAssertEqual(restored, approval)
        XCTAssertTrue(restored.matches(project: project))
    }

    func testDefaultAutostartApprovesValidProjectButPreservesPause() throws {
        let enabled = project.applyingDefaultAutostart()
        XCTAssertTrue(enabled.autostartEnabled)
        XCTAssertTrue(try XCTUnwrap(enabled.autostartApproval).matches(project: enabled))
        var paused = project!
        paused.autostartPaused = true
        XCTAssertEqual(paused.applyingDefaultAutostart(), paused)
    }

    func testDefaultAutostartDoesNotReplaceStaleApprovalOrApproveInvalidManifest() throws {
        let enabled = project.applyingDefaultAutostart()
        try writeManifest(manifest + "\n")
        XCTAssertEqual(enabled.applyingDefaultAutostart(), enabled)
        XCTAssertFalse(try XCTUnwrap(enabled.autostartApproval).matches(project: enabled))
        try writeManifest("{}")
        XCTAssertFalse(project.applyingDefaultAutostart().autostartEnabled)
    }

    func testEveryRawManifestChangeInvalidatesApproval() throws {
        let approval = try AutostartApproval.capture(project: project)
        try writeManifest(manifest + "\n")
        XCTAssertFalse(approval.matches(project: project))
        try writeManifest(#"{"scripts":{"dev":"vite --host"}}"#)
        XCTAssertFalse(approval.matches(project: project))
    }

    func testCommandAndArgumentChangesInvalidateApproval() throws {
        let approval = try AutostartApproval.capture(project: project)
        var changed = project!
        changed.executable = "npm"
        XCTAssertFalse(approval.matches(project: changed))
        changed = project
        changed.arguments = ["run", "build"]
        XCTAssertFalse(approval.matches(project: changed))
        XCTAssertThrowsError(try AutostartApproval.capture(project: changed)) { error in
            XCTAssertEqual(error as? AutostartApproval.ApprovalError, .missingDevScript)
        }
    }

    func testBuildApprovalIncludesBuildLifecycleAndCannotApproveDev() throws {
        try writeManifest(#"{"scripts":{"prebuild":"echo before","build":"vite build","postbuild":"echo after","dev":"vite"}}"#)
        project.arguments = ["run", "build"]
        let approval = try AutostartApproval.capture(project: project)
        XCTAssertEqual(try AutostartApproval.scriptDescription(project: project), "prebuild: echo before\nbuild: vite build\npostbuild: echo after")
        XCTAssertTrue(approval.matches(project: project))
        project.arguments = ["run", "dev"]
        XCTAssertFalse(approval.matches(project: project))
    }

    func testDifferentDirectoryInvalidatesApprovalEvenWithIdenticalManifest() throws {
        let approval = try AutostartApproval.capture(project: project)
        let otherDirectory = directory.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: otherDirectory.appendingPathComponent("package.json"))
        var changed = project!
        changed.directoryPath = otherDirectory.path
        XCTAssertFalse(approval.matches(project: changed))
    }

    func testCanonicalPathRecognizesSameDirectory() throws {
        let approval = try AutostartApproval.capture(project: project)
        var equivalent = project!
        equivalent.directoryPath = directory.appendingPathComponent(".").path
        XCTAssertTrue(approval.matches(project: equivalent))
    }

    func testScriptDescriptionIncludesLifecycleScriptsInOrder() throws {
        XCTAssertEqual(
            try AutostartApproval.scriptDescription(project: project),
            "predev: echo before\ndev: vite\npostdev: echo after"
        )
    }

    func testInvalidOrMissingManifestCannotMatchApproval() throws {
        let approval = try AutostartApproval.capture(project: project)
        for invalid in ["not json", #"{"scripts":{"dev":42}}"#, #"{"scripts":{"dev":" "}}"#, "{}"] {
            try writeManifest(invalid)
            XCTAssertFalse(approval.matches(project: project))
            XCTAssertThrowsError(try AutostartApproval.scriptDescription(project: project))
        }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("package.json"))
        XCTAssertFalse(approval.matches(project: project))
    }
}
