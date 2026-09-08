import AppKit
import SwiftUI

@main
struct DevWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("DevWatch", id: "projects") {
            ProjectsView(model: model)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 920, height: 620)

        MenuBarExtra("DevWatch", systemImage: "terminal") {
            MenuContent(model: model)
                .onAppear { delegate.model = model }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.runningCount > 0 else { return .terminateNow }
        model.stopAll()
        // Keep the run loop alive until the process manager's bounded shutdown completes.
        Task { @MainActor in
            while model.runningCount > 0 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("\(model.runningCount) Prozesse laufen")
        Divider()
        Button("Projekte öffnen …") {
            openWindow(id: "projects")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")
        Button("Alle Prozesse stoppen") { model.stopAll() }
            .disabled(model.runningCount == 0)
        Divider()
        Button("DevWatch beenden") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
