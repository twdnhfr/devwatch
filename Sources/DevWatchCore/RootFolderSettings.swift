import Foundation

/// Root folders and explicitly dismissed discoveries; neither grants execution approval.
public struct RootFolderSettings: Codable, Equatable, Sendable {
    public var paths: [String]
    public var hiddenRepositoryPaths: [String]

    public init(paths: [String] = [], hiddenRepositoryPaths: [String] = []) {
        self.paths = paths
        self.hiddenRepositoryPaths = hiddenRepositoryPaths
    }
}

public final class RootFolderSettingsStorage {
    private let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() throws -> RootFolderSettings {
        do {
            return try JSONDecoder().decode(RootFolderSettings.self, from: Data(contentsOf: fileURL))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return RootFolderSettings()
        }
    }

    public func save(_ settings: RootFolderSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
