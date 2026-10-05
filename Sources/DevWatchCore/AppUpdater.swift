import CryptoKit
import Foundation
import Security

public enum AppVersion {
    /// Reads a dot-separated version, ignoring a leading "v" and any pre-release
    /// suffix. Non-numeric components count as zero rather than failing.
    public static func components(_ version: String) -> [Int] {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        text = String(text.prefix { $0 != "-" && $0 != "+" })
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.isEmpty ? [0] : parts.map { Int($0) ?? 0 }
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = components(candidate), rhs = components(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}

public struct AvailableUpdate: Equatable, Sendable {
    public let version: String
    public let pageURL: URL
    public let downloadURL: URL
    public let sha256: String

    public init(version: String, pageURL: URL, downloadURL: URL, sha256: String) {
        self.version = version
        self.pageURL = pageURL
        self.downloadURL = downloadURL
        self.sha256 = sha256
    }

    /// Reads GitHub's latest-release response. A release without the DMG or its
    /// digest is not installable and is ignored.
    public static func parse(_ data: Data) -> AvailableUpdate? {
        struct Release: Decodable {
            struct Asset: Decodable {
                let name: String
                let browserDownloadUrl: URL
                let digest: String?
            }
            let tagName: String
            let htmlUrl: URL
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let release = try? decoder.decode(Release.self, from: data),
              release.draft != true, release.prerelease != true else { return nil }
        var version = release.tagName
        if version.first == "v" || version.first == "V" { version.removeFirst() }
        guard let asset = release.assets.first(where: { $0.name == "DevWatch-\(version).dmg" }),
              let digest = asset.digest, digest.hasPrefix("sha256:") else { return nil }
        return AvailableUpdate(version: version, pageURL: release.htmlUrl, downloadURL: asset.browserDownloadUrl,
                               sha256: String(digest.dropFirst("sha256:".count)).lowercased())
    }
}

public enum UpdateError: LocalizedError, Equatable {
    case unsigned
    case notWritable
    case checksumMismatch
    case diskImageFailed
    case invalidSignature
    case unexpectedBundle

    public var errorDescription: String? {
        switch self {
        case .unsigned: return L10n.text("Automatic updates are available only in signed releases.")
        case .notWritable:
            return L10n.text("DevWatch cannot replace itself here. Move it to Applications or install the update manually.")
        case .checksumMismatch: return L10n.text("The downloaded update is damaged.")
        case .diskImageFailed: return L10n.text("The update's disk image could not be opened.")
        case .invalidSignature: return L10n.text("The update is not signed by the DevWatch developer.")
        case .unexpectedBundle: return L10n.text("The update does not contain the expected DevWatch version.")
        }
    }
}

/// Downloads, verifies, and installs a release. Every step works on a private
/// directory; the running app is replaced only by `install`.
public struct UpdateInstaller: Sendable {
    public let bundleID: String
    public let teamID: String
    public let workDirectory: URL

    public init(bundleID: String, teamID: String, workDirectory: URL) {
        self.bundleID = bundleID
        self.teamID = teamID
        self.workDirectory = workDirectory
    }

    /// The Developer ID team of the running app, or nil for ad hoc builds.
    public static func currentTeamID() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    public static func sha256(of file: URL) throws -> String {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the verified app, copied out of the disk image.
    public func stage(_ update: AvailableUpdate, download: (URL) async throws -> URL) async throws -> URL {
        try? FileManager.default.removeItem(at: workDirectory)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let image = workDirectory.appendingPathComponent("update.dmg")
        try FileManager.default.moveItem(at: try await download(update.downloadURL), to: image)
        guard try Self.sha256(of: image) == update.sha256 else { throw UpdateError.checksumMismatch }

        let mountPoint = workDirectory.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        guard Self.run("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-readonly", "-noautoopen",
                                            "-mountpoint", mountPoint.path, "-quiet"]) else {
            throw UpdateError.diskImageFailed
        }
        let staged = workDirectory.appendingPathComponent("DevWatch.app", isDirectory: true)
        let copied = Self.run("/usr/bin/ditto", [mountPoint.appendingPathComponent("DevWatch.app").path, staged.path])
        if !Self.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"]) {
            _ = Self.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force", "-quiet"])
        }
        try? FileManager.default.removeItem(at: image)
        guard copied else { throw UpdateError.diskImageFailed }
        try verify(staged, version: update.version)
        return staged
    }

    public func verify(_ app: URL, version: String) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let text = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw UpdateError.invalidSignature
        }
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == bundleID,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else {
            throw UpdateError.unexpectedBundle
        }
    }

