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
                ProjectDetail(project: project, process: model.process(for: project), model: model)
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
    @ObservedObject var process: DevelopmentProcess
    @ObservedObject var model: AppModel
    @State private var executable = ""
    @State private var showRemoveConfirmation = false

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
                        Text("Manueller Start").font(.caption).foregroundStyle(.secondary)
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
                    Text("Prüfe das dev-Script deiner package.json vor dem Start. Dateibeobachtung und Autostart folgen im nächsten Schritt.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button {
                            process.start(directory: URL(fileURLWithPath: project.directoryPath),
                                          executable: project.executable, arguments: project.arguments)
                        } label: { Label("Starten", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent)
                            .disabled(process.isRunning || executable != project.executable)
                        Button { process.stop() } label: { Label("Stoppen", systemImage: "stop.fill") }
                            .disabled(!process.isRunning)
                        Spacer()
                        Button("Im Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.directoryPath)
                        }
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
        .confirmationDialog("Projekt aus DevWatch entfernen? Die Dateien bleiben erhalten.",
                            isPresented: $showRemoveConfirmation) {
            Button("Entfernen", role: .destructive) { model.remove(project) }
        }
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
