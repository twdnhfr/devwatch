import Darwin
import Foundation

/// A development server for a project that DevWatch did not start.
public struct ExternalProcess: Equatable, Sendable {
    public let pid: pid_t
    public let arguments: [String]
}

/// Finds an already running dev command so autostart does not collide with it. Never adopts or signals it.
public enum ExternalProcessDetector {
    private static let packageManagers: Set<String> = ["bun", "npm", "yarn", "pnpm"]
    private static let packageManagerScripts = ["npm-cli.js", "yarn.js", "yarn.cjs", "pnpm.js", "pnpm.cjs"]
    // A script tool this generic would also match unrelated processes such as MCP servers.
    private static let genericTools: Set<String> = packageManagers.union(["node", "sh", "bash", "zsh", "php", "composer"])
    private static let wrappers: Set<String> = ["cross-env", "env", "npx", "bunx"]

    /// Checks processes of this user whose working directory is exactly the project folder.
    /// Descendants of `owner` (by default DevWatch itself) are its own processes and are skipped.
    public static func find(project: DevProject, owner: pid_t? = getpid()) -> ExternalProcess? {
        guard project.arguments.count == 2, project.arguments[0] == "run" else { return nil }
        let scriptName = project.arguments[1]
        let script = (try? ProjectDiscovery.scripts(directory: URL(fileURLWithPath: project.directoryPath)))?[scriptName]
        guard let physical = realpath(project.directoryPath, nil) else { return nil }
        let directory = String(cString: physical)
        free(physical)

        var pids = [pid_t](repeating: 0, count: 16_384)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return nil }
        var parents: [pid_t: pid_t] = [:]
        var candidates: [pid_t] = []
        let user = getuid()
        for pid in pids.prefix(count) where pid > 0 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { continue }
            parents[pid] = pid_t(info.pbi_ppid)
            guard info.pbi_uid == user, workingDirectory(of: pid) == directory else { continue }
            candidates.append(pid)
        }
        for pid in candidates.sorted() {
            if let owner, isDescendant(pid, of: owner, parents: parents) { continue }
            guard let arguments = arguments(of: pid),
                  matches(arguments: arguments, scriptName: scriptName, script: script) else { continue }
            return ExternalProcess(pid: pid, arguments: arguments)
        }
        return nil
    }

    /// Recognizes `<manager> [run] <script>` or the script's own tool, e.g. `node …/.bin/vite`.
    static func matches(arguments: [String], scriptName: String, script: String?) -> Bool {
        var arguments = arguments.filter { !$0.isEmpty }
        // Node tools like npm set process.title, which rewrites argv[0] as one string with spaces.
        if let first = arguments.first, first.contains(" "), !FileManager.default.fileExists(atPath: first) {
            arguments = first.split(whereSeparator: \.isWhitespace).map(String.init) + arguments.dropFirst()
        }
        let names = arguments.prefix(2).map { ($0 as NSString).lastPathComponent }
        for (index, name) in names.enumerated()
        where packageManagers.contains(name) || packageManagerScripts.contains(name) {
            let rest = Array(arguments.dropFirst(index + 1).prefix(2))
            if rest.first == scriptName || rest == ["run", scriptName] || rest == ["run-script", scriptName] { return true }
        }
        guard let script, let command = command(in: script) else { return false }
        for (index, name) in names.enumerated() where name == command.tool {
            guard let subcommand = command.subcommand else { return true }
            if arguments.dropFirst(index + 1).first == subcommand { return true }
        }
        return false
    }

    /// The first specific tool and its subcommand, skipping environment assignments, wrappers
    /// and generic steps such as `npm run prepare && vite dev`.
    private static func command(in script: String) -> (tool: String, subcommand: String?)? {
        for part in script.components(separatedBy: CharacterSet(charactersIn: "&|;")) {
            let words = part.split(whereSeparator: \.isWhitespace).map(String.init)
                .drop { $0.contains("=") || wrappers.contains($0) }
            guard let tool = words.first.map({ ($0 as NSString).lastPathComponent }), !genericTools.contains(tool) else { continue }
            let subcommand = words.dropFirst().first.flatMap { $0.hasPrefix("-") ? nil : $0 }
            return (tool, subcommand)
        }
        return nil
    }

    private static func isDescendant(_ pid: pid_t, of owner: pid_t, parents: [pid_t: pid_t]) -> Bool {
        var current = pid
        var steps = 0
        while let parent = parents[current], parent > 1, steps < 64 {
            if parent == owner { return true }
            current = parent
            steps += 1
        }
        return false
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return nil }
        return withUnsafePointer(to: info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    /// Reads argv from KERN_PROCARGS2: argc, executable path, padding, then the arguments.
    private static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var limit: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &limit, &size, nil, 0) == 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(limit))
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}