    /// Swaps the bundle on disk. A running app keeps working from the files it already opened.
    public func install(_ staged: URL, over target: URL) throws {
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path),
              FileManager.default.isWritableFile(atPath: target.path) else { throw UpdateError.notWritable }
        // Copy next to the target first: the swap must not cross volumes.
        let sibling = parent.appendingPathComponent(".DevWatch-update-\(UUID().uuidString).app", isDirectory: true)
        guard Self.run("/usr/bin/ditto", [staged.path, sibling.path]) else { throw UpdateError.notWritable }
        do {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: sibling)
        } catch {
            try? FileManager.default.removeItem(at: sibling)
            throw UpdateError.notWritable
        }
        try? FileManager.default.removeItem(at: workDirectory)
    }

    public func discard() { try? FileManager.default.removeItem(at: workDirectory) }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

/// Checks a GitHub releases endpoint once a day, prepares a newer release in the
/// background, and installs it when the user asks or, if enabled, when DevWatch quits.
/// A failed check is never surfaced: an offline machine or a rate limit must not
/// produce an error the user cannot act on.
@MainActor
public final class AppUpdater: ObservableObject {
    public enum State: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(String)
        case ready(String)
        case installed
        case failed(String)
    }

    @Published public private(set) var state: State = .idle
    public let currentVersion: String
    /// Nil when updates cannot work, with the reason in `unavailableReason`.
    public let installer: UpdateInstaller?
    public let unavailableReason: String?

    private let feedURL: URL?
    private let appURL: URL
    private let load: (URL) async throws -> Data
    private let download: (URL) async throws -> URL
    private var staged: URL?
    private var loop: Task<Void, Never>?
    private var check: Task<Void, Never>?

    public init(currentVersion: String, appURL: URL, installer: UpdateInstaller?, unavailableReason: String? = nil,
                feedURL: URL?,
                load: @escaping (URL) async throws -> Data = AppUpdater.load,
                download: @escaping (URL) async throws -> URL = AppUpdater.download) {
        self.currentVersion = currentVersion
        self.appURL = appURL
        self.installer = installer
        self.unavailableReason = installer == nil ? unavailableReason ?? UpdateError.unsigned.localizedDescription : nil
        self.feedURL = feedURL
        self.load = load
        self.download = download
    }

    /// The first check waits briefly so that launching stays quick.
    public func startAutomaticChecks(interval: TimeInterval = 24 * 60 * 60) {
        guard loop == nil, installer != nil, feedURL != nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled {
                await self?.checkNow()
                do { try await Task.sleep(for: .seconds(interval), clock: .continuous) }
                catch { return }
            }
        }
    }

    public func stopAutomaticChecks() {
        loop?.cancel()
        loop = nil
    }

    public func checkNow() async {
        if let check { return await check.value }
        let task = Task { await performCheck() }
        check = task
        await task.value
        check = nil
    }

    private func performCheck() async {
        guard let installer, let feedURL else { return }
        switch state {
        case .ready, .installed, .downloading: return
        default: break
        }
        state = .checking
        // Offline or rate-limited checks stay quiet; the next one may succeed.
        guard let data = try? await load(feedURL), let update = AvailableUpdate.parse(data) else {
            state = .idle
            return
        }
        guard AppVersion.isNewer(update.version, than: currentVersion) else {
            state = .upToDate
            return
        }
        state = .downloading(update.version)
        let download = download
        do {
            staged = try await Task.detached(priority: .utility) {
                try await installer.stage(update, download: download)
            }.value
            state = .ready(update.version)
        } catch {
            installer.discard()
            state = .failed(error.localizedDescription)
        }
    }

    /// Installs the prepared update; returns false and records why when it fails.
    @discardableResult
    public func installPrepared() -> Bool {
        guard let installer, let staged, case .ready = state else { return false }
        do {
            try installer.install(staged, over: appURL)
            self.staged = nil
            state = .installed
            return true
        } catch {
            state = .failed(error.localizedDescription)
            return false
        }
    }

    /// Opens the new version once this process has exited.
    public func relaunchAfterExit() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"", "sh",
                             String(ProcessInfo.processInfo.processIdentifier), appURL.path]
        try? process.run()
    }

    public nonisolated static func load(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        // A private repository answers 404 here; stay quiet until it is public.
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    public nonisolated static func download(_ url: URL) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return file
    }
}
