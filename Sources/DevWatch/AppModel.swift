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
    private let storage: ProjectStorage
    private var storageAvailable = true

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevWatch", isDirectory: true)
        storage = ProjectStorage(fileURL: directory.appendingPathComponent("projects.json"))
        rootStorage = RootFolderSettingsStorage(fileURL: directory.appendingPathComponent("roots.json"))
        do { rootSettings = try rootStorage.load() }
        catch { rootsAvailable = false; errorMessage = "Stammordner konnten nicht geladen werden: \(error.localizedDescription)" }
        do {
            projects = try storage.load()
            selectedPath = projects.first?.directoryPath
            let restored = projects
            for project in restored { _ = automation(for: project) }
            refreshOwnership()
            automations.values.forEach { $0.beginObserving() }
        } catch {
            storageAvailable = false
            errorMessage = "Projektliste konnte nicht geladen werden: \(error.localizedDescription)"
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

    func activateDiscovery() {
        guard refreshTask == nil else { return }
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
        panel.title = "Stammordner hinzufügen"
        panel.message = "Git-Repositories und Worktrees werden rekursiv gesucht. Es werden keine Entwicklungsprozesse gestartet."
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
                    updated.append(candidate)
                }
                if repository.project == nil,
                   let existing = self.automations.values.first(where: { $0.project.directoryPath == repository.directoryPath }),
                   existing.project.autostartEnabled {
                    existing.pause(reason: repository.issue ?? "Kein Entwicklungsbefehl erkannt")
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
        }
    }

    private func saveRoots(_ updated: RootFolderSettings) -> Bool {
        guard rootsAvailable else {
            errorMessage = "Die bestehende Stammordner-Datei ist nicht lesbar und wird nicht überschrieben."
            return false
        }
        do { try rootStorage.save(updated); rootSettings = updated; return true }
        catch { errorMessage = error.localizedDescription; return false }
    }

    var runningCount: Int { automations.values.filter { $0.process.isRunning }.count }

    var runningProjects: [DevProject] {
        automations.values.filter { $0.process.isRunning }.map(\.project)
            .sorted { $0.directoryPath.localizedStandardCompare($1.directoryPath) == .orderedAscending }
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
        for automation in automations.values {
            let prefix = automation.project.directoryPath + "/"
            automation.excludedDirectories = Set(projects.map(\.directoryPath) + repositories.map(\.directoryPath)).compactMap {
                $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil
            }
        }
    }

    func addProject() {
        let panel = NSOpenPanel()
        panel.title = "Entwicklungsprojekt auswählen"
        panel.message = "Wähle den Projektordner mit seiner package.json. Es wird noch kein Befehl gestartet."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            let candidate = try ProjectDiscovery.inspect(directory: directory.resolvingSymlinksInPath())
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
            errorMessage = "Das Projekt oder der Befehl wurde seit dem Hinweis geändert. Bitte die aktuelle Konfiguration im Projektfenster prüfen und erneut freigeben."
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
        guard !automation(for: project).process.isRunning else { return }
        var settings = rootSettings
        if !settings.hiddenRepositoryPaths.contains(project.directoryPath) { settings.hiddenRepositoryPaths.append(project.directoryPath) }
        guard saveRoots(settings) else { return }
        do {
            try persist(projects.filter { $0.id != project.id })
            automations.removeValue(forKey: project.id)?.shutdown()
            refreshOwnership()
            subscriptions.removeValue(forKey: project.id)
            selectedPath = projects.first?.directoryPath
        } catch { errorMessage = error.localizedDescription }
    }

    func stopAll() { automations.values.forEach { $0.stopManually() } }

    func shutdown() {
        approvalPrompts = []
        scanTask?.cancel()
        refreshTask?.cancel()
        automations.values.forEach { $0.shutdown() }
    }

    private func persist(_ updated: [DevProject]) throws {
        guard storageAvailable else {
            throw NSError(domain: "DevWatch", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Die vorhandene Projektdatei konnte nicht gelesen werden und wird nicht überschrieben. Prüfe ~/Library/Application Support/DevWatch/projects.json und starte die App erneut."])
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
