import Foundation
import XCTest
@testable import DevWatchCore

final class ExternalProcessTests: XCTestCase {
    func testPackageManagerAndScriptToolInvocationsMatch() {
        XCTAssertTrue(ExternalProcessDetector.matches(arguments: ["/Users/me/.bun/bin/bun", "run", "dev"], scriptName: "dev", script: "vite"))
        XCTAssertTrue(ExternalProcessDetector.matches(arguments: ["bun", "dev"], scriptName: "dev", script: nil))
        XCTAssertTrue(ExternalProcessDetector.matches(arguments: ["node", "/usr/lib/node_modules/npm/bin/npm-cli.js", "run", "dev"], scriptName: "dev", script: nil))
        XCTAssertTrue(ExternalProcessDetector.matches(arguments: ["node", "/p/node_modules/.bin/vite"], scriptName: "dev", script: "vite"))
        XCTAssertTrue(ExternalProcessDetector.matches(arguments: ["node", "/p/node_modules/.bin/next", "dev", "--webpack"],
                                                      scriptName: "dev", script: "next dev --webpack"))
        XCTAssertTrue(ExternalProcessDetector.matches(arguments: ["node", "/p/node_modules/.bin/webpack", "--watch"], scriptName: "dev",
                                                      script: "cross-env NODE_ENV=development webpack --watch --progress"))
        // npm rewrites argv[0] with its process title; the remaining slots are empty.
        XCTAssertTrue(ExternalProcessDetector.matches(arguments: ["npm run dev --port 5273", "", ""], scriptName: "dev", script: nil))
        XCTAssertTrue(ExternalProcessDetector.matches(arguments: ["node", "/p/node_modules/.bin/vite", "dev", "--host"], scriptName: "dev",
                                                      script: "npm run pyodide:fetch && vite dev --host"))
    }

    func testUnrelatedProcessesInTheProjectFolderDoNotMatch() {
        XCTAssertFalse(ExternalProcessDetector.matches(arguments: ["bun", "run", "build"], scriptName: "dev", script: "vite"))
        XCTAssertFalse(ExternalProcessDetector.matches(arguments: ["bun", "src/index.ts"], scriptName: "dev", script: "vite"))
        XCTAssertFalse(ExternalProcessDetector.matches(arguments: ["/bin/zsh"], scriptName: "dev", script: "vite"))
        XCTAssertFalse(ExternalProcessDetector.matches(arguments: ["node", "/p/node_modules/.bin/next", "build"],
                                                       scriptName: "dev", script: "next dev"))
        // A script that starts with a package manager must not turn every bun process into a match.
        XCTAssertFalse(ExternalProcessDetector.matches(arguments: ["bun", "src/index.ts"], scriptName: "dev",
                                                       script: "bun run build && ./scripts/dev.sh"))
    }

    func testFindsRunningProcessInProjectFolderButSkipsOwnChildren() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevWatchExternalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"scripts":{"dev":"vite"}}"#.utf8).write(to: directory.appendingPathComponent("package.json"))
        // Runs as `/bin/sh ./bun run dev`, which looks like `bun run dev` to the detector.
        // It blocks on stdin without a child process, so terminate() ends it completely.
        try Data("read line\n".utf8).write(to: directory.appendingPathComponent("bun"))
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/bin/sh")
        server.arguments = ["./bun", "run", "dev"]
        server.currentDirectoryURL = directory
        server.standardInput = Pipe()
        let started = Date()
        try server.run()
        defer { server.terminate() }
        let project = DevProject(directoryPath: directory.path)

        var found: ExternalProcess?
        while found == nil, Date().timeIntervalSince(started) < 3 {
            found = ExternalProcessDetector.find(project: project, owner: nil)
        }
        XCTAssertEqual(found?.pid, server.processIdentifier)
        XCTAssertNil(ExternalProcessDetector.find(project: project), "Processes started by this process are its own")
    }
}
