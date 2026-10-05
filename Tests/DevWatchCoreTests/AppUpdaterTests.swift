import Foundation
import XCTest
@testable import DevWatchCore

@MainActor
final class AppUpdaterTests: XCTestCase {
    private let feed = URL(string: "https://api.github.com/repos/example/app/releases/latest")!

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DevWatchUpdaterTests-\(UUID().uuidString)",
                                                                      isDirectory: true)
    }

    private func release(tag: String = "v1.2.0", asset: String = "DevWatch-1.2.0.dmg",
                         digest: String? = "sha256:ABC", prerelease: Bool = false) -> Data {
        var file: [String: Any] = ["name": asset, "browser_download_url": "https://example.com/\(asset)"]
        if let digest { file["digest"] = digest }
        return try! JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "html_url": "https://example.com/release", "draft": false, "prerelease": prerelease,
            "assets": [file],
        ])
    }

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

    func testParsesOnlyInstallableReleases() {
        XCTAssertEqual(AvailableUpdate.parse(release()),
                       AvailableUpdate(version: "1.2.0", pageURL: URL(string: "https://example.com/release")!,
                                       downloadURL: URL(string: "https://example.com/DevWatch-1.2.0.dmg")!,
                                       sha256: "abc"))
        XCTAssertNil(AvailableUpdate.parse(release(digest: nil)), "Unverifiable downloads are not installed")
        XCTAssertNil(AvailableUpdate.parse(release(asset: "DevWatch-macOS.zip")))
        XCTAssertNil(AvailableUpdate.parse(release(prerelease: true)))
        // What GitHub returns for a private repository is not a release object.
        XCTAssertNil(AvailableUpdate.parse(Data(#"{"message": "Not Found"}"#.utf8)))
    }

    func testChecksReportUpToDateAndRejectDamagedDownloads() async throws {
        let work = directory()
        defer { try? FileManager.default.removeItem(at: work) }
        let installer = UpdateInstaller(bundleID: "de.example", teamID: "TEAM", workDirectory: work)

        let current = AppUpdater(currentVersion: "1.2.0", appURL: work, installer: installer, feedURL: feed,
                                 load: { _ in self.release() },
                                 download: { _ in
                                     XCTFail("No download expected")
                                     throw URLError(.cancelled)
                                 })
        await current.checkNow()
        XCTAssertEqual(current.state, .upToDate)

        let damaged = AppUpdater(currentVersion: "1.1.0", appURL: work, installer: installer, feedURL: feed,
                                 load: { _ in self.release() },
                                 download: { _ in
                                     let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                                     try Data("not the release".utf8).write(to: file)
                                     return file
                                 })
        await damaged.checkNow()
        XCTAssertEqual(damaged.state, .failed(UpdateError.checksumMismatch.localizedDescription))
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path), "Failed downloads are discarded")
        XCTAssertFalse(damaged.installPrepared())
    }

    func testOfflineCheckStaysQuiet() async {
        let updater = AppUpdater(currentVersion: "1.1.0", appURL: directory(),
                                 installer: UpdateInstaller(bundleID: "de.example", teamID: "TEAM", workDirectory: directory()),
                                 feedURL: feed, load: { _ in throw URLError(.notConnectedToInternet) })
        await updater.checkNow()
        XCTAssertEqual(updater.state, .idle)
    }

    func testMissingFeedURLNeverRequestsAnything() async {
        var requests = 0
        let updater = AppUpdater(currentVersion: "1.1.0", appURL: directory(),
                                 installer: UpdateInstaller(bundleID: "de.example", teamID: "TEAM", workDirectory: directory()),
                                 feedURL: nil, load: { _ in
                                     requests += 1
                                     return self.release(tag: "v9.9.9", asset: "DevWatch-9.9.9.dmg")
                                 })
        await updater.checkNow()
        updater.startAutomaticChecks()
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(updater.state, .idle)
    }

    func testUnsignedBuildExplainsWhyUpdatesAreUnavailable() {
        let updater = AppUpdater(currentVersion: "1.1.0", appURL: directory(), installer: nil, feedURL: feed)
        XCTAssertEqual(updater.unavailableReason, UpdateError.unsigned.localizedDescription)
    }

    func testInstallSwapsTheBundleAndCleansUp() throws {
        let base = directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let work = base.appendingPathComponent("work", isDirectory: true)
        let target = base.appendingPathComponent("Apps/DevWatch.app", isDirectory: true)
        let staged = work.appendingPathComponent("DevWatch.app", isDirectory: true)
        for (bundle, version) in [(target, "old"), (staged, "new")] {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data(version.utf8).write(to: bundle.appendingPathComponent("version"))
        }

        try UpdateInstaller(bundleID: "de.example", teamID: "TEAM", workDirectory: work).install(staged, over: target)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("version"), encoding: .utf8), "new")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path),
                       ["DevWatch.app"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }

    func testRejectsAppsWithoutTheDeveloperSignature() throws {
        let base = directory()
        defer { try? FileManager.default.removeItem(at: base) }
        let app = base.appendingPathComponent("Fake.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let installer = UpdateInstaller(bundleID: "de.example", teamID: "TEAM", workDirectory: base)
        XCTAssertThrowsError(try installer.verify(app.deletingLastPathComponent(), version: "1.0")) {
            XCTAssertEqual($0 as? UpdateError, .invalidSignature)
        }
    }
}
