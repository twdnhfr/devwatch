import AppKit
import Combine
import DevWatchCore

struct ActivityApprovalPrompt: Identifiable {
    var id: UUID { project.id }
    let project: DevProject
    let approval: AutostartApproval
    let script: String
    let changedFiles: [String]
}

@MainActor
final class AppModel: ObservableObject {
    @Published var approvalPrompts: [ActivityApprovalPrompt] = []
    @Published var showFolders = false
    var openProjectsWindow: (() -> Void)?
    @Published private(set) var projects: [DevProject] = []
    @Published var selectedPath: String?
    @Published private(set) var rootSettings = RootFolderSettings()
    @Published private(set) var repositories: [DiscoveredRepository] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scanWarnings: [String] = []
    private var scanTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var rootWatcher: RootFolderWatcher?
    private var rescanRequested = false
    private let rootStorage: RootFolderSettingsStorage
    private var rootsAvailable = true
    @Published var errorMessage: String?
    private var automations: [UUID: ProjectAutomation] = [:]
    private var subscriptions: [UUID: AnyCancellable] = [:]
    private struct ScriptKey: Hashable {
        let projectID: UUID
        let name: String
    }
    private var extraScripts: [ScriptKey: ProjectAutomation] = [:]
    private var scriptSubscriptions: [ScriptKey: AnyCancellable] = [:]
    @Published private(set) var scriptNames: [UUID: [String]] = [:]
    private let storage: ProjectStorage
    private var storageAvailable = true
    let updater: AppUpdater
    private var updateSubscription: AnyCancellable?
    /// Checks daily and installs a prepared update when DevWatch quits.
    @Published var automaticUpdates: Bool {
        didSet {
            UserDefaults.standard.set(automaticUpdates, forKey: "automaticUpdates")
            if automaticUpdates { updater.startAutomaticChecks() } else { updater.stopAutomaticChecks() }
        }
    }

    init() {
        updater = AppModel.makeUpdater()
        UserDefaults.standard.register(defaults: ["automaticUpdates": true])
        automaticUpdates = UserDefaults.standard.bool(forKey: "automaticUpdates")
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevWatch", isDirectory: true)
        storage = ProjectStorage(fileURL: directory.appendingPathComponent("projects.json"))
        rootStorage = RootFolderSettingsStorage(fileURL: directory.appendingPathComponent("roots.json"))
        updateSubscription = updater.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        do { rootSettings = try rootStorage.load() }
        catch { rootsAvailable = false; errorMessage = L10n.text("Could not load root folders: %@", String(describing: error.localizedDescription)) }
        do {
            projects = try storage.load()
            let defaults = projects.map { $0.applyingDefaultAutostart() }
            if defaults != projects {
                try storage.save(defaults)
                projects = defaults
            }
            selectedPath = projects.first?.directoryPath
            let restored = projects
            for project in restored { _ = automation(for: project) }
            refreshOwnership()
            automations.values.forEach { $0.beginObserving() }
            refreshScripts()
        } catch {
            storageAvailable = false
            errorMessage = L10n.text("Could not load the project list: %@", String(describing: error.localizedDescription))
        }
    }

    var listedRepositories: [DiscoveredRepository] {
        var list = repositories.filter { !rootSettings.hiddenRepositoryPaths.contains($0.directoryPath) }.map { repository in
            if repository.issue == nil, let saved = projects.first(where: { $0.directoryPath == repository.directoryPath }) {
                return DiscoveredRepository(directoryPath: saved.directoryPath, project: saved, issue: nil)
            }
            return repository
        }
        let discovered = Set(list.map(\.directoryPath))
        list += projects.filter { !discovered.contains($0.directoryPath) && !rootSettings.hiddenRepositoryPaths.contains($0.directoryPath) }
            .map { DiscoveredRepository(directoryPath: $0.directoryPath, project: $0, issue: nil) }
        return list.sorted { $0.directoryPath.localizedStandardCompare($1.directoryPath) == .orderedAscending }
    }

