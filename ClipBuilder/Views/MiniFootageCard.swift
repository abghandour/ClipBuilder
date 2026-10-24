import SwiftUI

/// Inline review of a Mini batch; long work uses the shared Wizard status and Stop.
struct MiniFootageCard: View {
    @Environment(AppStore.self) private var store
    let run: MiniWizardRun
    let pageHeight: CGFloat
    @State private var showTranscript = false
    /// The review area's height once the user has dragged its bottom edge;
    /// 0 means fit the page. Shared by Q&A, Transcript, Fight and Highlights.
    @AppStorage("mini.footageHeight") private var storedHeight = 0.0
    @State private var resizeStart: CGFloat?

    static let minimumHeight: CGFloat = 320

    private var automaticHeight: CGFloat { max(560, pageHeight - 220) }
    private var reviewHeight: CGFloat {
        storedHeight > 0 ? max(Self.minimumHeight, CGFloat(storedHeight)) : automaticHeight
    }

    var body: some View {
        FormCaption(run.summary)
        if run.footageKind == .qa {
            qaReview
        } else if run.footageKind == .transcript {
            resizable(MiniTranscriptPickView(run: run))
        } else if run.footageKind == .fightMetrics {
            resizable(MiniFightPickView(run: run))
        } else {
            resizable(MiniHighlightReviewView(run: run))
        }
    }

    /// The review at the remembered height with a grab bar under it; dragging
    /// the bar shows more or less of the transcript and the list.
    private func resizable<Content: View>(_ content: Content) -> some View {
        VStack(spacing: 0) {
            content
                .id(run.batchID)
                .frame(maxWidth: .infinity)
                .frame(height: reviewHeight)
                .disabled(store.isWizardRunning)
            resizeHandle
        }
        // Keep 644 pt for the columns even in a 700 pt detail pane:
        // 700 - 2 * spaceXL - 2 * spaceL + 2 * spaceS.
        .padding(.horizontal, -Theme.spaceS)
    }

    private var resizeHandle: some View {
        Capsule().fill(.quaternary)
            .frame(width: 48, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 14)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if resizeStart == nil { resizeStart = reviewHeight }
                    storedHeight = Double(max(Self.minimumHeight, (resizeStart ?? reviewHeight) + value.translation.height))
                }
                .onEnded { _ in resizeStart = nil })
            .onTapGesture(count: 2) { storedHeight = 0 }
            .help("Drag to show more or less footage. Double-click to fit the page.")
            .accessibilityElement()
            .accessibilityLabel("Footage area height")
            .accessibilityValue("\(Int(reviewHeight)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: storedHeight = Double(reviewHeight + 40)
                case .decrement: storedHeight = Double(max(Self.minimumHeight, reviewHeight - 40))
                @unknown default: break
                }
            }
    }

    @ViewBuilder
    private var qaReview: some View {
        if let qa = run.qa, !qa.sections.isEmpty {
            // The view sizes its own columns to the card; no sideways scrolling.
            let review = TranscriptQAView(video: run.video, sections: qa.sections, rows: qa.rows, labels: qa.labels,
                speakerSpans: qa.speakerSpans,
                kept: Binding(
                    get: { store.miniRun?.batchID == run.batchID ? store.miniRun?.qa?.kept ?? [] : [] },
                    set: { kept in
                        guard store.miniRun?.batchID == run.batchID else { return }
                        store.miniRun?.qa?.kept = kept
                        MiniWizardMemory.saveQAKept(kept, profileName: store.activeProfile.profileName, videoID: run.video.id)
                    }), preferredTranslationLanguage: store.activeProfile.captionLanguages.first) { scene, start, end in
                        store.setSceneEditRange(scene, start: start, end: end)
                    }
            resizable(review)
        } else {
            FormCaption("No Q&A found in this video")
            Button { showTranscript = true } label: {
                Text("Open Transcript").lineLimit(1).fixedSize()
            }
            .disabled(store.isWizardRunning)
            .sheet(isPresented: $showTranscript) { TranscriptSheet(video: run.video) }
        }
    }
}
