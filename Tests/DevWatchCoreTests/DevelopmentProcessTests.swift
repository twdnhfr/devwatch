import Combine
import Darwin
import Foundation
import XCTest
@testable import DevWatchCore

final class DevelopmentProcessTests: XCTestCase {
    @MainActor
    func testOutputStreamsBeforeExitAndPreservesSplitUTF8() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("stream.sh")
        // Emit the first byte of ü separately, forcing a UTF-8 sequence across reads.
        try "printf 'ready: \\303'\nsleep 0.2\nprintf '\\274ber\\n'\nsleep 60\n"
            .write(to: script, atomically: true, encoding: .utf8)
        let process = DevelopmentProcess()
        defer { process.stop() }
        process.start(directory: directory, executable: "/bin/sh", arguments: [script.path])
        try await eventually { process.log.contains("ready: über") }
        XCTAssertTrue(process.isRunning, "Output must arrive while the server is still running")
        XCTAssertFalse(process.log.contains("�"))
        process.stop()
        try await eventually { !process.isRunning }
    }

    @MainActor
    func testArgumentsArePassedLiterallyAndOutputIsCaptured() async throws {
        let process = DevelopmentProcess()
        let literal = "hello; $(touch never-created) spaces"
        process.start(directory: FileManager.default.temporaryDirectory,
                      executable: "/usr/bin/printf", arguments: ["%s", literal])
        // The startup line also echoes arguments; require the separate stdout occurrence.
        try await eventually { !process.isRunning && process.log.components(separatedBy: literal).count == 3 }
        XCTAssertNil(process.errorMessage)
        XCTAssertEqual(process.state, .succeeded)
        XCTAssertEqual(process.exitCode, 0)
    }

    @MainActor
    func testMissingExecutableDoesNotStart() {
        let process = DevelopmentProcess()
        process.start(directory: FileManager.default.temporaryDirectory,
                      executable: "/no-such-devwatch-executable", arguments: [])
        XCTAssertFalse(process.isRunning)
        XCTAssertNotNil(process.errorMessage)
        XCTAssertEqual(process.state, .failed)
        XCTAssertNil(process.exitCode)
    }

    @MainActor
    func testNonzeroExitIsReported() async throws {
        let process = DevelopmentProcess()
        process.start(directory: FileManager.default.temporaryDirectory,
                      executable: "/usr/bin/false", arguments: [])
        try await eventually { !process.isRunning }
        XCTAssertNotNil(process.errorMessage)
        XCTAssertEqual(process.state, .failed)
        XCTAssertEqual(process.exitCode, 1)
    }

    @MainActor
    func testStopTerminatesOwnedChildGroupAndSupportsRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("child.pid")
        let script = directory.appendingPathComponent("run.sh")
        // Both processes ignore TERM to exercise bounded escalation, without shell interpolation.
        try "trap '' TERM\nsleep 60 &\necho $! > child.pid\nwait\n".write(to: script, atomically: true, encoding: .utf8)
        let process = DevelopmentProcess()
        defer { process.stop() }
        process.start(directory: directory, executable: "/bin/sh", arguments: [script.path])
        try await eventually { FileManager.default.fileExists(atPath: pidFile.path) }
        let pidText = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try XCTUnwrap(Int32(pidText))
        XCTAssertEqual(kill(childPID, 0), 0)
        process.stop()
        try await eventually { !process.isRunning }
        try await eventually { kill(childPID, 0) == -1 && errno == ESRCH }
        XCTAssertNil(process.errorMessage)
        XCTAssertEqual(process.state, .stopped)
        process.start(directory: directory, executable: "/usr/bin/printf", arguments: ["restarted"])
        try await eventually { !process.isRunning && process.log.components(separatedBy: "restarted").count == 3 }
        XCTAssertNil(process.errorMessage)
    }

    @MainActor
    func testResultIsPublishedBeforeRunningBecomesFalseAndResetOnRestart() async throws {
        let process = DevelopmentProcess()
        XCTAssertEqual(process.state, .idle)
        XCTAssertNil(process.exitCode)
        var completedStates: [DevelopmentProcess.State] = []
        var completedCodes: [Int32?] = []
        let subscription = process.$isRunning.dropFirst().sink { running in
            if !running {
                completedStates.append(process.state)
                completedCodes.append(process.exitCode)
            }
        }
        defer { subscription.cancel(); process.stop() }
        process.start(directory: FileManager.default.temporaryDirectory,
                      executable: "/usr/bin/false", arguments: [])
        try await eventually { !process.isRunning }
        XCTAssertEqual(completedStates, [.failed])
        XCTAssertEqual(completedCodes, [1])

        process.start(directory: FileManager.default.temporaryDirectory,
                      executable: "/bin/sleep", arguments: ["60"])
        XCTAssertEqual(process.state, .running)
        XCTAssertNil(process.exitCode)
        XCTAssertNil(process.errorMessage)
        process.stop()
        try await eventually { !process.isRunning }
        XCTAssertEqual(completedStates, [.failed, .stopped])
        XCTAssertNil(process.errorMessage)
    }

    @MainActor
    func testLaunchFailureHasNoExitCode() {
        let process = DevelopmentProcess()
        let absentDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        process.start(directory: absentDirectory, executable: "/usr/bin/true", arguments: [])
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.state, .failed)
        XCTAssertNil(process.exitCode)
        XCTAssertNotNil(process.errorMessage)
    }

    @MainActor
    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "Condition did not become true within five seconds")
    }
}
