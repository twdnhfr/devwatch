import AppKit
import Combine
import DevWatchCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var projects: [DevProject] = []
    @Published var selectedID: UUID?
    @Published var errorMessage: String?
    private var automations: [UUID: ProjectAutomation] = [:]
    private var subscriptions: [UUID: AnyCancellable] = [:]
    private let storage: ProjectStorage
    private var storageAvailable = true

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevWatch", isDirectory: true)
        storage = ProjectStorage(fileURL: directory.appendingPathComponent("projects.json"))
        do {
            projects = try storage.load()
            selectedID = projects.first?.id
            let restored = projects
            for project in restored { _ = automation(for: project) }
            refreshOwnership()
            automations.values.forEach { $0.beginObserving() }
        } catch {
            storageAvailable = false
            errorMessage = "Projektliste konnte nicht geladen werden: \(error.localizedDescription)"
        }
    }

    var runningCount: Int { automations.values.filter { $0.process.isRunning }.count }

    func automation(for project: DevProject) -> ProjectAutomation {
        if let existing = automations[project.id] { return existing }
        let automation = ProjectAutomation(project: project) { [weak self] updated in
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
            automation.excludedDirectories = projects.compactMap {
                $0.directoryPath.hasPrefix(prefix) ? String($0.directoryPath.dropFirst(prefix.count)) : nil
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
            if let existing = projects.first(where: { $0.directoryPath == candidate.directoryPath }) {
                selectedID = existing.id
                return
            }
            var updated = projects
            updated.append(candidate)
            try persist(updated)
            selectedID = candidate.id
            _ = automation(for: candidate)
            refreshOwnership()
        } catch { errorMessage = error.localizedDescription }
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
        do {
            try persist(projects.filter { $0.id != project.id })
            automations.removeValue(forKey: project.id)?.shutdown()
            refreshOwnership()
            subscriptions.removeValue(forKey: project.id)
            selectedID = projects.first?.id
        } catch { errorMessage = error.localizedDescription }
    }

    func stopAll() { automations.values.forEach { $0.stopManually() } }

    func shutdown() { automations.values.forEach { $0.shutdown() } }

    private func persist(_ updated: [DevProject]) throws {
        guard storageAvailable else {
            throw NSError(domain: "DevWatch", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Die vorhandene Projektdatei konnte nicht gelesen werden und wird nicht überschrieben. Prüfe ~/Library/Application Support/DevWatch/projects.json und starte die App erneut."])
        }
        try storage.save(updated)
        projects = updated
    }
}
