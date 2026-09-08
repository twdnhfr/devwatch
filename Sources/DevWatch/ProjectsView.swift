import AppKit
import DevWatchCore
import SwiftUI

struct ProjectsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    @StateObject private var loginItem = LoginItemSettings()

    private var visibleRepositories: [DiscoveredRepository] {
        model.listedRepositories.filter {
            $0.project != nil && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedPath) {
                ForEach(visibleRepositories) { repository in
                    Text(repository.name)
                        .foregroundStyle(repository.project == nil ? .secondary : .primary)
                        .tag(repository.directoryPath)
                        .help(repository.directoryPath)
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Projekt suchen")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button { model.showFolders = true } label: {
                        Image(systemName: "folder.badge.gearshape")
                    }.help("Einstellungen").accessibilityLabel("Einstellungen")
                    Text("\(visibleRepositories.count) Projekte")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.isScanning {
                        ProgressView().controlSize(.small).accessibilityLabel("Projekte werden gesucht")
                    } else {
                        Button(action: model.rescan) { Image(systemName: "arrow.clockwise") }
                            .help("Projekte aktualisieren").accessibilityLabel("Projekte aktualisieren")
                    }
                }.buttonStyle(.borderless).padding(12).background(.bar)
            }
        } detail: {
            if let repository = model.listedRepositories.first(where: { $0.directoryPath == model.selectedPath }),
               let issue = repository.issue {
                VStack(alignment: .leading, spacing: 16) {
                    Text(repository.name).font(.title.bold())
                    Text("Kein Entwicklungsbefehl erkannt.").foregroundStyle(.secondary)
                    DisclosureGroup("Details") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(repository.directoryPath).textSelection(.enabled)
                            Text(issue).textSelection(.enabled)
                            Button("Erneut prüfen", action: model.rescan).disabled(model.isScanning)
                        }.font(.callout).padding(.top, 10)
                    }
                    if let saved = model.projects.first(where: { $0.directoryPath == repository.directoryPath }),
                       model.automation(for: saved).process.isRunning {
                        Button("Stoppen") { model.automation(for: saved).stopManually() }
                    }
                    Spacer()
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            } else if let project = model.projects.first(where: { $0.directoryPath == model.selectedPath }) {
                ProjectDetail(project: project, automation: model.automation(for: project),
                              process: model.automation(for: project).process, model: model)
                    .id(project.id)
            } else {
                ContentUnavailableView {
                    Label("Deine Projekte", systemImage: "folder")
                } description: {
                    Text(model.rootSettings.paths.isEmpty ? "Wähle einmal deinen Git-Ordner." : "Wähle links ein Projekt aus.")
                } actions: {
                    if model.rootSettings.paths.isEmpty {
                        Button("Ordner auswählen …", action: model.addRootFolder).buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .task { model.activateDiscovery() }
        .onChange(of: visibleRepositories.map(\.directoryPath), initial: true) { _, paths in
            if model.selectedPath.map({ paths.contains($0) }) != true {
                model.selectedPath = paths.first
            }
        }
        .onAppear {
            model.openProjectsWindow = {
                openWindow(id: "projects")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .frame(minWidth: 660, minHeight: 400)
        .sheet(isPresented: $model.showFolders) { foldersSheet }
        .alert("Aktion nicht möglich", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var foldersSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Einstellungen").font(.title2.bold())
            Toggle("Beim Anmelden starten", isOn: Binding(
                get: { loginItem.isRegistered },
                set: { loginItem.setEnabled($0) }
            ))
            if loginItem.requiresApproval {
                Text("Bitte den Autostart in den macOS-Systemeinstellungen erlauben.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Anmeldeobjekte öffnen", action: loginItem.openSystemSettings)
            }
            if let error = loginItem.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            Divider()
            HStack {
                Text("Projektordner").font(.headline)
                Spacer()
                Button(action: model.addRootFolder) {
                    Image(systemName: "plus")
                }
                .help("Ordner hinzufügen")
                .accessibilityLabel("Ordner hinzufügen")
            }
            VStack(spacing: 0) {
                if model.rootSettings.paths.isEmpty {
                    Text("Mit + einen Ordner hinzufügen")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(model.rootSettings.paths, id: \.self) { path in
                                HStack(spacing: 10) {
                                    Image(systemName: "folder").foregroundStyle(.secondary)
                                    Text(path).font(.callout).lineLimit(1)
                                        .truncationMode(.middle).help(path)
                                    Spacer(minLength: 0)
                                    Button { model.removeRoot(path) } label: {
                                        Image(systemName: "minus")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Ordner aus der Liste entfernen; Projekte behalten")
                                    .accessibilityLabel("Ordner \(path) entfernen")
                                }
                                .padding(.horizontal, 12).frame(height: 40)
                                if path != model.rootSettings.paths.last {
                                    Divider().padding(.leading, 12)
                                }
                            }
                        }
                    }
                    .frame(height: min(CGFloat(model.rootSettings.paths.count) * 41, 164))
                }
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            Text("Git-Projekte darin werden automatisch erkannt.")
                .font(.caption).foregroundStyle(.secondary)
            if !model.scanWarnings.isEmpty {
                ScrollView { Text(model.scanWarnings.joined(separator: "\n")).font(.caption).foregroundStyle(.orange) }
                    .frame(height: 80)
            }
            HStack {
                Spacer()
                Button("Fertig") { model.showFolders = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 470)
            .onAppear { loginItem.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                loginItem.refresh()
            }
    }
}

private struct ProjectDetail: View {
    let project: DevProject
    @ObservedObject var automation: ProjectAutomation
    @ObservedObject var process: DevelopmentProcess
    @ObservedObject var model: AppModel
    @State private var executable = ""
    @State private var showDetails = false
    @State private var showRemoveConfirmation = false
    private struct ApprovalRequest: Identifiable {
        let id = UUID()
        let approval: AutostartApproval
        let script: String
    }
    @State private var approvalRequest: ApprovalRequest?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(project.name).font(.title.bold())
                    Text(([project.executable] + project.arguments).joined(separator: " "))
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    ScriptLabels(model: model, project: project)
                    Label(process.isRunning ? "Prozess läuft" : (project.autostartEnabled ? "Wartet auf Dateiänderung" : "Gestoppt"),
                          systemImage: "circle.fill")
                        .font(.callout)
                        .foregroundStyle(process.isRunning ? Color.green : Color.secondary)
                }
                HStack(spacing: 18) {
                    Toggle("Autostart", isOn: Binding(
                        get: { project.autostartEnabled },
                        set: { if $0 { prepareApproval() } else { automation.pause() } }
                    )).toggleStyle(.switch).fixedSize()
                        .disabled(executable != project.executable)
                    Spacer()
                    Button(process.isRunning ? "Stoppen" : "Starten") {
                        if process.isRunning { automation.stopManually() }
                        else { automation.startManually() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!process.isRunning && executable != project.executable)
                }
                if let error = process.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                } else if automation.status.contains("fehlgeschlagen") || automation.status.contains("erneut") || automation.status.contains("verschoben") {
                    Text(automation.status).font(.callout).foregroundStyle(.orange)
                }
                Divider()
                DisclosureGroup("Details & Logs", isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(project.directoryPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            TextField("Programm oder Pfad", text: $executable)
                                .textFieldStyle(.roundedBorder).disabled(process.isRunning).onSubmit(saveExecutable)
                            Text(project.arguments.joined(separator: " ")).font(.system(.caption, design: .monospaced))
                            Button("Speichern", action: saveExecutable)
                                .disabled(process.isRunning || executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || executable == project.executable)
                        }
                        Text(automation.status).font(.caption).foregroundStyle(.secondary)
                        if let deadline = automation.idleDeadline {
                            Text("Automatischer Stopp um \(deadline.formatted(date: .omitted, time: .shortened)) – nach 30 Minuten ohne Dateiänderung.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let change = automation.lastChange {
                            Text("Letzte Änderung: \(change)").font(.caption).textSelection(.enabled)
                        }
                        ScrollView([.vertical, .horizontal]) {
                            Text(process.log.isEmpty ? "Noch keine Ausgabe." : process.log)
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .padding(10).frame(minWidth: 330, minHeight: 150, alignment: .topLeading)
                        }
                        .frame(height: 170)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        HStack {
                            Button("Im Finder") {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.directoryPath)
                            }
                            Spacer()
                            Button("Ausblenden …", role: .destructive) { showRemoveConfirmation = true }
                                .disabled(process.isRunning)
                        }
                    }.padding(.top, 14)
                }
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { executable = project.executable }
        .sheet(item: $approvalRequest) { request in
            VStack(alignment: .leading, spacing: 16) {
                Text("Autostart für \(project.name)?").font(.title2.bold())
                Text("Startet bei der nächsten Dateiänderung.").foregroundStyle(.secondary)
                Text(([project.executable] + project.arguments).joined(separator: " "))
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                ScrollView {
                    Text(request.script).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 70)
                HStack {
                    Spacer()
                    Button("Abbrechen") { approvalRequest = nil }
                    Button("Freigeben") {
                        automation.enable(approval: request.approval)
                        approvalRequest = nil
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 400)
        }
        .confirmationDialog("Projekt ausblenden? Die Dateien bleiben erhalten.", isPresented: $showRemoveConfirmation) {
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
