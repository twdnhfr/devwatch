import Foundation

/// Assembles the PATH for launched development commands.
public enum SearchPath {
    public static func split(_ path: String?) -> [String] {
        (path ?? "").split(separator: ":").map(String.init)
    }

    /// Keeps the first occurrence of each absolute directory and drops the rest,
    /// so an earlier group decides which of two identical tools is found.
    public static func combine(_ groups: [String]...) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for group in groups {
            for entry in group where entry.hasPrefix("/") {
                let trimmed = entry.count > 1 && entry.hasSuffix("/") ? String(entry.dropLast()) : entry
                if seen.insert(trimmed).inserted { result.append(trimmed) }
            }
        }
        return result
    }
}

/// A Finder-launched app inherits only the minimal system PATH. Node version
/// managers such as nvm, fnm, Volta, mise and asdf install per user and are put
/// on the PATH by shell configuration alone, so ask the login shell once instead
/// of guessing their directories.
public final class LoginShellPath: @unchecked Sendable {
    public static let shared = LoginShellPath()

    private let lock = NSLock()
    private var cached: [String]?
    private let read: () -> [String]

    init(read: @escaping () -> [String] = LoginShellPath.readFromLoginShell) {
        self.read = read
    }

    /// Reads at most once per app run; repeated calls reuse the first result.
    public func directories() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let resolved = read()
        cached = resolved
        return resolved
    }

    static func readFromLoginShell() -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard shell.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: shell) else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // A login shell (-l) sources the configuration that installs the version
        // manager. An interactive shell is deliberately avoided: it may draw a
        // prompt or wait for job control and would never return.
        process.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        // A misconfigured profile can hang; partial output is better than a stall.
        let watchdog = DispatchWorkItem { process.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return [] }
        return SearchPath.split(String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
