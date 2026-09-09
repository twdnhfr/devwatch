import CryptoKit
import Foundation

/// Binds an explicit approval to a directory, command and exact manifest contents.
public struct AutostartApproval: Codable, Equatable, Sendable {
    public let fingerprint: String

    public enum ApprovalError: LocalizedError, Equatable {
        case unsupportedCommand
        case unreadableManifest
        case invalidManifest
        case missingDevScript

        public var errorDescription: String? {
            switch self {
            case .unsupportedCommand:
                return L10n.text("Autostart requires an executable name or absolute path with the arguments run dev or run build.")
            case .unreadableManifest:
                return L10n.text("Could not read the project's package.json. Check the path and access permissions.")
            case .invalidManifest:
                return L10n.text("The package.json file is invalid or contains no valid script definitions.")
            case .missingDevScript:
                return L10n.text("The package.json file contains no runnable script for the selected command.")
            }
        }
    }

    private struct Manifest: Decodable {
        var scripts: [String: String]?
    }

    private struct FingerprintInput: Encodable {
        let directoryPath: String
        let executable: String
        let arguments: [String]
        let manifest: Data
    }

    public static func capture(project: DevProject) throws -> AutostartApproval {
        let (directory, data, _) = try readManifest(project: project)
        let input = FingerprintInput(
            directoryPath: directory.path,
            executable: project.executable,
            arguments: project.arguments,
            manifest: data
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(input))
        return AutostartApproval(fingerprint: digest.map { String(format: "%02x", $0) }.joined())
    }

    public func matches(project: DevProject) -> Bool {
        guard let current = try? Self.capture(project: project) else { return false }
        return current == self
    }

    /// Lists lifecycle scripts for review; actual lifecycle behavior depends on the manager.
    public static func scriptDescription(project: DevProject) throws -> String {
        let (_, _, manifest) = try readManifest(project: project)
        let name = project.arguments[1]
        return ["pre" + name, name, "post" + name].compactMap { name in
            guard let script = manifest.scripts?[name] else { return nil }
            return "\(name): \(script)"
        }.joined(separator: "\n")
    }

    private static func readManifest(project: DevProject) throws -> (URL, Data, Manifest) {
        guard !project.executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !project.executable.contains("/") || project.executable.hasPrefix("/"),
              (["run", "dev"] == project.arguments || ["run", "build"] == project.arguments) else {
            throw ApprovalError.unsupportedCommand
        }
        let directory = URL(fileURLWithPath: project.directoryPath)
            .standardizedFileURL.resolvingSymlinksInPath()
        let data: Data
        do {
            data = try Data(contentsOf: directory.appendingPathComponent("package.json"))
        } catch {
            throw ApprovalError.unreadableManifest
        }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw ApprovalError.invalidManifest
        }
        guard let dev = manifest.scripts?[project.arguments[1]],
              !dev.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ApprovalError.missingDevScript
        }
        return (directory, data, manifest)
    }
}
