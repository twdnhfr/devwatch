import Foundation

public struct DiscoveredRepository: Identifiable, Sendable {
    public let directoryPath: String
    public var id: String { directoryPath }
    public var name: String { URL(fileURLWithPath: directoryPath).lastPathComponent }
    public let project: DevProject?
    public let issue: String?

    public init(directoryPath: String, project: DevProject?, issue: String?) {
        self.directoryPath = directoryPath
        self.project = project
        self.issue = issue
    }
}

public struct RepositoryScanResult: Sendable {
    public let repositories: [DiscoveredRepository]
    public let warnings: [String]
}

public enum RepositoryScanner {
    private static let excludedDirectories: Set<String> = [
        ".git", "node_modules", "vendor", "storage", "dist", ".build", "build",
        ".swiftpm", ".cache", "cache", "caches", "Caches", ".next", ".nuxt",
        ".output", ".turbo", ".parcel-cache", "coverage", "DerivedData"
    ]

    /// Inspects directory entries without invoking Git or following discovered symlinks.
    public static func scan(roots: [String]) -> RepositoryScanResult {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        var visited = Set<String>()
        var repositories: [DiscoveredRepository] = []
        var warnings = Set<String>()
        var pending: [URL] = []

        for root in roots {
            guard !root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                warnings.insert("Ein Suchordner hat einen leeren Pfad und wurde übersprungen.")
                continue
            }
            let url = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                warnings.insert("Suchordner fehlt oder ist kein Verzeichnis: \(url.path)")
                continue
            }
            pending.append(url)
        }

        while let directory = pending.popLast() {
            if Task.isCancelled {
                warnings.insert("Die Repository-Suche wurde abgebrochen; die Ergebnisse sind unvollständig.")
                break
            }
            guard visited.insert(directory.path).inserted else { continue }
            let entries: [URL]
            do {
                entries = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
            } catch {
                warnings.insert("Ordner konnte nicht gelesen werden: \(directory.path). \(error.localizedDescription)")
                continue
            }

            var isRepository = false
            for entry in entries {
                if Task.isCancelled { break }
                do {
                    let values = try entry.resourceValues(forKeys: keys)
                    guard values.isSymbolicLink != true else { continue }
                    let name = entry.lastPathComponent
                    if name == ".git" {
                        if values.isDirectory == true {
                            isRepository = true
                        } else if values.isRegularFile == true {
                            let marker = try String(contentsOf: entry, encoding: .utf8)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if marker.hasPrefix("gitdir:"),
                               !marker.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                isRepository = true
                            } else {
                                warnings.insert("Ungültige Git-Verweisdatei: \(entry.path)")
                            }
                        }
                        continue
                    }
                    if values.isDirectory == true && !excludedDirectories.contains(name) {
                        pending.append(entry.standardizedFileURL)
                    }
                } catch {
                    warnings.insert("Eintrag konnte nicht geprüft werden: \(entry.path). \(error.localizedDescription)")
                }
            }

            guard isRepository else { continue }
            let project: DevProject?
            let issue: String?
            if !manager.fileExists(atPath: directory.appendingPathComponent("package.json").path) {
                project = nil
                issue = "Keine package.json gefunden; kein Frontend-Entwicklungsbefehl erkannt."
            } else {
                do {
                    project = try ProjectDiscovery.inspect(directory: directory)
                    issue = nil
                } catch {
                    project = nil
                    issue = "Frontend-Konfiguration konnte nicht erkannt werden: \(error.localizedDescription)"
                }
            }
            repositories.append(DiscoveredRepository(directoryPath: directory.path, project: project, issue: issue))
        }
        return RepositoryScanResult(
            repositories: repositories.sorted { $0.directoryPath < $1.directoryPath },
            warnings: warnings.sorted()
        )
    }
}
