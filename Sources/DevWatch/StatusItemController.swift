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
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    init(model: AppModel) {
        self.model = model
        super.init()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(handleClick)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
        removeClickMonitors()
        popover.close()
        popover.contentViewController = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    @objc private func handleClick() {
        if NSApp.currentEvent?.type == .rightMouseUp ||
            NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showContextMenu()
            return
        }
        togglePopover()
    }

    private func showContextMenu() {
        guard let button = statusItem?.button else { return }
        popover.performClose(nil)
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if let update = model.updates.available {
            add(L10n.text("Download version %@ …", String(describing: update.displayVersion)), #selector(openUpdate))
            menu.addItem(.separator())
        }
        add(L10n.text("Projects …"), #selector(openProjects))
        add(L10n.text("Settings …"), #selector(openFolders))
        if model.runningCount > 0 {
            menu.addItem(.separator())
            add(L10n.text("Stop all"), #selector(stopAll))
        }
        menu.addItem(.separator())
        add(L10n.text("Quit DevWatch"), #selector(quit))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }

    @objc private func openProjects() { model.openProjectsWindow?() }
    @objc private func openFolders() {
        model.openProjectsWindow?()
        model.showFolders = true
    }
    @objc private func stopAll() { model.stopAll() }
    @objc private func openUpdate() {
        guard let url = model.updates.available?.pageURL else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard !shuttingDown, let button = statusItem?.button else { return }
        model.refreshScripts()
        visiblePromptID = model.approvalPrompts.first?.id
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installClickMonitors()
        // Deliberately leave the user's active application in the foreground.
    }

    private func installClickMonitors() {
        removeClickMonitors()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // A non-activating popover may not receive AppKit's usual transient dismissal.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            self?.popover.performClose(nil)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            guard let self, let window = event.window else { return event }
            if window == self.statusItem?.button?.window { return event }
            var ancestor: NSWindow? = window
            while let current = ancestor {
                if current == self.popover.contentViewController?.view.window { return event }
                ancestor = current.parent
            }
            // Preserve interactions with the popover's native action menu.
            if window.level == .popUpMenu { return event }
            self.popover.performClose(nil)
            return event
        }
    }

    private func removeClickMonitors() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        globalClickMonitor = nil
        localClickMonitor = nil
    }

    private func refresh() {
        guard !shuttingDown, let button = statusItem?.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        button.image = MenuBarIcon.make(running: model.runningCount > 0, scanning: model.isScanning, dark: dark)
        let status = model.runningCount > 0
            ? L10n.text("Running development processes: %@", String(describing: model.runningCount))
            : (model.isScanning ? L10n.text("Scanning for Git projects") : L10n.text("No development processes running"))
        let promptHint = model.approvalPrompts.isEmpty ? "" : L10n.text(" · Approval pending")
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
        removeClickMonitors()
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
                Label(L10n.text("Active: %@", String(describing: model.runningCount)), systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(model.runningCount > 0 ? Color.green : Color.secondary)
            }
            if let prompt = model.approvalPrompts.first {
                ActivityApprovalCard(model: model, prompt: prompt)
                    .id(prompt.id)
            } else if model.scriptProjects.isEmpty {
                Text(model.isScanning ? L10n.text("Scanning for projects …") : L10n.text("Waiting for file changes."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !model.scriptProjects.isEmpty {
                ViewThatFits(in: .vertical) {
                    runningProjectList
                    ScrollView { runningProjectList }.frame(height: 150)
                }
                .frame(maxHeight: 150)
            }
            if model.approvalPrompts.count > 1 {
                Text(L10n.text("More: %@", String(describing: model.approvalPrompts.count - 1)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var runningProjectList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.scriptProjects) { project in
                HStack(spacing: 10) {
                    Button {
                        model.selectedPath = project.directoryPath
                        model.openProjectsWindow?()
                    } label: {
                        Text(project.name).font(.callout.weight(.medium))
                            .lineLimit(1).truncationMode(.middle)
                            .frame(width: 125, alignment: .leading)
                    }
                    .buttonStyle(.plain).help(project.directoryPath)
                    ScriptLabels(model: model, project: project)
                }
            }
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
            Text(L10n.text("Change detected. Approving starts the process now."))
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup(L10n.text("Details"), isExpanded: $detailsExpanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(prompt.project.directoryPath)
                            .foregroundStyle(.secondary)
                        Text(L10n.text("Changed files")).bold()
                        Text(prompt.changedFiles.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                        Text(L10n.text("Command and scripts")).bold()
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
                Button(L10n.text("Later")) { model.dismissActivity(prompt) }
                Spacer()
                Button(L10n.text("Approve autostart …")) { model.approveActivity(prompt) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
