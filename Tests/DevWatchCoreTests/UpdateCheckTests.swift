import Foundation
import XCTest
@testable import DevWatchCore

final class UpdateCheckTests: XCTestCase {
    private func release(_ tag: String) -> Data {
        Data("""
        {"tag_name": "\(tag)", "html_url": "https://github.com/example/app/releases/tag/\(tag)"}
        """.utf8)
    }

    private let feed = URL(string: "https://api.github.com/repos/example/app/releases/latest")!

    func testVersionComparisonIgnoresTagMarkerAndPreReleaseSuffix() {
        XCTAssertTrue(AppVersion.isNewer("v1.0.1", than: "1.0.0"))
        XCTAssertTrue(AppVersion.isNewer("1.10.0", than: "1.9.0"))
        XCTAssertTrue(AppVersion.isNewer("2.0", than: "1.9.9"))
        XCTAssertTrue(AppVersion.isNewer("1.1", than: "1.0.9"))
        XCTAssertFalse(AppVersion.isNewer("v1.0.0", than: "1.0.0"))
        XCTAssertFalse(AppVersion.isNewer("1.0.0", than: "1.0.0-beta"))
        XCTAssertFalse(AppVersion.isNewer("0.9.9", than: "1.0.0"))
        XCTAssertFalse(AppVersion.isNewer("kaputt", than: "1.0.0"))
    }

    func testVersionComponentsTreatMissingAndNonNumericPartsAsZero() {
        XCTAssertEqual(AppVersion.components("v1.2.3"), [1, 2, 3])
        XCTAssertEqual(AppVersion.components("1.0.0-beta.2"), [1, 0, 0])
        XCTAssertEqual(AppVersion.components("1.x.3"), [1, 0, 3])
        XCTAssertEqual(AppVersion.components(""), [0])
    }

    @MainActor
    func testNewerReleaseIsOffered() async {
        let checker = UpdateChecker(feedURL: feed, currentVersion: "1.0.0") { _ in self.release("v1.1.0") }
        await checker.checkOnce()
        XCTAssertEqual(checker.available?.version, "v1.1.0")
        XCTAssertEqual(checker.available?.displayVersion, "1.1.0")
        XCTAssertEqual(checker.available?.pageURL.absoluteString,
                       "https://github.com/example/app/releases/tag/v1.1.0")
    }

    @MainActor
    func testSameOrOlderReleaseIsIgnored() async {
        for tag in ["v1.0.0", "v0.9.0"] {
            let checker = UpdateChecker(feedURL: feed, currentVersion: "1.0.0") { _ in self.release(tag) }
            await checker.checkOnce()
            XCTAssertNil(checker.available, "Tag \(tag) hätte nicht angeboten werden dürfen")
        }
    }

    @MainActor
    func testFailedRequestAndUnusableAnswerStaySilent() async {
        struct Offline: Error {}
        let failing = UpdateChecker(feedURL: feed, currentVersion: "1.0.0") { _ in throw Offline() }
        await failing.checkOnce()
        XCTAssertNil(failing.available)

        // Was GitHub für ein privates Repository liefert, ist kein Release-Objekt.
        let garbage = UpdateChecker(feedURL: feed, currentVersion: "1.0.0") { _ in
            Data(#"{"message": "Not Found"}"#.utf8)
        }
        await garbage.checkOnce()
        XCTAssertNil(garbage.available)
    }

    @MainActor
    func testMissingFeedURLNeverRequestsAnything() async {
        var requests = 0
        let checker = UpdateChecker(feedURL: nil, currentVersion: "1.0.0") { _ in
            requests += 1
            return self.release("v9.9.9")
        }
        await checker.checkOnce()
        checker.start()
        XCTAssertEqual(requests, 0)
        XCTAssertNil(checker.available)
    }
}
