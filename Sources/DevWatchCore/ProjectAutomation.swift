import Combine
import Foundation

/// Coordinates approval, observation and process lifecycle for one working directory.
@MainActor
public final class ProjectAutomation: ObservableObject {
    public let process = DevelopmentProcess()
    @Published public private(set) var project: DevProject
    @Published public private(set) var status = "Autostart nicht freigegeben"
    @Published public private(set) var lastChange: String?
    @Published public private(set) var idleDeadline: Date?
    private let inactivityTimeout: TimeInterval
    private var idleTask: Task<Void, Never>?
    private var timerGeneration = UUID()
    private var idleStopInProgress = false
    private var activityWhileStopping = false
    private var watcher: ProjectWatcher?
    private var subscription: AnyCancellable?
    private var shuttingDown = false
    private var hasRequestedApproval = false
    private let onApprovalNeeded: ((DevProject, [String]) -> Void)?
    private let persist: (DevProject) -> Bool
    public var excludedDirectories: [String] = []

    public init(project: DevProject,
                inactivityTimeout: TimeInterval = 30 * 60,
                onApprovalNeeded: ((DevProject, [String]) -> Void)? = nil,
                persist: @escaping (DevProject) -> Bool) {
        self.project = project
        self.inactivityTimeout = inactivityTimeout.isFinite && inactivityTimeout > 0 ? inactivityTimeout : 30 * 60
        self.onApprovalNeeded = onApprovalNeeded
        self.persist = persist
        subscription = process.$isRunning.dropFirst().sink { [weak self] running in
            // Published values arrive before the property's mutation has completed.
            Task { @MainActor [weak self] in
                guard let self, !running, !self.process.isRunning else { return }
                self.processEnded()
            }
        }
    }

    public func beginObserving() {
        watcher?.stop()
        watcher = nil
        guard !shuttingDown, project.autostartPaused != true || process.isRunning else {
            status = "Autostart pausiert"
            return
        }
        if project.autostartEnabled, let approval = project.autostartApproval, !approval.matches(project: project) {
            invalidateApproval()
            return
        }
        do {
            let observer = ProjectWatcher(directory: URL(fileURLWithPath: project.directoryPath),
                                          onChange: { [weak self] paths in self?.filesChanged(paths) },
                                          onError: { [weak self] message in self?.pause(reason: message) })
            try observer.start()
            watcher = observer
            status = project.autostartApproval == nil
                ? "Beobachtet Änderungen – Start noch nicht freigegeben"
                : "Autostart aktiv – wartet auf Dateiänderung"
        } catch { pause(reason: "Dateibeobachtung fehlgeschlagen: \(error.localizedDescription)") }
    }

    /// Approval is captured when the dialog opens and rechecked when confirmed.
    public func enable(approval: AutostartApproval) {
        guard approval.matches(project: project) else {
            invalidateApproval()
            return
        }
        var updated = project
        updated.autostartApproval = approval
        updated.autostartPaused = false
        guard persist(updated) else { return }
        project = updated
        beginObserving()
    }

    /// Confirms the activity prompt and starts immediately, without requiring another edit.
    public func approveAndStart(approval: AutostartApproval) {
        guard !shuttingDown else { return }
        enable(approval: approval)
        guard project.autostartEnabled, approval.matches(project: project),
              project.autostartApproval == approval else { return }
        launch()
    }

    public func configure(_ updated: DevProject) {
        project = updated
        beginObserving()
    }

    public func pause(reason: String = "Autostart pausiert") {
        if !process.isRunning {
            watcher?.stop()
            watcher = nil
        }
        var updated = project
        updated.autostartPaused = true
        project = updated // Fail closed even when persistence fails.
        _ = persist(updated)
        // Keep an existing observer for a running server's idle timer, but never rearm on observer errors.
        status = reason
    }

    public func startManually() {
        guard !shuttingDown else { return }
        launch()
    }