    static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func activateDiscovery() {
        guard refreshTask == nil else { return }
        if automaticUpdates { updater.startAutomaticChecks() }
        watchRoots()
        rescan()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                // File events trigger rescans; polling remains for roots FSEvents cannot watch.
                let interval = self?.rootWatcher == nil ? 30 : 600
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                self?.rescan()
            }
        }
    }

    private func watchRoots() {
        rootWatcher?.stop()
        rootWatcher = nil
        let watcher = RootFolderWatcher(roots: rootSettings.paths) { [weak self] in self?.rescan() }
        do {
            try watcher.start()
            rootWatcher = watcher
        } catch {
            // The polling fallback in activateDiscovery keeps discovery working.
        }
    }

    private static func makeUpdater() -> AppUpdater {
        let bundle = Bundle.main
        // Forks point DWReleaseFeedURL to their own repository or remove it to disable updates.
        let feed = (bundle.object(forInfoDictionaryKey: "DWReleaseFeedURL") as? String).flatMap { URL(string: $0) }
        var reason: String?
        var installer: UpdateInstaller?
        if bundle.bundleURL.pathExtension != "app" || bundle.bundleURL.path.contains("/AppTranslocation/") {
            reason = UpdateError.notWritable.localizedDescription
        } else if let teamID = UpdateInstaller.currentTeamID(), let bundleID = bundle.bundleIdentifier {
            installer = UpdateInstaller(bundleID: bundleID, teamID: teamID,
                                        workDirectory: FileManager.default.temporaryDirectory
                                            .appendingPathComponent("\(bundleID)-update", isDirectory: true))
        }
        return AppUpdater(currentVersion: bundleVersion, appURL: bundle.bundleURL, installer: installer,
                          unavailableReason: reason, feedURL: feed)
    }

    func checkForUpdates() { Task { await updater.checkNow() } }

    /// Running development processes stop with the restart; the next file change starts them again.
    func installUpdateAndRestart() {
        guard case .ready(let version) = updater.state else { return }
        if runningCount > 0 {
            let alert = NSAlert()
            alert.messageText = L10n.text("Install DevWatch %@ now?", version)
            alert.informativeText = L10n.text("Restarting stops all running development processes. With autostart enabled, the next file change starts them again.")
            alert.addButton(withTitle: L10n.text("Install and Restart"))
            alert.addButton(withTitle: L10n.text("Cancel"))
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        guard updater.installPrepared() else {
            if case .failed(let message) = updater.state {
                errorMessage = message
                openProjectsWindow?()
            }
            return
        }
        updater.relaunchAfterExit()
        NSApp.terminate(nil)
    }

    /// Called while quitting; a prepared update replaces the app on disk for the next launch.
    func installPreparedUpdateOnQuit() {
        if automaticUpdates { updater.installPrepared() }
    }

    func addRootFolder() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Add root folder")
        panel.message = L10n.text("Git repositories and worktrees are scanned recursively. No development processes will be started.")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        var updated = rootSettings
        for url in panel.urls {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            if !updated.paths.contains(path) { updated.paths.append(path) }
        }
        guard saveRoots(updated) else { return }
        if refreshTask != nil { watchRoots() }
        rescan()
    }

    func removeRoot(_ path: String) {
        var updated = rootSettings
        updated.paths.removeAll { $0 == path }
        guard saveRoots(updated) else { return }
        if refreshTask != nil { watchRoots() }
        rescan()
    }

    func showHiddenRepositories() {
        var updated = rootSettings
        updated.hiddenRepositoryPaths = []
        guard saveRoots(updated) else { return }
        rescan()
    }

    func rescan() {
        guard rootsAvailable, storageAvailable else { return }
        // Changes reported during a scan may have been missed by it; scan once more afterwards.
        guard !isScanning else { rescanRequested = true; return }
        rescanRequested = false
        isScanning = true
        let roots = rootSettings.paths
        scanTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { RepositoryScanner.scan(roots: roots) }.value
            guard let self, !Task.isCancelled else { return }
            // A changed root selection is picked up by a fresh scan, never by this stale result.
            guard self.rootSettings.paths == roots else {
                self.isScanning = false
                self.rescan()
                return
            }
            self.scanWarnings = result.warnings
            self.repositories = result.repositories
            var updated = self.projects
            for repository in result.repositories where !self.rootSettings.hiddenRepositoryPaths.contains(repository.directoryPath) {
                if let candidate = repository.project,
                   !updated.contains(where: { $0.directoryPath == candidate.directoryPath }) {
                    updated.append(candidate.applyingDefaultAutostart())
                }
                if repository.project == nil,
                   let existing = self.automations.values.first(where: { $0.project.directoryPath == repository.directoryPath }),
                   existing.project.autostartEnabled {
                    existing.pause(reason: repository.issue ?? L10n.text("No development command detected"))
                }
            }
            do {
                // Preserve any pauses persisted above rather than overwriting them with the scan snapshot.
                let additions = updated.filter { candidate in !self.projects.contains { $0.id == candidate.id } }
                if !additions.isEmpty { try self.persist(self.projects + additions) }
                let newProjects = self.projects.filter { self.automations[$0.id] == nil }
                for project in newProjects { _ = self.automation(for: project) }
                self.refreshOwnership()
                for project in newProjects { self.automations[project.id]?.beginObserving() }
                if self.selectedPath == nil { self.selectedPath = self.listedRepositories.first?.directoryPath }
            } catch { self.errorMessage = error.localizedDescription }
            self.isScanning = false
            self.refreshScripts()
            if self.rescanRequested { self.rescan() }
        }
    }

    private func saveRoots(_ updated: RootFolderSettings) -> Bool {
        guard rootsAvailable else {
            errorMessage = L10n.text("The existing root folder file cannot be read and will not be overwritten.")
            return false
        }
        do { try rootStorage.save(updated); rootSettings = updated; return true }
        catch { errorMessage = error.localizedDescription; return false }
    }

    private var allAutomations: [ProjectAutomation] { Array(automations.values) + Array(extraScripts.values) }

    var runningCount: Int { allAutomations.filter { $0.process.isRunning }.count }

    var runningProjects: [DevProject] {
        projects.filter { project in
            allAutomations.contains { $0.project.directoryPath == project.directoryPath && $0.process.isRunning }
        }.sorted { $0.directoryPath.localizedStandardCompare($1.directoryPath) == .orderedAscending }
    }

    /// Keep completed runs visible so their result doesn't disappear with the process.
    var scriptProjects: [DevProject] {
        projects.filter { project in
            !rootSettings.hiddenRepositoryPaths.contains(project.directoryPath) &&
            allAutomations.contains { $0.project.directoryPath == project.directoryPath && $0.process.state != .idle }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func refreshScripts() {
        var names: [UUID: [String]] = [:]
        for project in projects {
            let manifest = try? ProjectDiscovery.scripts(directory: URL(fileURLWithPath: project.directoryPath))
            var available = Set(manifest?.keys.map { $0 } ?? [])
            // Retain a removed script while it is running, so it can still be stopped.
            for (key, automation) in extraScripts where key.projectID == project.id && automation.process.isRunning {
                available.insert(key.name)
            }
            if automation(for: project).process.isRunning, let name = project.arguments.last { available.insert(name) }
            names[project.id] = available.sorted {
                let priority = ["dev": 0, "build": 1]
                let lhs = priority[$0] ?? 2, rhs = priority[$1] ?? 2
                return lhs == rhs ? $0.localizedStandardCompare($1) == .orderedAscending : lhs < rhs
            }
        }
        scriptNames = names
    }

    func scriptProcess(for project: DevProject, name: String) -> DevelopmentProcess? {
        if project.arguments == ["run", name] { return automations[project.id]?.process }
        return extraScripts[ScriptKey(projectID: project.id, name: name)]?.process
    }

    func toggleScript(for project: DevProject, name: String) {
        let key = ScriptKey(projectID: project.id, name: name)
        let existing = project.arguments == ["run", name] ? automations[project.id] : extraScripts[key]
        if let existing, existing.process.isRunning {
            existing.stopManually()
            return
        }
        do {
            let scripts = try ProjectDiscovery.scripts(directory: URL(fileURLWithPath: project.directoryPath))
            guard scripts[name] != nil else {
                throw NSError(domain: "DevWatch", code: 2, userInfo: [NSLocalizedDescriptionKey: L10n.text("The script %@ no longer exists.", String(describing: name))])
            }
            if project.arguments == ["run", name] {
                automation(for: project).startManually()
            } else {
                // These labels are manual actions; only the project's approved default script autostarts.
                var command = project
                command.arguments = ["run", name]
                command.autostartApproval = nil
                command.autostartPaused = true
                let runner = existing ?? ProjectAutomation(project: command, persist: { _ in true })
                runner.configure(command)
                extraScripts[key] = runner
                scriptSubscriptions[key] = forwardStatus(of: runner.process)
                refreshOwnership()
                runner.startManually()
            }
        } catch {
            errorMessage = error.localizedDescription
            selectedPath = project.directoryPath
            openProjectsWindow?()
        }
    }

    func automation(for project: DevProject) -> ProjectAutomation {
        if let existing = automations[project.id] { return existing }
        let automation = ProjectAutomation(project: project, onApprovalNeeded: { [weak self] candidate, paths in
            self?.offerApproval(for: candidate, paths: paths)
        }) { [weak self] updated in
            guard let self else { return false }
            var list = self.projects
            guard let index = list.firstIndex(where: { $0.id == updated.id }) else { return false }
            list[index] = updated
            do { try self.persist(list); return true }
            catch { self.errorMessage = error.localizedDescription; return false }
        }
        automations[project.id] = automation
        subscriptions[project.id] = forwardStatus(of: automation.process)
        return automation
    }

    /// Log output is observed by the detail view directly; forwarding it would rebuild
    /// every view and the status item on each chunk a development server writes.
    private func forwardStatus(of process: DevelopmentProcess) -> AnyCancellable {
        Publishers.Merge4(process.$state.dropFirst().map { _ in () },
                          process.$isRunning.dropFirst().map { _ in () },
                          process.$exitCode.dropFirst().map { _ in () },
                          process.$errorMessage.dropFirst().map { _ in () })
            .sink { [weak self] in self?.objectWillChange.send() }
    }

    private func refreshOwnership() {
        for automation in allAutomations {
            let prefix = automation.project.directoryPath + "/"
            automation.excludedDirectories = Set(projects.map(\.directoryPath) + repositories.map(\.directoryPath)).compactMap {
                $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil
            }
        }
    }

    func addProject() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Select development project")
        panel.message = L10n.text("Select the project folder containing package.json. No command will be started yet.")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            let candidate = try ProjectDiscovery.inspect(directory: directory.resolvingSymlinksInPath()).applyingDefaultAutostart()
            if rootSettings.hiddenRepositoryPaths.contains(candidate.directoryPath) {
                var settings = rootSettings
                settings.hiddenRepositoryPaths.removeAll { $0 == candidate.directoryPath }
                guard saveRoots(settings) else { return }
            }
            if let existing = projects.first(where: { $0.directoryPath == candidate.directoryPath }) {
                selectedPath = existing.directoryPath
                return
            }
            var updated = projects
            updated.append(candidate)
            try persist(updated)
            selectedPath = candidate.directoryPath
            _ = automation(for: candidate)
            refreshOwnership()
            automations[candidate.id]?.beginObserving()
            refreshScripts()
        } catch { errorMessage = error.localizedDescription }
    }

    private func offerApproval(for project: DevProject, paths: [String]) {
        guard !rootSettings.hiddenRepositoryPaths.contains(project.directoryPath),
              !approvalPrompts.contains(where: { $0.id == project.id }) else { return }
        do {
            let approval = try AutostartApproval.capture(project: project)
            let script = try AutostartApproval.scriptDescription(project: project)
            approvalPrompts.append(ActivityApprovalPrompt(project: project, approval: approval,
                                                         script: script, changedFiles: paths))
        } catch {
            // Invalid manifests cannot be offered for execution; the project detail explains them.
        }
    }

    func dismissActivity(_ prompt: ActivityApprovalPrompt) {
        approvalPrompts.removeAll { $0.id == prompt.id }
    }

    func approveActivity(_ prompt: ActivityApprovalPrompt) {
        guard let current = projects.first(where: { $0.id == prompt.id }),
              !rootSettings.hiddenRepositoryPaths.contains(current.directoryPath) else {
            dismissActivity(prompt)
            return
        }
        guard prompt.approval.matches(project: current) else {
            dismissActivity(prompt)
            errorMessage = L10n.text("The project or command has changed since this prompt appeared. Review the current configuration in the project window and approve it again.")
            selectedPath = current.directoryPath
            openProjectsWindow?()
            return
        }
        automation(for: current).approveAndStart(approval: prompt.approval)
        dismissActivity(prompt)
    }

    func update(_ project: DevProject) {
        var updated = projects
        guard let index = updated.firstIndex(where: { $0.id == project.id }) else { return }
        var changed = project
        if changed.executable != projects[index].executable || changed.arguments != projects[index].arguments {
            changed.autostartApproval = nil
            changed.autostartPaused = true
        }
        updated[index] = changed
        do {
            try persist(updated)
            automation(for: changed).configure(changed)
        } catch { errorMessage = error.localizedDescription }
    }

    func remove(_ project: DevProject) {
        guard !allAutomations.contains(where: { $0.project.directoryPath == project.directoryPath && $0.process.isRunning }) else { return }
        var settings = rootSettings
        if !settings.hiddenRepositoryPaths.contains(project.directoryPath) { settings.hiddenRepositoryPaths.append(project.directoryPath) }
        guard saveRoots(settings) else { return }
        do {
            try persist(projects.filter { $0.id != project.id })
            automations.removeValue(forKey: project.id)?.shutdown()
            for key in Array(extraScripts.keys) where key.projectID == project.id {
                extraScripts.removeValue(forKey: key)?.shutdown()
                scriptSubscriptions.removeValue(forKey: key)
            }
            refreshOwnership()
            subscriptions.removeValue(forKey: project.id)
            selectedPath = projects.first?.directoryPath
        } catch { errorMessage = error.localizedDescription }
    }

    func stopAll() { allAutomations.forEach { $0.stopManually() } }

    func shutdown() {
        approvalPrompts = []
        updater.stopAutomaticChecks()
        scanTask?.cancel()
        refreshTask?.cancel()
        rootWatcher?.stop()
        rootWatcher = nil
        allAutomations.forEach { $0.shutdown() }
    }

    private func persist(_ updated: [DevProject]) throws {
        guard storageAvailable else {
            throw NSError(domain: "DevWatch", code: 1, userInfo: [NSLocalizedDescriptionKey:
                L10n.text("The existing project file could not be read and will not be overwritten. Check ~/Library/Application Support/DevWatch/projects.json and restart the app.")])
        }
        try storage.save(updated)
        projects = updated
        approvalPrompts.removeAll { prompt in
            guard let current = updated.first(where: { $0.id == prompt.id }) else { return true }
            return current.autostartEnabled || current.autostartPaused == true ||
                current.executable != prompt.project.executable || current.arguments != prompt.project.arguments
        }
    }
}
