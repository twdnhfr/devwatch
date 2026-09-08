import DevWatchCore
import SwiftUI

struct ScriptLabels: View {
    @ObservedObject var model: AppModel
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
                            Text(name).font(.system(.caption, design: .monospaced).weight(.medium))
                        }
                        .foregroundStyle(color(for: state))
                        .padding(.horizontal, 7).padding(.vertical, 5)
                        .background(color(for: state).opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(name): \(description(for: state))")
                    .help("\(project.executable) run \(name) · \(description(for: state))\nKlicken zum \(process?.isRunning == true ? "Stoppen" : "Starten")" +
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
        case .idle: return "Bereit"
        case .running: return "Läuft"
        case .stopped: return "Gestoppt"
        case .succeeded: return "Erfolgreich"
        case .failed: return "Fehlgeschlagen"
        }
    }
}
