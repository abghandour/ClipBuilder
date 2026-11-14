import SwiftUI

/// Two buttons in one shape. The label runs every missing analysis step;
/// the number on the right is how many are missing and opens the list, where
/// one step can be run on its own.
struct AnalyzeStepsButton: View {
    struct Item: Identifiable {
        var step: AnalysisSteps.Step
        /// Files missing this step; nil beside a single file's button.
        var files: Int?
        var id: AnalysisSteps.Step { step }
    }

    var title: String
    /// The number on the right: the missing steps this button would run.
    var count: Int
    var items: [Item]
    var help: String
    var runAll: () -> Void
    var run: (AnalysisSteps.Step) -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 1) {
            Button(action: runAll) {
                Text(title).lineLimit(1).fixedSize()
                    .padding(.leading, 12).padding(.trailing, 10).frame(height: 24)
                    .background(Color.accentColor, in: UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 6))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)

            Menu {
                Section("Missing steps") {
                    ForEach(items) { item in
                        Button(item.files.map { "\(item.step.title) (\($0) file\($0 == 1 ? "" : "s"))" } ?? item.step.title) {
                            run(item.step)
                        }
                        .help(item.step.detail)
                    }
                }
            } label: {
                Text("\(count)").monospacedDigit().fontWeight(.semibold).lineLimit(1).fixedSize()
                    .padding(.horizontal, 9).frame(minWidth: 26).frame(height: 24)
                    .background(Color.accentColor.opacity(0.78),
                                in: UnevenRoundedRectangle(bottomTrailingRadius: 6, topTrailingRadius: 6))
                    .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .fixedSize()
            .help("\(count) missing step\(count == 1 ? "" : "s"): choose one to run only that step")
            .accessibilityLabel("\(count) missing step\(count == 1 ? "" : "s")")
        }
        .foregroundStyle(.white)
        .opacity(isEnabled ? 1 : 0.45)
    }
}
