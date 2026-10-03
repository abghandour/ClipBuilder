import SwiftUI

/// Which automated steps a Wizard Pipeline run executes, in pipeline order.
/// Everything on = "fire and forget": select footage, come back to finished
/// reels.
nonisolated struct PipelineOptions: Sendable {
    var detectPeople = true
    var transcribe = true
    var analyze = true
    var fightScoring = true
    var fightResearch = true
    var proposeNames = false
    var curate = true
    var framing = true
    var generate = true
    var critique = true
    var coverFrame = true

    var anyEnabled: Bool {
        detectPeople || transcribe || analyze || fightScoring || fightResearch
            || proposeNames || curate || framing || generate || coverFrame
    }
}

/// The Wizard Pipeline modal: pick which automated steps run for the selected
/// videos, then fire and forget — the pipeline works through each video in
/// the background (progress bar at the bottom of the window, click it for
/// the log) while the app stays usable.
struct AnalyzeWizardSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let videos: [VideoRecord]

    // Checkbox choices persist between runs.
    @AppStorage("pipeline.detectPeople") private var detectPeople = true
    @AppStorage("pipeline.transcribe") private var transcribe = true
    @AppStorage("pipeline.analyze") private var analyze = true
    @AppStorage("pipeline.fightScoring") private var fightScoring = true
    @AppStorage("pipeline.fightResearch") private var fightResearch = true
    @AppStorage("pipeline.proposeNames") private var proposeNames = false
    @AppStorage("pipeline.curate") private var curate = true
    @AppStorage("pipeline.framing") private var framing = true
    @AppStorage("pipeline.generate") private var generate = true
    @AppStorage("pipeline.critique") private var critique = true
    @AppStorage("pipeline.coverFrame") private var coverFrame = true
    /// The saved Wizard form, read once: it lists the music folder on disk.
    @State private var step1 = WizardStep1Options()
    @State private var step2 = WizardStep2Options()

    private var options: PipelineOptions {
        PipelineOptions(detectPeople: detectPeople, transcribe: transcribe,
                        analyze: analyze, fightScoring: fightScoring,
                        fightResearch: fightResearch, proposeNames: proposeNames,
                        curate: curate, framing: framing,
                        generate: generate, critique: critique,
                        coverFrame: coverFrame)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wizard Pipeline")
                .font(.title3.bold())
            Text("Runs everything the app can do for the \(videos.count) selected video\(videos.count == 1 ? "" : "s") — start to finished reels — in the background. Watch or cancel from the bar at the bottom of the window; keep using the app meanwhile.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(videos) { video in
                            Text(video.filename)
                                .font(.caption)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 76)
            } label: {
                Text(videos.count == 1 ? "1 video" : "\(videos.count) videos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    taskRow(.detectPeople, $detectPeople, "Detect people",
                            "Who's who per video: roster and portraits — ground truth for tagging and framing.")
                    taskRow(.transcribe, $transcribe, "Transcribe",
                            "Speech to text — feeds analysis, captions, and soundbites. Skipped when a transcript already exists.")
                    taskRow(.analyze, $analyze, "Analyze tags",
                            "The full scene analysis: tags, stories, scores, people ranges — one new analyze batch per video.")
                    taskRow(.fightScoring, $fightScoring, "Fight scoring",
                            "Scored actions behind the pace and who-is-winning graphs. Skips non-fight videos on its own.")
                    taskRow(.fightResearch, $fightResearch, "Fight research",
                            "Crawls fan reaction to the fight and distills the story angle for planning and captions. Fights only.")
                    taskRow(.proposeNames, $proposeNames, "Rename files",
                            "Descriptive filenames built from everything found — applied automatically at the end of the run; derived analyze-batch names follow.")
                    taskRow(.curate, $curate, "AI Favorites",
                            "Judges the fresh scenes against your taste rubric and promotes the keepers to Favorites — generation then plans from them.")
                    taskRow(.framing, $framing, "Framing detection",
                            "The 9:16 Center Stage framing pass over each new batch's scenes.")
                    taskRow(.generate, $generate, "Generate video",
                            "One reel per video via the AI Wizard, using your current Wizard settings (format, branding, audio).")
                    taskRow(.critique, $critique, "Critique & auto-retry",
                            "The content critic compares up to 3 takes on small previews. Only the best take is rendered.",
                            enabled: generate)
                        .disabled(!generate)
                        .padding(.leading, 18)
                    taskRow(.coverFrame, $coverFrame, "Pick cover frames",
                            "The AI picks each finished reel's Library thumbnail.", enabled: generate)
                        .disabled(!generate)
                        .padding(.leading, 18)
                }
            }

            Text("Model choices are shared with Settings → AI and the AI Wizard, and saved as soon as you pick them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Start") {
                    store.startPipeline(videos: videos, options: options)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(videos.isEmpty || !options.anyEnabled || store.isPipelineRunning)
            }
        }
        .padding(20)
        .frame(minWidth: 720, idealWidth: 760, minHeight: 480, idealHeight: 720)
        .modalCloseButton { dismiss() }
        .onAppear {
            let form = AppStore.wizardOptionsFromForm(transcriptsAvailable: false)
            step1 = form.step1
            step2 = form.step2
        }
    }

    private func taskRow(_ phase: PipelinePhase, _ isOn: Binding<Bool>, _ title: String,
                         _ subtitle: String, enabled: Bool = true) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isOn.wrappedValue && enabled {
                    if let engine = phase.onDeviceEngine {
                        Text("Runs on this Mac (\(engine)) — no model to choose")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            TaskModelPickers(tasks: modelTasks(for: phase), labelWidth: Self.modelLabelWidth)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .controlSize(.small)
                        .padding(.top, 4)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Wide enough for the longest task label at caption size.
    private static let modelLabelWidth: CGFloat = 130

    private func modelTasks(for phase: PipelinePhase) -> [String] {
        phase.aiTasks(recipe: ReelRecipe.recipe(id: step1.formatPreset ?? "custom") ?? .custom,
                      useBRoll: step2.useBRoll ?? false, brollInstructions: step2.brollInstructions ?? "")
    }
}
