import AppKit
import SwiftUI

@main
struct DevWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("DevWatch", id: "projects") {
            ProjectsView(model: model)
                .onAppear { delegate.configure(model: model) }
        }
        .defaultSize(width: 920, height: 620)


    }
}

/// A non-template image preserves the badge color in the macOS status bar.
enum MenuBarIcon {
    static func make(running: Bool, scanning: Bool, dark: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            let ink: NSColor = dark ? .white : .black
            ink.setStroke()
            let frame = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 3.5, width: 17, height: 12),
                                     xRadius: 2, yRadius: 2)
            frame.lineWidth = 1.4
            frame.stroke()
            let prompt = NSBezierPath()
            prompt.move(to: NSPoint(x: 5, y: 12))
            prompt.line(to: NSPoint(x: 8, y: 9.5))
            prompt.line(to: NSPoint(x: 5, y: 7))
            prompt.move(to: NSPoint(x: 10, y: 7))
            prompt.line(to: NSPoint(x: 14, y: 7))
            prompt.lineWidth = 1.4
            prompt.lineCapStyle = .round
            prompt.lineJoinStyle = .round
            prompt.stroke()
            if running || scanning {
                // Running takes priority so periodic discovery never hides the green badge.
                let badge = NSBezierPath(ovalIn: NSRect(x: 14.5, y: 0.5, width: 7, height: 7))
                (running ? NSColor.systemGreen : NSColor.systemOrange).setFill()
                badge.fill()
                (dark ? NSColor.black : NSColor.white).setStroke()
                badge.lineWidth = 0.8
                badge.stroke()
            }
            return true
        }
        image.isTemplate = !running && !scanning
        image.accessibilityDescription = "DevWatch"
        return image
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var statusController: StatusItemController?

    func configure(model: AppModel) {
        self.model = model
        if statusController == nil { statusController = StatusItemController(model: model) }
        model.activateDiscovery()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        statusController?.shutdown()
        model.shutdown()
        guard model.runningCount > 0 else { return .terminateNow }
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
