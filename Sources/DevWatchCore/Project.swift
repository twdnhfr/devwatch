import Foundation

public struct DevProject: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var directoryPath: String
    public var executable: String
    public var arguments: [String]
    public var autostartApproval: AutostartApproval?
    public var autostartPaused: Bool?

    public var autostartEnabled: Bool { autostartApproval != nil && autostartPaused != true }

    /// Apply the default once; explicit pauses and existing approvals remain unchanged.
    public func applyingDefaultAutostart() -> DevProject {
        guard autostartApproval == nil, autostartPaused != true,
              let approval = try? AutostartApproval.capture(project: self) else { return self }
        var updated = self
        updated.autostartApproval = approval
        updated.autostartPaused = false
        return updated
    }

    public var name: String {
        URL(fileURLWithPath: directoryPath).lastPathComponent
    }

    public init(
        id: UUID = UUID(),
        directoryPath: String,
        executable: String = "bun",
        arguments: [String] = ["run", "dev"]
    ) {
        self.id = id
        self.directoryPath = directoryPath
        self.executable = executable
        self.arguments = arguments
    }
}

public enum ProjectDiscovery {
    public enum DiscoveryError: LocalizedError, Equatable {
        case missingDevScript
        case unsupportedPackageManager(String)
        case ambiguousLockfiles([String])

        public var errorDescription: String? {
            switch self {
            case .missingDevScript:
                return "Die package.json enthält kein ausführbares dev- oder build-Script."
            case .unsupportedPackageManager(let manager):
                return "Der Paketmanager \(manager) wird nicht unterstützt. Unterstützt werden bun, npm, yarn und pnpm."
            case .ambiguousLockfiles(let managers):
                return "Lockfiles für mehrere Paketmanager gefunden: \(managers.joined(separator: ", ")). Bitte packageManager in package.json festlegen oder veraltete Lockfiles entfernen."
            }
        }
    }

    private struct PackageManifest: Decodable {
        var scripts: [String: String]?
        var packageManager: String?
    }

    /// Reads script names for explicit, user-triggered execution; never runs them.
    public static func scripts(directory: URL) throws -> [String: String] {
        let data = try Data(contentsOf: directory.appendingPathComponent("package.json"))
        let manifest = try JSONDecoder().decode(PackageManifest.self, from: data)
        return (manifest.scripts ?? [:]).filter {
            !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Proposes a command without running scripts or installing dependencies.
    public static func inspect(directory: URL) throws -> DevProject {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let manifestData = try Data(contentsOf: directory.appendingPathComponent("package.json"))
        let manifest = try JSONDecoder().decode(PackageManifest.self, from: manifestData)
        guard let scriptName = ["dev", "build"].first(where: {
            !(manifest.scripts?[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }) else {
            throw DiscoveryError.missingDevScript
        }

        let supported = ["bun", "npm", "yarn", "pnpm"]
        let executable: String
        if let declaration = manifest.packageManager {
            let manager = declaration.split(separator: "@", omittingEmptySubsequences: false)
                .first.map(String.init) ?? ""
            guard supported.contains(manager) else {
                throw DiscoveryError.unsupportedPackageManager(declaration)
            }
            executable = manager
        } else {
            let lockfiles: [(String, [String])] = [
                ("bun", ["bun.lock", "bun.lockb"]),
                ("npm", ["package-lock.json", "npm-shrinkwrap.json"]),
                ("yarn", ["yarn.lock"]),
                ("pnpm", ["pnpm-lock.yaml"])
            ]
            let detected = lockfiles.compactMap { manager, filenames -> String? in
                filenames.contains { filename in
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent(filename).path,
                        isDirectory: &isDirectory
                    ) && !isDirectory.boolValue
                } ? manager : nil
            }
            guard detected.count <= 1 else {
                throw DiscoveryError.ambiguousLockfiles(detected.sorted())
            }
            executable = detected.first ?? "npm"
        }
        return DevProject(directoryPath: directory.path, executable: executable, arguments: ["run", scriptName])
    }
}

public final class ProjectStorage {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> [DevProject] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([DevProject].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ projects: [DevProject]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(projects)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
