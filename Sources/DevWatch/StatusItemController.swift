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
        popover.contentViewController = NSHostingController(rootView: StatusPopoverView(model: model))
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
        popover.contentSize = NSSize(width: 440, height: model.approvalPrompts.isEmpty ? 225 : 570)

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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("DevWatch").font(.headline)
                Spacer()
                if model.isScanning { ProgressView().controlSize(.small) }
                Label("\(model.runningCount) aktiv", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(model.runningCount > 0 ? Color.green : Color.secondary)
            }
            if let prompt = model.approvalPrompts.first {
                approvalCard(prompt)
            } else {
                Text("DevWatch beobachtet deine Projekte und fragt bei der ersten relevanten Änderung nach der Freigabe.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Projekte öffnen …") { model.openProjectsWindow?() }
                Spacer()
                Button("Alle stoppen") { model.stopAll() }
                    .disabled(model.runningCount == 0)
            }
            HStack {
                if model.approvalPrompts.count > 1 {
                    Text("\(model.approvalPrompts.count - 1) weitere Freigaben warten")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("DevWatch beenden") { NSApp.terminate(nil) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    private func approvalCard(_ prompt: ActivityApprovalPrompt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dateiänderung erkannt").font(.subheadline).foregroundStyle(.secondary)
            Text(prompt.project.name).font(.title3.bold())
            Text(prompt.project.directoryPath)
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Geänderte Dateien").font(.caption.bold())
                    Text(prompt.changedFiles.prefix(4).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    if prompt.changedFiles.count > 4 {
                        Text("… und \(prompt.changedFiles.count - 4) weitere")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Auszuführender Befehl").font(.caption.bold())
                    Text(([prompt.project.executable] + prompt.project.arguments).joined(separator: " "))
                        .font(.system(.callout, design: .monospaced).bold())
                        .textSelection(.enabled)
                    Text(prompt.script)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 160)

            Text("Freigeben startet den Entwicklungsserver jetzt.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Später") { model.dismissActivity(prompt) }
                Spacer()
                Button("Autostart freigeben …") { model.approveActivity(prompt) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
