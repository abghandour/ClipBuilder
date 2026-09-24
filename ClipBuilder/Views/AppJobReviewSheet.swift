import SwiftUI

/// Routes a finished job to its review sheet. The rich reviews own their whole
/// layout (title, close button, footer), so this adds nothing around them —
/// a second title and button row made the sheet overflow its window.
struct AppJobReviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let job: AppJob

    var body: some View {
        Group {
            switch job.result {
            case let .favorites(candidates, proposals, provenance):
                AIFavoritesReviewSheet(jobID: job.id, candidates: candidates, proposals: proposals, provenance: provenance)
            case let .soundbites(video, items, provenance):
                SoundbiteReviewSheet(jobID: job.id, video: video, soundbites: items, provenance: provenance)
            case let .duplicateReport(videos, groups, provenance):
                DuplicateReviewSheet(jobID: job.id, videos: videos, groups: groups, provenance: provenance)
            case .fileNames(let suggestions):
                FileNameReviewSheet(jobID: job.id, suggestions: suggestions)
            case let .gapReport(sections, provenance):
                GapReportReviewSheet(jobID: job.id, sections: sections, provenance: provenance)
            case let .profileStarter(result, provenance):
                ProfileStarterReviewSheet(jobID: job.id, result: result, provenance: provenance)
            case let .coverFrames(video, candidates, provenance):
                CoverFrameReviewSheet(jobID: job.id, video: video, candidates: candidates, provenance: provenance)
            case .fightResearch(let video):
                FightResearchReviewSheet(jobID: job.id, video: video)
            default:
                simple
            }
        }
        .onAppear { store.jobs.reviewDidAppear(job.id) }
    }

    /// Results with nothing to decide: a permalink or a list of written files.
    private var simple: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(job.title)
                .font(.title3.bold())
            switch job.result {
            case .instagramPublished(let permalink):
                Text("Published to Instagram.")
                    .font(.callout)
                if let permalink {
                    HStack(spacing: 10) {
                        Link("View on Instagram", destination: permalink)
                        Button("Copy Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(permalink.absoluteString, forType: .string)
                        }
                    }
                }
            case .resourceExport(let url): files([url])
            case .socialExport(let urls): files(urls)
            case .resourceImport(let summary):
                Text(summary.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                Text(job.statusLine.isEmpty ? "Finished." : job.statusLine)
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button("Done") { store.jobs.markReviewed(job.id); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .help("Close this result and clear it from the status bar")
            }
        }
        .padding(20)
        .frame(minWidth: 440, idealWidth: 480)
        .modalCloseButton { dismiss() }
    }

    private func files(_ urls: [URL]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(urls, id: \.self) { url in
                    HStack {
                        Text(url.lastPathComponent)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
            }
        }
        .frame(maxHeight: 260)
    }
}

/// Setup sheets block automatic review until their dismissal has completed.
private struct AppJobSetupPresentation: ViewModifier {
    @Environment(AppStore.self) private var store
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { store.jobs.setupPresentations.insert(id) }
            .onDisappear { store.jobs.setupPresentations.remove(id) }
    }
}

extension View {
    func appJobSetupPresentation() -> some View { modifier(AppJobSetupPresentation()) }
}
