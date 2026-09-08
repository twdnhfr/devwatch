import AppKit
import DevWatchCore
import SwiftUI

struct ProjectsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedID) {
                Section("PROJEKTE") {
                    ForEach(model.projects) { project in
                        Label(project.name, systemImage: "folder")
                            .tag(project.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 230)
            .safeAreaInset(edge: .bottom) {
                Button(action: model.addProject) {
                    Label("Projekt hinzufügen", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .padding(12)
            }
        } detail: {
            if let project = model.projects.first(where: { $0.id == model.selectedID }) {
                ProjectDetail(project: project, automation: model.automation(for: project), process: model.automation(for: project).process, model: model)
                    .id(project.id)
            } else {
                ContentUnavailableView {
                    Label("Dein nächstes Projekt", systemImage: "terminal")
                } description: {
                    Text("Füge ein Webprojekt hinzu und starte dessen Entwicklungsserver direkt hier.")
                } actions: {
                    Button("Projekt auswählen …", action: model.addProject)
                        .buttonStyle(.borderedProminent)
                }
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
                Button("Projekt entfernen …", role: .destructive) { showRemoveConfirmation = true }
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
        .confirmationDialog("Projekt aus DevWatch entfernen? Die Dateien bleiben erhalten.",
                            isPresented: $showRemoveConfirmation) {
            Button("Entfernen", role: .destructive) { model.remove(project) }
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
