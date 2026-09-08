import AppKit
import DevWatchCore
import SwiftUI

struct ProjectsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedPath) {
                Section("STAMMORDNER") {
                    ForEach(model.rootSettings.paths, id: \.self) { path in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "folder.badge.gearshape")
                            Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .help(path)
                        .contextMenu {
                            Button("Stammordner entfernen (Projekte behalten)") { model.removeRoot(path) }
                        }
                    }
                    Button(action: model.addRootFolder) {
                        Label("Stammordner hinzufügen …", systemImage: "plus")
                    }.buttonStyle(.plain)
                }
                Section("PROJEKTE · \(model.listedRepositories.count)") {
                    ForEach(model.listedRepositories) { repository in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(repository.name, systemImage: repository.project == nil ? "folder.badge.questionmark" : "folder")
                            Text(repository.project.map { "\($0.executable) run dev" } ?? "Kein dev-Befehl")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .tag(repository.directoryPath)
                        .help(repository.directoryPath)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button(action: model.rescan) {
                        Label(model.isScanning ? "Suche läuft …" : "Jetzt aktualisieren", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }.disabled(model.isScanning)
                    Menu("Weitere Aktionen") {
                        Button("Einzelnes Projekt hinzufügen …", action: model.addProject)
                        if !model.rootSettings.hiddenRepositoryPaths.isEmpty {
                            Button("Ausgeblendete Projekte wieder anzeigen", action: model.showHiddenRepositories)
                        }
                    }
                    if !model.scanWarnings.isEmpty {
                        Text(model.scanWarnings.joined(separator: "\n"))
                            .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }.padding(12).background(.bar)
            }
        } detail: {
            if let repository = model.listedRepositories.first(where: { $0.directoryPath == model.selectedPath }),
               let issue = repository.issue {
                VStack(alignment: .leading, spacing: 16) {
                    Label(repository.name, systemImage: "folder").font(.largeTitle.bold())
                    Text(repository.directoryPath).foregroundStyle(.secondary).textSelection(.enabled)
                    Label("Git-Projekt erkannt", systemImage: "checkmark.circle")
                    Text(issue).textSelection(.enabled)
                    Text("Das Repository bleibt sichtbar. Sobald ein gültiges dev-Script vorhanden ist, erscheint beim nächsten Scan der Startbefehl.")
                        .foregroundStyle(.secondary)
                    Button("Erneut prüfen", action: model.rescan).disabled(model.isScanning)
                    if let saved = model.projects.first(where: { $0.directoryPath == repository.directoryPath }),
                       model.automation(for: saved).process.isRunning {
                        Button("Laufenden Prozess stoppen") { model.automation(for: saved).stopManually() }
                    }
                    Spacer()
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            } else if let project = model.projects.first(where: { $0.directoryPath == model.selectedPath }) {
                ProjectDetail(project: project, automation: model.automation(for: project), process: model.automation(for: project).process, model: model)
                    .id(project.id)
            } else {
                ContentUnavailableView {
                    Label(model.isScanning ? "Git-Projekte werden gesucht" : "Deine Projekte, automatisch", systemImage: "folder.badge.gearshape")
                } description: {
                    Text("Wähle einen Stammordner wie ~/gits. DevWatch findet darin Git-Repositories und Worktrees – auch ohne Frontend-Script.")
                } actions: {
                    Button("Stammordner auswählen …", action: model.addRootFolder)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .task { model.activateDiscovery() }
        .onAppear {
            model.openProjectsWindow = {
                openWindow(id: "projects")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .alert("Aktion nicht möglich", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

private struct ProjectDetail: View {
    let project: DevProject
    @ObservedObject var automation: ProjectAutomation
    @ObservedObject var process: DevelopmentProcess
    @ObservedObject var model: AppModel
    @State private var executable = ""
    @State private var showRemoveConfirmation = false
    private struct ApprovalRequest: Identifiable {
        let id = UUID()
        let approval: AutostartApproval
        let script: String
    }
    @State private var approvalRequest: ApprovalRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(project.name).font(.largeTitle.bold())
                    Text(project.directoryPath)
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Label(process.isRunning ? "Prozess läuft" : "Gestoppt",
                      systemImage: process.isRunning ? "circle.fill" : "circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(process.isRunning ? Color.green : Color.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Entwicklungsbefehl").font(.headline)
                        Spacer()
                        Text(project.autostartEnabled ? "Autostart aktiv" : "Manueller Start").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        TextField("Programm oder absoluter Pfad", text: $executable)
                            .textFieldStyle(.roundedBorder)
                            .disabled(process.isRunning)
                            .onSubmit(saveExecutable)
                        Text(project.arguments.joined(separator: " "))
                            .font(.system(.body, design: .monospaced))
                        Button("Speichern", action: saveExecutable)
                            .disabled(process.isRunning || executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || executable == project.executable)
                    }
                    Text(automation.status)
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button {
                            automation.startManually()
                        } label: { Label("Starten", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent)
                            .disabled(process.isRunning || executable != project.executable)
                        Button { automation.stopManually() } label: { Label("Stoppen", systemImage: "stop.fill") }
                            .disabled(!process.isRunning)
                        Spacer()
                        Button("Im Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.directoryPath)
                        }
                    }
                    Divider()
                    HStack {
                        if project.autostartEnabled {
                            Button("Autostart pausieren") { automation.pause() }
                        } else {
                            Button("Autostart freigeben …", action: prepareApproval)
                                .disabled(executable != project.executable)
                        }
                        Spacer()
                        Text("Auslöser: Dateiänderung").font(.caption).foregroundStyle(.secondary)
                    }
                    if let change = automation.lastChange {
                        Text("Letzte Änderung: \(change)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.padding(8)
            }

            if let error = process.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }

            HStack {
                Text("Prozessausgabe").font(.headline)
                Spacer()
                Text("Erreichbarkeit noch nicht geprüft").font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ScrollView([.vertical, .horizontal]) {
                    Text(process.log.isEmpty ? "Noch keine Ausgabe. Starte den Entwicklungsserver, um seine Logs zu sehen." : process.log)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(process.log.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Projekt ausblenden …", role: .destructive) { showRemoveConfirmation = true }
                    .disabled(process.isRunning)
            }
        }
        .padding(24)
        .onAppear { executable = project.executable }
        .sheet(item: $approvalRequest) { request in
            VStack(alignment: .leading, spacing: 16) {
                Text("Autostart freigeben").font(.title2.bold())
                Text("Bei relevanten Dateiänderungen führt DevWatch diesen Befehl in \(project.name) aus. Die Freigabe startet noch keinen Prozess.")
                    .fixedSize(horizontal: false, vertical: true)
                Text(([project.executable] + project.arguments).joined(separator: " "))
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                ScrollView {
                    Text(request.script).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 120)
                Text("Änderungen an package.json oder am Befehl erfordern eine neue Freigabe. Stoppen pausiert den Autostart.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Abbrechen") { approvalRequest = nil }
                    Button("Freigeben") {
                        automation.enable(approval: request.approval)
                        approvalRequest = nil
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 490)
        }
        .confirmationDialog("Projekt ausblenden? Die Dateien bleiben erhalten. Du kannst ausgeblendete Projekte über „Weitere Aktionen“ wieder anzeigen.",
                            isPresented: $showRemoveConfirmation) {
            Button("Ausblenden", role: .destructive) { model.remove(project) }
        }
    }

    private func prepareApproval() {
        do {
            let approval = try AutostartApproval.capture(project: project)
            let script = try AutostartApproval.scriptDescription(project: project)
            approvalRequest = ApprovalRequest(approval: approval, script: script)
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func saveExecutable() {
        let trimmed = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !process.isRunning else { return }
        var updated = project
        updated.executable = trimmed
        model.update(updated)
        executable = trimmed
    }
}
