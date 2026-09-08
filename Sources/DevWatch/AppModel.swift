import AppKit
import Combine
import DevWatchCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var projects: [DevProject] = []
    @Published var selectedID: UUID?
    @Published var errorMessage: String?
    private var processes: [UUID: DevelopmentProcess] = [:]
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
        } catch {
            storageAvailable = false
            errorMessage = "Projektliste konnte nicht geladen werden: \(error.localizedDescription)"
        }
    }

    var runningCount: Int { processes.values.filter(\.isRunning).count }

    func process(for project: DevProject) -> DevelopmentProcess {
        if let process = processes[project.id] { return process }
        let process = DevelopmentProcess()
        processes[project.id] = process
        subscriptions[project.id] = process.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return process
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
        } catch { errorMessage = error.localizedDescription }
    }

    func update(_ project: DevProject) {
        var updated = projects
        guard let index = updated.firstIndex(where: { $0.id == project.id }) else { return }
        updated[index] = project
        do { try persist(updated) } catch { errorMessage = error.localizedDescription }
    }

    func remove(_ project: DevProject) {
        guard !process(for: project).isRunning else { return }
        do {
            try persist(projects.filter { $0.id != project.id })
            processes.removeValue(forKey: project.id)
            subscriptions.removeValue(forKey: project.id)
            selectedID = projects.first?.id
        } catch { errorMessage = error.localizedDescription }
    }

    func stopAll() { processes.values.forEach { $0.stop() } }

    private func persist(_ updated: [DevProject]) throws {
        guard storageAvailable else {
            throw NSError(domain: "DevWatch", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Die vorhandene Projektdatei konnte nicht gelesen werden und wird nicht überschrieben. Prüfe ~/Library/Application Support/DevWatch/projects.json und starte die App erneut."])
        }
        try storage.save(updated)
        projects = updated
    }
}
