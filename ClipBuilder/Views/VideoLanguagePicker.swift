import SwiftUI

/// The one editable control for a video's language: the detail pane row
/// under Type. "—" means none; detection then leaves the video alone.
struct VideoLanguagePicker: View {
    @Environment(AppStore.self) private var store
    let video: VideoRecord

    private var current: VideoRecord { store.videos.first { $0.id == video.id } ?? video }

    private var selection: Binding<String> {
        Binding(
            get: { current.language ?? "" },
            set: { store.setVideoLanguage(video, language: $0.isEmpty ? nil : $0) }
        )
    }

    var body: some View {
        let current = current
        let choices = VideoLanguage.choices(including: current.language, project: store.projectLanguages.spoken)
        let source = current.languageSource.flatMap(VideoLanguage.Source.init(rawValue:))
        let failed = VideoLanguage.detectionFailed(language: current.language, source: current.languageSource)
        Picker("Language", selection: selection) {
            Text("—").tag("")
            ForEach(choices, id: \.self) { locale in
                Text(VideoLanguage.choiceTitle(locale, state: store.recognizerStates[locale])).tag(locale)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .lineLimit(1)
        .fixedSize()
        .help("The language spoken in this footage. "
              + (failed ? VideoLanguage.detectionFailedText + " " : source.map { $0.caption + ". " } ?? "Not known yet. ")
              + "Transcription uses it before the project's languages; a language marked not installed is refused until it is installed.")
    }
}

/// Two-letter language code at the right edge of the Sources File column.
struct LanguageBadge: View {
    let video: VideoRecord

    var body: some View {
        if VideoLanguage.detectionFailed(language: video.language, source: video.languageSource) {
            Text("?")
                .font(.caption2.weight(.bold)).monospaced()
                .foregroundStyle(.orange)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                .lineLimit(1).fixedSize()
                .help(VideoLanguage.detectionFailedText)
                .accessibilityLabel("Language not detected")
        } else if let badge = VideoLanguage.badge(video.language), let language = video.language {
            Text(badge)
                .font(.caption2.weight(.bold)).monospaced()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                .lineLimit(1).fixedSize()
                .help("Language: \(VideoLanguage.name(language))")
                .accessibilityLabel("Language \(VideoLanguage.name(language))")
        }
    }
}
