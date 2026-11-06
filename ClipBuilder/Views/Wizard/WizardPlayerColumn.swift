import SwiftUI

/// The Express and full wizard pages' third column: the kept footage played
/// as recorded, in the video's own format. Express adds List and Summary
/// tabs and a footer. Nothing here renders the settings; the rough cut
/// sheet (Preview) is where captions, name tags, overlays and the focus
/// frame are seen and placed.
struct WizardPlayerColumn: View {
    /// Kept footage in output order. Empty: the scenes play instead.
    var clips: [WizardPreviewClip] = []
    var scenes: [SceneRecord] = []
    /// Width / height of the output format: the player's frame until the
    /// recording's own shape has been read.
    let aspect: CGFloat
    /// Pinned under the player: Express puts its run summary and Generate here.
    var footer: AnyView? = nil
    /// Top-right corner of the header: Express puts Start Over here.
    var headerAccessory: AnyView? = nil
    var emptyMessage = "Choose a video to preview"
    /// When set, the header gets List and Video (and Summary) tabs (Express).
    var list: WizardPreviewListConfig? = nil

    @AppStorage("preview.express.tab") private var tabRaw = PreviewTab.list.rawValue
    private enum PreviewTab: String, CaseIterable { case list, video, summary }
    private var tab: PreviewTab {
        guard let list else { return .video }
        let chosen = PreviewTab(rawValue: tabRaw) ?? .list
        return chosen == .summary && list.summary == nil ? .list : chosen
    }
    @State private var index = 0

    private var playable: [WizardPreviewClip] {
        clips.isEmpty ? KeptClipsPlayback.clips(scenes: scenes) : clips
    }

    var body: some View {
        Group {
            if let footer, list?.summary != nil {
                // The summary is a tab, so the footer is only the action row.
                VStack(spacing: 0) {
                    content
                    Divider()
                    footer
                }
            } else if let footer {
                VSplitView {
                    content
                        .rememberedPaneHeight("pane.wizard.previewArea", min: 260, initial: 560)
                    footer
                        .frame(minHeight: 96)
                }
            } else {
                content
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            VStack(alignment: .leading, spacing: Theme.spaceS) {
                HStack(spacing: Theme.spaceS) {
                    Text("Preview").font(.headline).lineLimit(1).fixedSize()
                    Spacer(minLength: 0)
                    headerAccessory
                }
                if list != nil { tabPicker }
            }
            if let list, tab == .list {
                WizardPreviewList(clips: clips, selectedIndex: $index, config: list,
                                  emptyMessage: clips.isEmpty ? "No kept footage yet. Keep footage in the Footage step to list it here." : "")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let summary = list?.summary, tab == .summary {
                ScrollView { summary.frame(maxWidth: .infinity, alignment: .topLeading) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                KeptClipsPlayer(clips: playable, aspect: max(0.01, aspect), index: $index,
                                noun: clips.isEmpty ? "Scene" : "Clip", emptyMessage: emptyMessage)
            }
        }
        .padding(Theme.spaceM)
    }

    private var tabPicker: some View {
        Picker("Preview tab", selection: $tabRaw) {
            Text("List").tag(PreviewTab.list.rawValue)
            Text("Video").tag(PreviewTab.video.rawValue)
            if list?.summary != nil { Text("Summary").tag(PreviewTab.summary.rawValue) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("List shows the kept clips in order; Video plays them as recorded, in the video's own format; Summary shows what Generate will make")
    }
}
