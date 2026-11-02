import SwiftUI

/// The Sources Status column: one chip per analysis step the recording's
/// type expects. Done chips show their count; missing and outdated chips
/// are buttons that run the step (and the missing steps before it).
struct AnalysisStepChips: View {
    /// Passed in, not read from the environment: a recycled Table cell can
    /// be updated after its host environment is gone.
    let store: AppStore
    let video: VideoRecord
    let chips: [AnalysisStepPresentation.Chip]
    let missing: [AnalysisSteps.Step]
    /// Runs the steps a clicked chip resolves to; the owner adds the type
    /// question for untyped files.
    let run: ([AnalysisSteps.Step]) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(chips) { chip in
                if chip.state == .done || chip.state == .running {
                    chipLabel(chip)
                        .help(chip.help)
                        .accessibilityLabel("\(chip.step.title): \(chip.title)")
                } else {
                    Button {
                        run(AnalysisStepPresentation.stepsToRun(for: chip.step, type: video.type, missing: missing))
                    } label: {
                        chipLabel(chip)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isAnalyzing || !video.isPresent)
                    .help(video.isPresent ? chip.help : VideoRecord.notPresentReason)
                    .accessibilityLabel("\(chip.step.title) \(chip.state == .outdated ? "outdated" : "missing"): \(chip.help)")
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private func chipLabel(_ chip: AnalysisStepPresentation.Chip) -> some View {
        HStack(spacing: 3) {
            switch chip.state {
            case .running:
                ProgressView().controlSize(.mini)
            case .done:
                Image(systemName: symbol(chip.step)).foregroundStyle(.secondary)
            case .missing:
                Image(systemName: symbol(chip.step)).foregroundStyle(.tertiary)
            case .outdated:
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
            }
            Text(chip.title)
                .foregroundStyle(chip.state == .missing ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .monospacedDigit()
        }
        .font(.caption)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(chip.state == .outdated ? Color.orange.opacity(0.12) : Color.primary.opacity(0.05),
                    in: Capsule())
        .overlay(Capsule().strokeBorder(chip.state == .missing ? Color.secondary.opacity(0.35) : .clear,
                                        style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
    }

    private func symbol(_ step: AnalysisSteps.Step) -> String {
        switch step {
        case .people: "person.2.fill"
        case .transcript: "text.quote"
        case .speakerNames: "person.wave.2"
        case .scenes: "film.stack"
        case .exchanges: "bubble.left.and.bubble.right"
        case .fightScore: "figure.boxing"
        }
    }
}
