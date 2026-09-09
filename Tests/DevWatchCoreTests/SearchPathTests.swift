import Foundation
import XCTest
@testable import DevWatchCore

final class SearchPathTests: XCTestCase {
    func testSplitIgnoresEmptySegments() {
        XCTAssertEqual(SearchPath.split("/usr/bin:/bin"), ["/usr/bin", "/bin"])
        XCTAssertEqual(SearchPath.split("::/bin:"), ["/bin"])
        XCTAssertEqual(SearchPath.split(nil), [])
        XCTAssertEqual(SearchPath.split(""), [])
    }

    func testCombineKeepsFirstOccurrenceAndDropsRelativeEntries() {
        let combined = SearchPath.combine(
            ["/opt/homebrew/bin", "relative", "."],
            ["/usr/bin", "/opt/homebrew/bin/"],
            ["/usr/bin", "/usr/local/bin"]
        )
        XCTAssertEqual(combined, ["/opt/homebrew/bin", "/usr/bin", "/usr/local/bin"])
    }

    func testCombinePreservesRootAndGroupOrder() {
        XCTAssertEqual(SearchPath.combine(["/"], ["/bin"]), ["/", "/bin"])
        // The earlier group decides which of two identical tools wins.
        XCTAssertEqual(SearchPath.combine(["/nvm/bin"], ["/usr/bin"]), ["/nvm/bin", "/usr/bin"])
        XCTAssertEqual(SearchPath.combine(["/usr/bin"], ["/nvm/bin"]), ["/usr/bin", "/nvm/bin"])
    }

    func testLoginShellPathReadsOnceAndCachesTheResult() {
        var reads = 0
        let path = LoginShellPath { reads += 1; return ["/nvm/bin"] }
        XCTAssertEqual(path.directories(), ["/nvm/bin"])
        XCTAssertEqual(path.directories(), ["/nvm/bin"])
        XCTAssertEqual(reads, 1)
    }

    func testUnreadableLoginShellIsCachedAsEmptyWithoutRetrying() {
        var reads = 0
        let path = LoginShellPath { reads += 1; return [] }
        XCTAssertEqual(path.directories(), [])
        XCTAssertEqual(path.directories(), [])
        XCTAssertEqual(reads, 1)
    }

    func testRealLoginShellReturnsOnlyAbsoluteDirectories() {
        // The shell configuration is the developer's own; assert the shape only.
        for directory in LoginShellPath.readFromLoginShell() {
            XCTAssertTrue(directory.hasPrefix("/"), "Kein absoluter Pfad: \(directory)")
        }
    }
}
