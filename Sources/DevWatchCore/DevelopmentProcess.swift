import Combine
import Darwin
import Foundation

/// Owns only processes launched by this instance; never adopts an existing server.
@MainActor
public final class DevelopmentProcess: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var log = ""
    @Published public private(set) var errorMessage: String?

    private var child: ManagedChild?
    private var generation = UUID()
    private var requestedStop = false
    private let logLimit = 64_000

    public init() {}

    deinit { child?.terminate() }

    public func start(directory: URL, executable: String, arguments: [String]) {
        guard !isRunning else { return }
        errorMessage = nil
        log = ""
        requestedStop = false
        let token = UUID()
        generation = token
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        paths += [home + "/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin",
                  home + "/Library/Application Support/Herd/bin"]
        // Herd's NVM installation is usable without sourcing interactive shell configuration.
        // With multiple installed versions the user must provide a PATH or absolute executable.
        let nodeRoot = URL(fileURLWithPath: home + "/Library/Application Support/Herd/config/nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(at: nodeRoot, includingPropertiesForKeys: nil),
           versions.count == 1 {
            paths.append(versions[0].appendingPathComponent("bin").path)
        }
        environment["PATH"] = paths.joined(separator: ":")
        environment["PWD"] = directory.path
        let resolved: String?
        if executable.hasPrefix("/") {
            resolved = FileManager.default.isExecutableFile(atPath: executable) ? executable : nil
        } else if executable.contains("/") {
            let candidate = directory.appendingPathComponent(executable).path
            resolved = FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
        } else {
            resolved = paths.map { URL(fileURLWithPath: $0).appendingPathComponent(executable).path }
                .first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        guard let resolved, !executable.isEmpty else {
            errorMessage = "Programm nicht gefunden: \(executable). Bitte Installation oder absoluten Pfad prüfen."
            return
        }
        do {
            let launched = try ManagedChild.launch(directory: directory, executable: resolved,
                                                   arguments: arguments, environment: environment)
            child = launched.child
            isRunning = true
            append("Gestartet: \(resolved) \(arguments.joined(separator: " "))\n")
            // A dedicated reader prevents full stdout/stderr pipes from blocking the server.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                defer { close(launched.output) }
                var buffer = [UInt8](repeating: 0, count: 4096)
                var decoder = StreamingUTF8Decoder()
                while true {
                    // POSIX read returns the currently available bytes. Foundation's
                    // read(upToCount:) may wait for the whole buffer or EOF on a pipe.
                    let count = Darwin.read(launched.output, &buffer, buffer.count)
                    if count < 0 && errno == EINTR { continue }
                    let chunk = count > 0
                        ? decoder.append(Array(buffer.prefix(count)))
                        : decoder.finish()
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == token else { return }
                        self.append(chunk)
                    }
                    if count <= 0 { break }
                }
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let status = launched.child.waitForExit()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.child = nil
                    self.isRunning = false
                    if !self.requestedStop && status != 0 {
                        self.errorMessage = "Prozess beendet (Status \(status)). Details stehen im Log."
                    }
                    self.append("\nProzess beendet.\n")
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Sends TERM to the owned group, followed by KILL after one second if needed.
    public func stop() {
        guard let child, !requestedStop else { return }
        requestedStop = true
        child.terminate()
    }

    private func append(_ text: String) {
        log += text
        if log.utf8.count > logLimit { log = String(log.suffix(logLimit / 2)) }
    }
}

/// Keeps an incomplete multibyte sequence for the next pipe read, up to three bytes.
private struct StreamingUTF8Decoder {
    private var pending: [UInt8] = []

    mutating func append(_ bytes: [UInt8]) -> String {
        pending += bytes
        var boundary = pending.count
        if !pending.isEmpty {
            var lead = pending.count - 1
            while lead > 0 && pending[lead] & 0xc0 == 0x80 { lead -= 1 }
            let byte = pending[lead]
            let width: Int
            switch byte {
            case 0xc2...0xdf: width = 2
            case 0xe0...0xef: width = 3
            case 0xf0...0xf4: width = 4
            default: width = 1
            }
            if pending.count - lead < width { boundary = lead }
        }
        let text = String(decoding: pending.prefix(boundary), as: UTF8.self)
        pending = Array(pending.dropFirst(boundary))
        return text
    }

    mutating func finish() -> String {
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }
}

/// Synchronizes signals and reaping so a stale PID can never target a reused process ID.
private final class ManagedChild: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?

    private init(pid: pid_t) { self.pid = pid }

    static func launch(directory: URL, executable: String, arguments: [String],
                       environment: [String: String]) throws -> (child: ManagedChild, output: Int32) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw posixError(errno) }
        var success = false
        defer {
            close(fds[1])
            if !success { close(fds[0]) }
        }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        if #available(macOS 26.0, *) {
            try check(posix_spawn_file_actions_addchdir(&actions, directory.path))
        } else {
            try check(posix_spawn_file_actions_addchdir_np(&actions, directory.path))
        }
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, fds[1], STDERR_FILENO))
        try check(posix_spawn_file_actions_addclose(&actions, fds[0]))
        try check(posix_spawn_file_actions_addclose(&actions, fds[1]))
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var spawned: pid_t = 0
        try check(posix_spawn(&spawned, executable, &actions, &attributes, argv, envp))
        success = true
        return (ManagedChild(pid: spawned), fds[0])
    }

    func terminate() {
        signal(SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
            signal(SIGKILL)
        }
    }

    private func signal(_ value: Int32) {
        lock.lock()
        defer { lock.unlock() }
        if let pid { _ = kill(-pid, value) }
    }

    func waitForExit() -> Int32 {
        lock.lock()
        let originalPID = pid!
        lock.unlock()
        // Leave the exited leader unreaped until group cleanup, preventing PID reuse.
        var info = siginfo_t()
        while waitid(P_PID, id_t(originalPID), &info, WEXITED | WNOWAIT) == -1 {
            if errno != EINTR { break }
        }
        lock.lock()
        defer { lock.unlock() }
        _ = kill(-originalPID, SIGKILL)
        var status: Int32 = 0
        while waitpid(originalPID, &status, 0) == -1 && errno == EINTR {}
        pid = nil
        let terminationSignal = status & 0x7f
        return terminationSignal == 0 ? (status >> 8) & 0xff : 128 + terminationSignal
    }

    private static func check(_ code: Int32) throws {
        if code != 0 { throw posixError(code) }
    }

    private static func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: nil)
    }
}
