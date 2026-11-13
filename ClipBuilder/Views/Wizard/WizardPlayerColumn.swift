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
                // With a list this column is the reel being built; without
                // one (the Full wizard) it only plays the chosen scenes.
                Text(list != nil ? "Reel" : "Preview").font(.headline).lineLimit(1).fixedSize()
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
        // Whatever still outgrows the column is cut at the right, never the left.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .padding(Theme.spaceM)
        .focusedValue(\.wizardPreviewFocused, true)
    }

    private var tabPicker: some View {
        Picker("Reel tab", selection: $tabRaw) {
            Text("List").tag(PreviewTab.list.rawValue)
            Text("Source Video").tag(PreviewTab.video.rawValue)
            if list?.summary != nil { Text("Summary").tag(PreviewTab.summary.rawValue) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        // Fills the column and shrinks with it; a fixed size wider than a
        // narrow column pushed the whole column's content off its left edge.
        .frame(maxWidth: .infinity)
        .help("List shows the reel's clips in order; Source Video plays them as recorded, in the video's own format and without the settings; Summary shows what Generate will make")
    }
}
