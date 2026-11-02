import SwiftUI

/// Builder inspector section for the dub, a checkbox like Speech Polish below
/// it. On shows the options (voices, language, original level, mute) and the
/// button that prepares the lines; off hides them and keeps whatever was
/// prepared, so the dub can be turned back on without another preparation.
struct DubInspector: View {
    @Environment(AppStore.self) private var store

    private var dub: DubSettings? { store.builder.document.dub }
    private var lines: [DubLine] { store.builder.document.dubLines ?? [] }

    /// The dub job for this timeline while it prepares lines.
    private var preparing: AppJob? {
        let subject = "timeline-\(store.openTimelineID.map(String.init) ?? "unsaved")"
        guard let job = store.jobs.latest(.dub, subjectID: subject), job.status == .running else { return nil }
        return job
    }

    var body: some View {
        InspectorSection("Dub") {
            Toggle("Dub on export", isOn: Binding(get: { dub?.enabled == true }, set: { setEnabled($0) }))
                .lineLimit(1)
                .disabled(store.builder.document.videoTrack.isEmpty)
                .help("Replace the speech on this timeline with a synthetic voice in another language. Lines are reviewed before they are applied.")
            if let dub, dub.enabled {
                DubLanguagePicker(language: Binding(
                    get: { dub.language },
                    set: { if let language = $0 { update { $0.language = language } } }))
                HStack {
                    Text("Original level").lineLimit(1).fixedSize()
                    Slider(value: Binding(get: { dub.originalLevel }, set: { level in update { $0.originalLevel = level } }),
                           in: 0...0.5)
                        .accessibilityLabel("Original speech level")
                        .disabled(dub.replaceOriginal)
                    Text(dub.originalLevel, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().frame(width: 44)
                }
                Toggle("Mute original audio", isOn: Binding(
                    get: { dub.replaceOriginal },
                    set: { mute in update { $0.replaceOriginal = mute } }))
                    .lineLimit(1)
                    .help("Silence the speech and background under the dub instead of ducking them to the original level")
                linesStatus
            }
        }
        .padding()
    }

    @ViewBuilder private var linesStatus: some View {
        if let preparing {
            HStack(spacing: Theme.spaceS) {
                ProgressView().controlSize(.small)
                Text(preparing.statusLine.isEmpty ? "Preparing dub lines…" : preparing.statusLine)
                    .lineLimit(1).truncationMode(.tail)
                    .font(.caption).foregroundStyle(.secondary)
                Button("Stop") { store.jobs.cancel(preparing.id) }
                    .lineLimit(1).fixedSize()
            }
        } else if lines.isEmpty {
            Text("No lines yet. Prepare them, then review each line before they are applied.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Prepare lines…") { prepare() }
                .lineLimit(1).fixedSize()
        } else {
            Text("\(lines.count) lines · \(lines.filter(\.tight).count) tight")
                .font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack { lineControls }
                VStack(alignment: .leading) { lineControls }
            }
        }
    }

    @ViewBuilder private var lineControls: some View {
        Button("Review lines…") { store.reviewTimelineDub() }
            .lineLimit(1).fixedSize()
        Button("Prepare again…") { prepare() }
            .lineLimit(1).fixedSize()
            .help("Prepare the lines again with the current language and voices")
    }

    /// The project's dub language first, then the profile's, then the app default.
    private var defaultLanguage: String {
        store.projectLanguages.dub.first
            ?? store.editingDefaults.footage.dubLanguage
            ?? DubLanguageChoices.defaultLanguage
    }

    private func setEnabled(_ enabled: Bool) {
        var settings = dub ?? DubSettings(language: defaultLanguage, enabled: false)
        settings.enabled = enabled
        store.builder.setDub(settings: settings, lines: store.builder.document.dubLines)
    }

    /// Settings edits keep the lines; a language change drops them because
    /// they were spoken in the old language.
    private func update(_ change: (inout DubSettings) -> Void) {
        guard var settings = dub else { return }
        let language = settings.language
        change(&settings)
        let keepLines = settings.language == language
        store.builder.setDub(settings: settings, lines: keepLines ? store.builder.document.dubLines : nil)
    }

    private func prepare() {
        guard let dub else { return }
        store.dubTimeline(language: dub.language, originalLevel: dub.originalLevel, replaceOriginal: dub.replaceOriginal)
    }
}
