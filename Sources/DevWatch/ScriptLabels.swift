import DevWatchCore
import SwiftUI

struct ScriptLabels: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let project: DevProject

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.scriptNames[project.id] ?? [], id: \.self) { name in
                    let process = model.scriptProcess(for: project, name: name)
                    let state = process?.state ?? .idle
                    Button { model.toggleScript(for: project, name: name) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: symbol(for: state)).font(.system(size: 8, weight: .bold))
                                .symbolEffect(.pulse, options: .repeating,
                                              isActive: state == .running && name != "dev" && !reduceMotion)
                            Text(name).font(.system(.caption, design: .monospaced).weight(.medium))
                        }
                        .foregroundStyle(color(for: state))
                        .padding(.horizontal, 7).padding(.vertical, 5)
                        .background(color(for: state).opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(name): \(description(for: state))")
                    .help(L10n.text("%@ run %@ · %@\nClick to %@", String(describing: project.executable), String(describing: name), String(describing: description(for: state)), String(describing: process?.isRunning == true ? L10n.text("Stop") : L10n.text("Start"))) +
                          (process?.errorMessage.map { "\n" + $0 } ?? ""))
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func symbol(for state: DevelopmentProcess.State) -> String {
        switch state {
        case .running: return "circle.fill"
        case .succeeded: return "checkmark"
        case .failed: return "xmark"
        case .idle, .stopped: return "play.fill"
        }
    }

    private func color(for state: DevelopmentProcess.State) -> Color {
        switch state {
        case .running, .succeeded: return .green
        case .failed: return .red
        case .idle, .stopped: return .secondary
        }
    }

    private func description(for state: DevelopmentProcess.State) -> String {
        switch state {
        case .idle: return L10n.text("Ready")
        case .running: return L10n.text("Running")
        case .stopped: return L10n.text("Stopped")
        case .succeeded: return L10n.text("Succeeded")
        case .failed: return L10n.text("Failed")
        }
    }
}
