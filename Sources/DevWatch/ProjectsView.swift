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
            .searchable(text: $search, placement: .sidebar, prompt: L10n.text("Search projects"))
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button { model.showFolders = true } label: {
                        Image(systemName: "folder.badge.gearshape")
                    }.help(L10n.text("Settings")).accessibilityLabel(L10n.text("Settings"))
                    Text(L10n.text("Projects: %@", String(describing: visibleRepositories.count)))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.isScanning {
                        ProgressView().controlSize(.small).accessibilityLabel(L10n.text("Scanning for projects"))
                    } else {
                        Button(action: model.rescan) { Image(systemName: "arrow.clockwise") }
                            .help(L10n.text("Refresh projects")).accessibilityLabel(L10n.text("Refresh projects"))
                    }
                }.buttonStyle(.borderless).padding(12).background(.bar)
            }
        } detail: {
            if let repository = model.listedRepositories.first(where: { $0.directoryPath == model.selectedPath }),
               let issue = repository.issue {
                VStack(alignment: .leading, spacing: 16) {
                    Text(repository.name).font(.title.bold())
                    Text(L10n.text("No development command detected.")).foregroundStyle(.secondary)
                    DisclosureGroup(L10n.text("Details")) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(repository.directoryPath).textSelection(.enabled)
                            Text(issue).textSelection(.enabled)
                            Button(L10n.text("Check again"), action: model.rescan).disabled(model.isScanning)
                        }.font(.callout).padding(.top, 10)
                    }
                    if let saved = model.projects.first(where: { $0.directoryPath == repository.directoryPath }),
                       model.automation(for: saved).process.isRunning {
                        Button(L10n.text("Stop")) { model.automation(for: saved).stopManually() }
                    }
                    Spacer()
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
            } else if let project = model.projects.first(where: { $0.directoryPath == model.selectedPath }) {
                ProjectDetail(project: project, automation: model.automation(for: project),
                              process: model.automation(for: project).process, model: model)
                    .id(project.id)
            } else {
                ContentUnavailableView {
                    Label(L10n.text("Your projects"), systemImage: "folder")
                } description: {
                    Text(model.rootSettings.paths.isEmpty ? L10n.text("Select your Git folder to get started.") : L10n.text("Select a project on the left."))
                } actions: {
                    if model.rootSettings.paths.isEmpty {
                        Button(L10n.text("Select folder …"), action: model.addRootFolder).buttonStyle(.borderedProminent)
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
        .alert(L10n.text("Action unavailable"), isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button(L10n.text("OK")) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var foldersSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("Settings")).font(.title2.bold())
            Toggle(L10n.text("Launch at login"), isOn: Binding(
                get: { loginItem.isRegistered },
                set: { loginItem.setEnabled($0) }
            ))
            if loginItem.requiresApproval {
                Text(L10n.text("Please allow launch at login in macOS System Settings."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L10n.text("Open Login Items"), action: loginItem.openSystemSettings)
            }
            if let error = loginItem.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            Divider()
            HStack(spacing: 8) {
                Text("DevWatch \(AppModel.bundleVersion)").font(.callout)
                Spacer()
                // Ohne Fund bleibt die Zeile stumm: eine gescheiterte Prüfung
                // ist von "keine neue Version" nicht zu unterscheiden.
                if let update = model.updates.available {
                    Link(L10n.text("Download version %@ …", String(describing: update.displayVersion)), destination: update.pageURL)
                        .font(.callout)
                }
            }
            Divider()
            HStack {
                Text(L10n.text("Project folders")).font(.headline)
                Spacer()
                Button(action: model.addRootFolder) {
                    Image(systemName: "plus")
                }
                .help(L10n.text("Add folder"))
                .accessibilityLabel(L10n.text("Add folder"))
            }
            VStack(spacing: 0) {
                if model.rootSettings.paths.isEmpty {
                    Text(L10n.text("Use + to add a folder"))
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
                                    .help(L10n.text("Remove folder from the list; keep its projects"))
                                    .accessibilityLabel(L10n.text("Remove folder %@", String(describing: path)))
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
            Text(L10n.text("Git projects inside these folders are discovered automatically."))
                .font(.caption).foregroundStyle(.secondary)
            if !model.scanWarnings.isEmpty {
                ScrollView { Text(model.scanWarnings.joined(separator: "\n")).font(.caption).foregroundStyle(.orange) }
                    .frame(height: 80)
            }
            HStack {
                Spacer()
                Button(L10n.text("Done")) { model.showFolders = false }.keyboardShortcut(.defaultAction)
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
                    Label(process.isRunning ? L10n.text("Process running") : (project.autostartEnabled ? L10n.text("Waiting for a file change") : L10n.text("Stopped")),
                          systemImage: "circle.fill")
                        .font(.callout)
                        .foregroundStyle(process.isRunning ? Color.green : Color.secondary)
                }
                HStack(spacing: 18) {
                    Toggle(L10n.text("Autostart"), isOn: Binding(
                        get: { project.autostartEnabled },
                        set: { if $0 { prepareApproval() } else { automation.pause() } }
                    )).toggleStyle(.switch).fixedSize()
                        .disabled(executable != project.executable)
                    Spacer()
                    Button(process.isRunning ? L10n.text("Stop") : L10n.text("Start")) {
                        if process.isRunning { automation.stopManually() }
                        else { automation.startManually() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!process.isRunning && executable != project.executable)
                }
                if let error = process.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                } else if automation.needsAttention {
                    Text(automation.status).font(.callout).foregroundStyle(.orange)
                }
                Divider()
                DisclosureGroup(L10n.text("Details & Logs"), isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(project.directoryPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            TextField(L10n.text("Executable or path"), text: $executable)
                                .textFieldStyle(.roundedBorder).disabled(process.isRunning).onSubmit(saveExecutable)
                            Text(project.arguments.joined(separator: " ")).font(.system(.caption, design: .monospaced))
                            Button(L10n.text("Save"), action: saveExecutable)
                                .disabled(process.isRunning || executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || executable == project.executable)
                        }
                        Text(automation.status).font(.caption).foregroundStyle(.secondary)
                        if let deadline = automation.idleDeadline {
                            Text(L10n.text("Automatic stop at %@ — after 30 minutes without file changes.", String(describing: deadline.formatted(date: .omitted, time: .shortened))))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let change = automation.lastChange {
                            Text(L10n.text("Last change: %@", String(describing: change))).font(.caption).textSelection(.enabled)
                        }
                        ScrollView([.vertical, .horizontal]) {
                            Text(process.log.isEmpty ? L10n.text("No output yet.") : process.log)
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .padding(10).frame(minWidth: 330, minHeight: 150, alignment: .topLeading)
                        }
                        .frame(height: 170)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        HStack {
                            Button(L10n.text("Show in Finder")) {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.directoryPath)
                            }
                            Spacer()
                            Button(L10n.text("Hide …"), role: .destructive) { showRemoveConfirmation = true }
                                .disabled(process.isRunning)
                        }
                    }.padding(.top, 14)
                }
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { executable = project.executable }
        .sheet(item: $approvalRequest) { request in
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.text("Enable autostart for %@?", String(describing: project.name))).font(.title2.bold())
                Text(L10n.text("Starts on the next file change.")).foregroundStyle(.secondary)
                Text(([project.executable] + project.arguments).joined(separator: " "))
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                ScrollView {
                    Text(request.script).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 70)
                HStack {
                    Spacer()
                    Button(L10n.text("Cancel")) { approvalRequest = nil }
                    Button(L10n.text("Approve")) {
                        automation.enable(approval: request.approval)
                        approvalRequest = nil
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 400)
        }
        .confirmationDialog(L10n.text("Hide project? Its files will be kept."), isPresented: $showRemoveConfirmation) {
            Button(L10n.text("Hide"), role: .destructive) { model.remove(project) }
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
