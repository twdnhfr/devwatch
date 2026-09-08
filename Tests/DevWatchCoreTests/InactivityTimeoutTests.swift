import Foundation
import XCTest
@testable import DevWatchCore

final class InactivityTimeoutTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let directory: URL
        let automation: ProjectAutomation
        let saved: SavedProjects

        init(timeout: TimeInterval = 3) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("DevWatchInactivityTests-\(UUID().uuidString)", isDirectory: true)
                .resolvingSymlinksInPath()
            for name in ["vendor", "nested"] {
                try FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            try Data(#"{"scripts":{"dev":"vite"}}"#.utf8).write(to: directory.appendingPathComponent("package.json"))
            try Data("printf 'start\\n' >> vendor/launches\nexec /bin/sleep 60\n".utf8)
                .write(to: directory.appendingPathComponent("run"))
            try Data("initial".utf8).write(to: directory.appendingPathComponent("source.php"))
            let storage = SavedProjects()
            saved = storage
            automation = ProjectAutomation(
                project: DevProject(directoryPath: directory.path, executable: "/bin/sh"),
                inactivityTimeout: timeout
            ) { project in
                storage.values.append(project)
                return true
            }
            automation.excludedDirectories = ["nested"]
        }

        func change(_ file: String = "source.php") throws {
            try Data(UUID().uuidString.utf8).write(to: directory.appendingPathComponent(file))
        }

        func approveAndStart() throws {
            automation.approveAndStart(approval: try AutostartApproval.capture(project: automation.project))
        }

        var launchCount: Int {
            let text = (try? String(contentsOf: directory.appendingPathComponent("vendor/launches"), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").count
        }
    }

    private final class SavedProjects {
        var values: [DevProject] = []
    }

    @MainActor
    private func eventually(timeout: TimeInterval = 5, _ predicate: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try await Task.sleep(for: .milliseconds(40))
        }
        return predicate()
    }

    @MainActor
    private func withFixture(timeout: TimeInterval = 3, body: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture(timeout: timeout)
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
        XCTAssertTrue(stopped, "Testprozess muss nach shutdown beendet sein")
        try FileManager.default.removeItem(at: fixture.directory)
    }

    @MainActor
    func testExpiryKeepsApprovalAndNextRelevantEditRestarts() async throws {
        try await withFixture(timeout: 2.5) { fixture in
            try fixture.approveAndStart()
            let launched = try await eventually { fixture.launchCount == 1 }
            XCTAssertTrue(launched)
            XCTAssertNotNil(fixture.automation.idleDeadline)
            let approval = fixture.automation.project.autostartApproval

            let expired = try await eventually { !fixture.automation.process.isRunning }
            XCTAssertTrue(expired)
            XCTAssertNil(fixture.automation.idleDeadline)
            XCTAssertEqual(fixture.automation.project.autostartApproval, approval)
            XCTAssertTrue(fixture.automation.project.autostartEnabled)
            XCTAssertFalse(fixture.saved.values.contains { $0.autostartPaused == true })

            try fixture.change()
            let restarted = try await eventually { fixture.launchCount == 2 && fixture.automation.process.isRunning }
            XCTAssertTrue(restarted)
            XCTAssertNotNil(fixture.automation.idleDeadline)
        }
    }

    @MainActor
    func testOnlyRelevantActivityExtendsDeadline() async throws {
        try await withFixture(timeout: 4) { fixture in
            try fixture.approveAndStart()
            let original = try XCTUnwrap(fixture.automation.idleDeadline)
            try fixture.change("vendor/generated.php")
            try fixture.change("nested/source.php")
            try await Task.sleep(for: .milliseconds(1500))
            XCTAssertEqual(fixture.automation.idleDeadline, original)

            try fixture.change()
            let refreshed = try await eventually(timeout: 2) {
                (fixture.automation.idleDeadline ?? .distantPast) > original
            }
            XCTAssertTrue(refreshed)
            XCTAssertTrue(fixture.automation.process.isRunning)
            XCTAssertEqual(fixture.launchCount, 1)
        }
    }

    @MainActor
    func testManualStopCancelsDeadlineAndPersistsPause() async throws {
        try await withFixture(timeout: 2.5) { fixture in
            try fixture.approveAndStart()
            let launched = try await eventually { fixture.launchCount == 1 }
            XCTAssertTrue(launched)
            fixture.automation.stopManually()
            let stopped = try await eventually { !fixture.automation.process.isRunning }
            XCTAssertTrue(stopped)
            XCTAssertNil(fixture.automation.idleDeadline)
            XCTAssertEqual(fixture.saved.values.last?.autostartPaused, true)
            try fixture.change()
            try await Task.sleep(for: .milliseconds(1600))
            XCTAssertFalse(fixture.automation.process.isRunning)
            XCTAssertEqual(fixture.launchCount, 1)
        }
    }

    @MainActor
    func testShutdownCancelsDeadlineWithoutLaterStateChanges() async throws {
        try await withFixture(timeout: 2.5) { fixture in
            try fixture.approveAndStart()
            let launched = try await eventually { fixture.launchCount == 1 }
            XCTAssertTrue(launched)
            fixture.automation.shutdown()
            let stopped = try await eventually { !fixture.automation.process.isRunning }
            XCTAssertTrue(stopped)
            XCTAssertNil(fixture.automation.idleDeadline)
            let savedCount = fixture.saved.values.count
            let project = fixture.automation.project
            try fixture.change()
            try await Task.sleep(for: .milliseconds(2700))
            XCTAssertNil(fixture.automation.idleDeadline)
            XCTAssertEqual(fixture.saved.values.count, savedCount)
            XCTAssertEqual(fixture.automation.project, project)
            XCTAssertEqual(fixture.launchCount, 1)
        }
    }

    @MainActor
    func testManuallyStartedPausedProjectTracksActivityButCannotAutorestart() async throws {
        try await withFixture(timeout: 2.5) { fixture in
            fixture.automation.stopManually()
            fixture.automation.startManually()
            let launched = try await eventually { fixture.launchCount == 1 }
            XCTAssertTrue(launched)
            let initialDeadline = try XCTUnwrap(fixture.automation.idleDeadline)
            try fixture.change()
            let refreshed = try await eventually(timeout: 2) {
                (fixture.automation.idleDeadline ?? .distantPast) > initialDeadline
            }
            XCTAssertTrue(refreshed)
            XCTAssertEqual(fixture.automation.project.autostartPaused, true)

            let expired = try await eventually { !fixture.automation.process.isRunning }
            XCTAssertTrue(expired)
            try fixture.change()
            try await Task.sleep(for: .milliseconds(1500))
            XCTAssertFalse(fixture.automation.process.isRunning)
            XCTAssertEqual(fixture.launchCount, 1)
            XCTAssertEqual(fixture.automation.project.autostartPaused, true)
        }
    }
}
