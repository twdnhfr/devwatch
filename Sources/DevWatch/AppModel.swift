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
    let updates: UpdateChecker
    private var updateSubscription: AnyCancellable?

    init() {
        let feed = (Bundle.main.object(forInfoDictionaryKey: "DWReleaseFeedURL") as? String)
            .flatMap { URL(string: $0) }
        updates = UpdateChecker(feedURL: feed, currentVersion: AppModel.bundleVersion)
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevWatch", isDirectory: true)
        storage = ProjectStorage(fileURL: directory.appendingPathComponent("projects.json"))
        rootStorage = RootFolderSettingsStorage(fileURL: directory.appendingPathComponent("roots.json"))
        updateSubscription = updates.objectWillChange.sink { [weak self] _ in
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
        updates.start()
        rescan()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.rescan()
            }
        }
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
        rescan()
    }

    func removeRoot(_ path: String) {
        var updated = rootSettings
        updated.paths.removeAll { $0 == path }
        guard saveRoots(updated) else { return }
        rescan()
    }

    func showHiddenRepositories() {
        var updated = rootSettings
        updated.hiddenRepositoryPaths = []
        guard saveRoots(updated) else { return }
        rescan()
    }

    func rescan() {
        guard !isScanning, rootsAvailable, storageAvailable else { return }
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
                scriptSubscriptions[key] = runner.process.objectWillChange.sink { [weak self] _ in
                    self?.objectWillChange.send()
                }
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
        subscriptions[project.id] = automation.process.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return automation
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
        updates.stop()
        scanTask?.cancel()
        refreshTask?.cancel()
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
