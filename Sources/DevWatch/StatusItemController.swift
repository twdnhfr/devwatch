import AppKit
import Combine
import DevWatchCore
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var subscription: AnyCancellable?
    private var appearanceObservation: NSKeyValueObservation?
    private var knownPromptIDs = Set<UUID>()
    private var visiblePromptID: UUID?
    private var shuttingDown = false

    init(model: AppModel) {
        self.model = model
        super.init()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.delegate = self
        let content = NSHostingController(rootView: StatusPopoverView(model: model))
        content.sizingOptions = [.preferredContentSize]
        popover.contentViewController = content
        subscription = model.objectWillChange.sink { [weak self] _ in
            // ObservableObject publishes before its properties have been updated.
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
        if let button = item.button {
            appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { [weak self] in self?.refresh() }
            }
        }
        refresh()
    }

    func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        subscription?.cancel()
        subscription = nil
        appearanceObservation?.invalidate()
        appearanceObservation = nil
        popover.close()
        popover.contentViewController = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard !shuttingDown, let button = statusItem?.button else { return }
        visiblePromptID = model.approvalPrompts.first?.id
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Deliberately leave the user's active application in the foreground.
    }

    private func refresh() {
        guard !shuttingDown, let button = statusItem?.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        button.image = MenuBarIcon.make(running: model.runningCount > 0, scanning: model.isScanning, dark: dark)
        let status = model.runningCount > 0
            ? "\(model.runningCount) Entwicklungsprozesse laufen"
            : (model.isScanning ? "Git-Projekte werden gesucht" : "Keine Entwicklungsprozesse aktiv")
        let promptHint = model.approvalPrompts.isEmpty ? "" : " · Freigabe wartet"
        button.toolTip = "DevWatch: \(status)\(promptHint)"
        button.setAccessibilityLabel("DevWatch: \(status)\(promptHint)")

        let ids = Set(model.approvalPrompts.map(\.id))
        let newIDs = ids.subtracting(knownPromptIDs)
        knownPromptIDs = ids
        if popover.isShown {
            visiblePromptID = model.approvalPrompts.first?.id
        } else if !newIDs.isEmpty {
            showPopover()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard !shuttingDown else { return }
        // Closing outside the popover declines only the card actually shown.
        // Existing queued cards remain available on the next manual opening and
        // are already known, so closing cannot immediately reopen the popover.
        let dismissedID = visiblePromptID
        visiblePromptID = nil
        knownPromptIDs = Set(model.approvalPrompts.map(\.id))
        if let prompt = model.approvalPrompts.first(where: { $0.id == dismissedID }) {
            model.dismissActivity(prompt)
        }
    }
}

private struct StatusPopoverView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("DevWatch").font(.headline)
                Spacer()
                if model.isScanning { ProgressView().controlSize(.small) }
                Label("\(model.runningCount) aktiv", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(model.runningCount > 0 ? Color.green : Color.secondary)
            }
            if let prompt = model.approvalPrompts.first {
                ActivityApprovalCard(model: model, prompt: prompt)
                    .id(prompt.id)
            } else if model.runningProjects.isEmpty {
                Text(model.isScanning ? "Projekte werden gesucht …" : "Wartet auf Dateiänderungen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !model.runningProjects.isEmpty {
                ViewThatFits(in: .vertical) {
                    runningProjectList
                    ScrollView { runningProjectList }.frame(height: 150)
                }
                .frame(maxHeight: 150)
            }
            Divider()
            HStack {
                Button("Projekte …") { model.openProjectsWindow?() }
                Spacer()
                if model.approvalPrompts.count > 1 {
                    Text("\(model.approvalPrompts.count - 1) weitere")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Menu {
                    if model.runningCount > 0 {
                        Button("Alle stoppen") { model.stopAll() }
                        Divider()
                    }
                    Button("Beenden") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis")
                        .accessibilityLabel("Weitere Aktionen")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(14)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var runningProjectList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.runningProjects) { project in
                Button {
                    model.selectedPath = project.directoryPath
                    model.openProjectsWindow?()
                } label: {
                    Label(project.name, systemImage: "circle.fill")
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .labelStyle(RunningProjectLabelStyle())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(project.directoryPath)
            }
        }
    }
}

private struct RunningProjectLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.font(.system(size: 7)).foregroundStyle(.green)
            configuration.title.lineLimit(1).truncationMode(.middle)
        }
    }
}

private struct ActivityApprovalCard: View {
    @ObservedObject var model: AppModel
    let prompt: ActivityApprovalPrompt
    @State private var detailsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(prompt.project.name)
                .font(.title3.bold())
                .lineLimit(2)
            Text(([prompt.project.executable] + prompt.project.arguments).joined(separator: " "))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
            Text("Änderung erkannt. Freigeben startet jetzt.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Details", isExpanded: $detailsExpanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(prompt.project.directoryPath)
                            .foregroundStyle(.secondary)
                        Text("Geänderte Dateien").bold()
                        Text(prompt.changedFiles.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                        Text("Befehl und Scripts").bold()
                        Text(([prompt.project.executable] + prompt.project.arguments).joined(separator: " ") + "\n" + prompt.script)
                            .font(.system(.caption, design: .monospaced))
                    }
                    .font(.caption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
                .frame(height: 140)
            }
            .font(.caption)
            HStack {
                Button("Später") { model.dismissActivity(prompt) }
                Spacer()
                Button("Autostart freigeben …") { model.approveActivity(prompt) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
