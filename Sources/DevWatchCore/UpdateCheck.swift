import Combine
import Foundation

public struct ReleaseInfo: Equatable, Sendable {
    public let version: String
    public let pageURL: URL

    public init(version: String, pageURL: URL) {
        self.version = version
        self.pageURL = pageURL
    }

    /// Tags are usually written as "v1.2.0"; the marker is noise in the interface.
    public var displayVersion: String {
        version.first == "v" || version.first == "V" ? String(version.dropFirst()) : version
    }
}

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

/// Asks a GitHub releases endpoint whether a newer version exists. A failure is
/// never surfaced: an offline machine, a rate limit or a repository that is still
/// private must not produce an error the user cannot act on.
@MainActor
public final class UpdateChecker: ObservableObject {
    @Published public private(set) var available: ReleaseInfo?

    private struct Release: Decodable {
        let tag_name: String
        let html_url: URL
    }

    private let feedURL: URL?
    private let currentVersion: String
    private let load: (URL) async throws -> Data
    private var task: Task<Void, Never>?

    public init(feedURL: URL?,
                currentVersion: String,
                load: @escaping (URL) async throws -> Data = UpdateChecker.download) {
        self.feedURL = feedURL
        self.currentVersion = currentVersion
        self.load = load
    }

    /// Checks once now and then once per interval for as long as the app runs.
    public func start(interval: TimeInterval = 24 * 60 * 60) {
        guard task == nil, feedURL != nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkOnce()
                do { try await Task.sleep(for: .seconds(interval), clock: .continuous) }
                catch { return }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func checkOnce() async {
        guard let feedURL else { return }
        guard let data = try? await load(feedURL),
              let release = try? JSONDecoder().decode(Release.self, from: data),
              AppVersion.isNewer(release.tag_name, than: currentVersion) else { return }
        available = ReleaseInfo(version: release.tag_name, pageURL: release.html_url)
    }

    public static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            // A private repository answers 404 here; stay quiet until it is public.
            throw URLError(.badServerResponse)
        }
        return data
    }
}