    public func stopManually() {
        cancelIdleTimer()
        idleStopInProgress = false
        activityWhileStopping = false
        pause()
        watcher?.stop()
        watcher = nil
        process.stop()
    }

    public func shutdown() {
        shuttingDown = true
        cancelIdleTimer()
        idleStopInProgress = false
        activityWhileStopping = false
        watcher?.stop()
        watcher = nil
        process.stop()
    }

    private func filesChanged(_ paths: [String]) {
        guard !shuttingDown else { return }
        let relevant = paths.filter { path in
            !excludedDirectories.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        guard !relevant.isEmpty else { return }
        lastChange = relevant.sorted().prefix(3).joined(separator: ", ")
        // Remember edits even after the process exited but before processEnded runs.
        if idleStopInProgress || process.isRunning {
            if idleStopInProgress { activityWhileStopping = true }
            else { resetIdleTimer() }
            if project.autostartEnabled, project.autostartApproval?.matches(project: project) != true {
                invalidateApproval()
            }
            return
        }
        guard project.autostartPaused != true else { return }
        if project.autostartApproval == nil {
            guard !process.isRunning, !hasRequestedApproval else { return }
            hasRequestedApproval = true
            onApprovalNeeded?(project, relevant.sorted())
            return
        }
        guard project.autostartApproval?.matches(project: project) == true else {
            invalidateApproval()
            return
        }
        guard !process.isRunning else { return }
        launch()
    }

    private func launch() {
        guard !process.isRunning, !idleStopInProgress, !shuttingDown else { return }
        process.start(directory: URL(fileURLWithPath: project.directoryPath),
                      executable: project.executable, arguments: project.arguments)
        if !process.isRunning {
            cancelIdleTimer()
            pause(reason: "Start fehlgeschlagen – Autostart pausiert")
        } else {
            resetIdleTimer()
            if watcher == nil { beginObserving() }
        }
    }

    private func resetIdleTimer() {
        cancelIdleTimer()
        guard process.isRunning, !shuttingDown, !idleStopInProgress else { return }
        let generation = UUID()
        timerGeneration = generation
        let interval = inactivityTimeout
        idleDeadline = Date().addingTimeInterval(interval)
        // ContinuousClock includes time spent asleep; an expired deadline is handled on wake.
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(interval), clock: .continuous) }
            catch { return }
            guard let self, !Task.isCancelled, self.timerGeneration == generation,
                  !self.shuttingDown, self.process.isRunning else { return }
            self.idleTask = nil
            self.idleDeadline = nil
            self.idleStopInProgress = true
            self.activityWhileStopping = false
            self.status = "Inaktivität – Prozess wird beendet"
            self.process.stop()
        }
    }

    private func cancelIdleTimer() {
        timerGeneration = UUID()
        idleTask?.cancel()
        idleTask = nil
        idleDeadline = nil
    }

    private func processEnded() {
        cancelIdleTimer()
        guard !shuttingDown else { return }
        if idleStopInProgress {
            let restart = activityWhileStopping && project.autostartEnabled &&
                project.autostartApproval?.matches(project: project) == true
            idleStopInProgress = false
            activityWhileStopping = false
            if project.autostartPaused == true {
                watcher?.stop()
                watcher = nil
            } else if watcher == nil {
                beginObserving()
            }
            if restart { launch() }
            else { status = "Nach Inaktivität gestoppt" }
        } else if project.autostartEnabled {
            pause(reason: "Prozess beendet – Autostart pausiert")
        } else if project.autostartPaused == true {
            watcher?.stop()
            watcher = nil
        } else if watcher == nil {
            beginObserving()
        }
    }

    private func invalidateApproval() {
        if !process.isRunning {
            watcher?.stop()
            watcher = nil
        }
        var updated = project
        updated.autostartApproval = nil
        updated.autostartPaused = true
        project = updated
        _ = persist(updated)
        status = "Projekt oder Befehl geändert – erneut freigeben"
    }
}
