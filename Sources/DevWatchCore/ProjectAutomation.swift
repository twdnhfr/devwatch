import Combine
import Foundation

/// Coordinates approval, observation and process lifecycle for one working directory.
@MainActor
public final class ProjectAutomation: ObservableObject {
    public let process = DevelopmentProcess()
    @Published public private(set) var project: DevProject
    @Published public private(set) var status = "Autostart nicht freigegeben"
    @Published public private(set) var lastChange: String?
    private var watcher: ProjectWatcher?
    private var subscription: AnyCancellable?
    private var shuttingDown = false
    private var hasRequestedApproval = false
    private let onApprovalNeeded: ((DevProject, [String]) -> Void)?
    private let persist: (DevProject) -> Bool
    public var excludedDirectories: [String] = []

    public init(project: DevProject,
                onApprovalNeeded: ((DevProject, [String]) -> Void)? = nil,
                persist: @escaping (DevProject) -> Bool) {
        self.project = project
        self.onApprovalNeeded = onApprovalNeeded
        self.persist = persist
        subscription = process.$isRunning.dropFirst().sink { [weak self] running in
            // Published values arrive before the property's mutation has completed.
            Task { @MainActor [weak self] in
                guard let self, !running, !self.process.isRunning, !self.shuttingDown, self.project.autostartEnabled else { return }
                self.pause(reason: "Prozess beendet – Autostart pausiert")
            }
        }
    }

    public func beginObserving() {
        watcher?.stop()
        watcher = nil
        guard project.autostartPaused != true, !shuttingDown else {
            status = "Autostart pausiert"
            return
        }
        if let approval = project.autostartApproval, !approval.matches(project: project) {
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
        watcher?.stop()
        watcher = nil
        var updated = project
        updated.autostartPaused = true
        project = updated // Fail closed even when persistence fails.
        _ = persist(updated)
        status = reason
    }

    public func startManually() {
        guard !shuttingDown else { return }
        launch()
    }

    public func stopManually() {
        pause()
        process.stop()
    }

    public func shutdown() {
        shuttingDown = true
        watcher?.stop()
        watcher = nil
        process.stop()
    }

    private func filesChanged(_ paths: [String]) {
        guard !shuttingDown, project.autostartPaused != true else { return }
        let relevant = paths.filter { path in
            !excludedDirectories.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        guard !relevant.isEmpty else { return }
        lastChange = relevant.sorted().prefix(3).joined(separator: ", ")
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
        guard !process.isRunning else { return }
        process.start(directory: URL(fileURLWithPath: project.directoryPath),
                      executable: project.executable, arguments: project.arguments)
        if !process.isRunning {
            pause(reason: "Start fehlgeschlagen – Autostart pausiert")
        }
    }

    private func invalidateApproval() {
        watcher?.stop()
        watcher = nil
        var updated = project
        updated.autostartApproval = nil
        updated.autostartPaused = true
        project = updated
        _ = persist(updated)
        status = "Projekt oder Befehl geändert – erneut freigeben"
    }
}
