import Foundation
import XCTest
@testable import DevWatchCore

final class ProjectAutomationTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let directory: URL
        let automation: ProjectAutomation

        init(executable: String = "/bin/sh") throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DevWatchAutomationTests-\(UUID().uuidString)", isDirectory: true)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("vendor"), withIntermediateDirectories: true)
            try Data(#"{"scripts":{"dev":"vite"}}"#.utf8).write(to: directory.appendingPathComponent("package.json"))
            try Data("printf 'start\\n' >> vendor/launches\nprintf 'READY\\n'\nexec /bin/sleep 60\n".utf8)
                .write(to: directory.appendingPathComponent("run"))
            try Data("<?php // initial".utf8).write(to: directory.appendingPathComponent("source.php"))
            let project = DevProject(directoryPath: directory.path, executable: executable)
            // This box allows the persistence callback to be installed before self exists.
            let storage = SavedProjects()
            automation = ProjectAutomation(project: project, onApprovalNeeded: { project, paths in
                storage.approvalRequests.append((project, paths))
            }) { value in
                storage.values.append(value)
                return true
            }
            saved = storage
        }

        private let saved: SavedProjects
        var lastSaved: DevProject? { saved.values.last }
        var approvalRequests: [(DevProject, [String])] { saved.approvalRequests }
        var launchCount: Int {
            let text = (try? String(contentsOf: directory.appendingPathComponent("vendor/launches"), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").count
        }
        func change(_ filename: String = "source.php", contents: String = "<?php // edited") throws {
            try Data(contents.utf8).write(to: directory.appendingPathComponent(filename))
        }
        func enable() throws {
            automation.enable(approval: try AutostartApproval.capture(project: automation.project))
        }
    }

    private final class SavedProjects {
        var values: [DevProject] = []
        var approvalRequests: [(DevProject, [String])] = []
    }

    @MainActor
    private func eventually(timeout: TimeInterval = 5, _ predicate: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate()
    }

    @MainActor
    private func withFixture(executable: String = "/bin/sh", body: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture(executable: executable)
        do {
            try await body(fixture)
        } catch {
            fixture.automation.shutdown()
            _ = try? await eventually { !fixture.automation.process.isRunning }
            try? FileManager.default.removeItem(at: fixture.directory)
            throw error
        }
        fixture.automation.shutdown()
        let stopped = try await eventually { !fixture.automation.process.isRunning }
        XCTAssertTrue(stopped, "Fixture-Prozess muss nach shutdown beendet sein")
        try FileManager.default.removeItem(at: fixture.directory)
    }

    @MainActor
    func testSuccessfulBuildKeepsApprovalAndRebuildsOnNextEdit() async throws {
        try await withFixture { fixture in
            try fixture.change("package.json", contents: #"{"scripts":{"build":"vite build"}}"#)
            try fixture.change("run", contents: "printf 'start\\n' >> vendor/launches\nexit 0\n")
            var project = fixture.automation.project
            project.arguments = ["run", "build"]
            fixture.automation.configure(project)
            try fixture.enable()
            fixture.automation.startManually()
            let completed = try await eventually {
                fixture.launchCount == 1 && fixture.automation.status == L10n.text("Build completed — waiting for a file change")
            }
            XCTAssertTrue(completed)
            XCTAssertTrue(fixture.automation.project.autostartEnabled)
            try fixture.change()
            let rebuilt = try await eventually { fixture.launchCount == 2 && !fixture.automation.process.isRunning }
            XCTAssertTrue(rebuilt)
            XCTAssertTrue(fixture.automation.project.autostartEnabled)
        }
    }

    @MainActor
    func testUnapprovedActivityRequestsApprovalOnlyOnceWithoutStarting() async throws {
        try await withFixture { fixture in
            fixture.automation.beginObserving()
            try await Task.sleep(nanoseconds: 1_500_000_000)
            XCTAssertTrue(fixture.approvalRequests.isEmpty)
            try fixture.change()
            let requested = try await eventually { fixture.approvalRequests.count == 1 }
            XCTAssertTrue(requested)
            XCTAssertEqual(fixture.approvalRequests.first?.0.id, fixture.automation.project.id)
            XCTAssertTrue(fixture.approvalRequests.first?.1.contains("source.php") == true)
            XCTAssertEqual(fixture.automation.lastChange, "source.php")
            XCTAssertFalse(fixture.automation.process.isRunning)
            XCTAssertEqual(fixture.launchCount, 0)
            // Rescanning/reconfiguration must not repeatedly ask about the same project.
            fixture.automation.configure(fixture.automation.project)
            try fixture.change(contents: "<?php // later edit")
            try await Task.sleep(nanoseconds: 1_600_000_000)
            XCTAssertEqual(fixture.approvalRequests.count, 1)
            XCTAssertEqual(fixture.launchCount, 0)
        }
    }

    @MainActor
    func testPausedUnapprovedProjectDoesNotRequestApproval() async throws {
        try await withFixture { fixture in
            fixture.automation.beginObserving()
            fixture.automation.stopManually()
            fixture.automation.beginObserving()
            try fixture.change()
            try await Task.sleep(nanoseconds: 1_600_000_000)
            XCTAssertTrue(fixture.approvalRequests.isEmpty)
            XCTAssertFalse(fixture.automation.process.isRunning)
        }
    }

    @MainActor
    func testApproveAndStartLaunchesWithoutAnotherFileChange() async throws {
        try await withFixture { fixture in
            fixture.automation.beginObserving()
            let approval = try AutostartApproval.capture(project: fixture.automation.project)
            fixture.automation.approveAndStart(approval: approval)
            let started = try await eventually { fixture.automation.process.isRunning && fixture.launchCount == 1 }
            XCTAssertTrue(started)
            XCTAssertTrue(fixture.automation.project.autostartEnabled)
        }
    }

    @MainActor
    func testApproveAndStartRejectsStaleSnapshot() async throws {
        try await withFixture { fixture in
            let approval = try AutostartApproval.capture(project: fixture.automation.project)
            try fixture.change("package.json", contents: #"{"scripts":{"dev":"different-command"}}"#)
            fixture.automation.approveAndStart(approval: approval)
            XCTAssertFalse(fixture.automation.process.isRunning)
            XCTAssertFalse(fixture.automation.project.autostartEnabled)
            XCTAssertEqual(fixture.automation.project.autostartPaused, true)
            XCTAssertEqual(fixture.launchCount, 0)
        }
    }

    @MainActor
    func testEnableWaitsForChangeAndFurtherChangesDoNotStartAnotherProcess() async throws {
        try await withFixture { fixture in
            try fixture.enable()
            try await Task.sleep(nanoseconds: 1_500_000_000)
            XCTAssertTrue(fixture.automation.project.autostartEnabled)
            XCTAssertFalse(fixture.automation.process.isRunning)
            XCTAssertEqual(fixture.launchCount, 0)

            try fixture.change()
            let started = try await eventually { fixture.automation.process.isRunning && fixture.launchCount == 1 }
            XCTAssertTrue(started)
            try fixture.change(contents: "<?php // second edit")
            try await Task.sleep(nanoseconds: 1_600_000_000)
            XCTAssertTrue(fixture.automation.process.isRunning)
            XCTAssertEqual(fixture.launchCount, 1)
        }
    }

    @MainActor
    func testManualStopPersistsPauseAndPreventsRestartAfterChange() async throws {
        try await withFixture { fixture in
            try fixture.enable()
            try fixture.change()
            let started = try await eventually { fixture.launchCount == 1 }
            XCTAssertTrue(started)
            fixture.automation.stopManually()
            let stopped = try await eventually { !fixture.automation.process.isRunning }
            XCTAssertTrue(stopped)
            XCTAssertEqual(fixture.lastSaved?.autostartPaused, true)
            XCTAssertFalse(fixture.automation.project.autostartEnabled)
            try fixture.change(contents: "<?php // after manual stop")
            try await Task.sleep(nanoseconds: 1_600_000_000)
            XCTAssertFalse(fixture.automation.process.isRunning)
            XCTAssertEqual(fixture.launchCount, 1)
        }
    }

    @MainActor
    func testRegisteredNestedProjectDoesNotTriggerParentButRootChangeDoes() async throws {
        try await withFixture { fixture in
            let nested = fixture.directory.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try fixture.change("nested/source.php", contents: "<?php // initial nested source")
            fixture.automation.excludedDirectories = ["nested"]
            try fixture.enable()

            try fixture.change("nested/source.php", contents: "<?php // nested project edit")
            try await Task.sleep(nanoseconds: 1_600_000_000)
            XCTAssertFalse(fixture.automation.process.isRunning)
            XCTAssertEqual(fixture.launchCount, 0)

            try fixture.change(contents: "<?php // parent project edit")
            let started = try await eventually {
                fixture.automation.process.isRunning && fixture.launchCount == 1
            }
            XCTAssertTrue(started)
        }
    }

    @MainActor
    func testManifestChangeInvalidatesApprovalWithoutStarting() async throws {
        try await withFixture { fixture in
            try fixture.enable()
            try fixture.change("package.json", contents: #"{"scripts":{"dev":"different-command"}}"#)
            let invalidated = try await eventually { fixture.automation.project.autostartApproval == nil }
            XCTAssertTrue(invalidated)
            XCTAssertEqual(fixture.lastSaved?.autostartPaused, true)
            XCTAssertFalse(fixture.automation.process.isRunning)
            XCTAssertEqual(fixture.launchCount, 0)
        }
    }

    @MainActor
    func testFailedProcessPausesInsteadOfRestartingOnLaterChanges() async throws {
        try await withFixture(executable: "/usr/bin/false") { fixture in
            try fixture.enable()
            try fixture.change()
            let paused = try await eventually {
                fixture.automation.project.autostartPaused == true && fixture.automation.process.errorMessage != nil
            }
            XCTAssertTrue(paused)
            XCTAssertEqual(fixture.lastSaved?.autostartPaused, true)
            let logAfterFailure = fixture.automation.process.log
            try fixture.change(contents: "<?php // must not restart")
            try await Task.sleep(nanoseconds: 1_600_000_000)
            XCTAssertFalse(fixture.automation.process.isRunning)
            XCTAssertEqual(fixture.automation.process.log, logAfterFailure)
        }
    }

    func testLegacyProjectDecodesWithoutAutostartPermission() throws {
        let json = #"{"id":"0C4048AF-F600-4D61-82F0-000000000001","directoryPath":"/tmp/legacy","executable":"bun","arguments":["run","dev"]}"#
        let project = try JSONDecoder().decode(DevProject.self, from: Data(json.utf8))
        XCTAssertNil(project.autostartApproval)
        XCTAssertFalse(project.autostartEnabled)
    }
}
