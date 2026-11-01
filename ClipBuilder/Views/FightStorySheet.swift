import SwiftUI

/// Setup for an evidence-linked fight story (docs/Fight-Story-Plan.md):
/// an interview claim, a fight video's picked sequences, an optional
/// strike stat card and the outcome card's copy. Build starts a
/// background job and closes the sheet; the result opens in the Builder
/// from the job's review sheet. Launched from Express (Fight metrics) and
/// the Analyze view's fight research row.
struct FightStorySheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// The fight video to start from, when the caller has one.
    var fightVideo: VideoRecord?

    private struct Claim: Identifiable {
        var pick: TranscriptPick
        var videoName: String
        var text: String
        var id: Int64 { pick.id }
    }

    @State private var claims: [Claim] = []
    @State private var claimID: Int64?
    @State private var fightVideoID: Int64?
    @State private var fightPicks: [FightPick] = []
    @State private var selectedFightIDs: Set<Int64> = []
    @State private var includeStats = false
    @State private var kicker = ""
    @State private var headline = ""
    @State private var subline = ""
    @State private var fallback = FightStoryBuilder.StoryCardCopy(kicker: "", headline: "")
    @State private var loadingClaims = true

    private var fightVideos: [VideoRecord] {
        store.videos.filter { video in
            guard let type = video.type else { return false }
            return type.supportsFightFeatures || type == .training
        }
    }

    private var orderedFightIDs: [Int64] {
        fightPicks.filter { selectedFightIDs.contains($0.id) }.map(\.id)
    }

    private var userCard: FightStoryBuilder.StoryCardCopy? {
        let copy = FightStoryBuilder.StoryCardCopy(
            kicker: kicker.trimmingCharacters(in: .whitespacesAndNewlines),
            headline: headline.trimmingCharacters(in: .whitespacesAndNewlines),
            subline: subline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil
                : subline.trimmingCharacters(in: .whitespacesAndNewlines))
        return copy.isEmpty ? nil : copy
    }

    private var canBuild: Bool {
        claimID != nil && fightVideoID != nil && !orderedFightIDs.isEmpty && store.activeProjectID != nil
            && !(fightVideoID.map(store.isBuildingFightStory) ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            Text("Fight Story").font(.title2.bold())
            Text("One timeline: an interview claim, the fight sequence, and a closing card with the result. Every clip keeps a link to its transcript range or fight events.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spaceM) {
                    claimSection
                    Divider()
                    fightSection
                    Divider()
                    cardSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 360, maxHeight: 520)

            HStack(spacing: Theme.spaceS) {
                if store.activeProjectID == nil {
                    Text("Open a project first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    guard let claimID, let fightVideoID else { return }
                    store.startFightStory(claimPickID: claimID, fightVideoID: fightVideoID,
                                          fightPickIDs: orderedFightIDs, includeStats: includeStats, card: userCard)
                    dismiss()
                } label: {
                    Text("Build").lineLimit(1).fixedSize()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canBuild)
                .help("Build the story in the background; it opens in the Builder from the status bar")
            }
        }
        .padding(Theme.spaceL)
        .frame(minWidth: 560, idealWidth: 620)
        .modalCloseButton { dismiss() }
        .appJobSetupPresentation()
        .task { await loadClaims() }
        .task(id: fightVideoID) { await loadFight() }
        .onAppear {
            if fightVideoID == nil {
                fightVideoID = fightVideo.flatMap { video in fightVideos.first { $0.id == video.id }?.id }
                    ?? fightVideos.first?.id
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var claimSection: some View {
        Text("1  Interview claim").font(.headline)
        if loadingClaims {
            ProgressView().controlSize(.small)
        } else if claims.isEmpty {
            Text("No transcript picks yet. In Express, choose an interview, pick Transcript footage, mark the claim and press Add.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Picker("Claim", selection: $claimID) {
                ForEach(claims) { claim in
                    Text("\(claim.videoName) · \(claim.pick.start.timecode)").lineLimit(1).tag(Optional(claim.id))
                }
            }
            .labelsHidden()
            .accessibilityLabel("Interview claim")
            if let claim = claims.first(where: { $0.id == claimID }) {
                Text(claim.text.isEmpty ? "(No transcript text in this range.)" : "\u{201C}\(claim.text)\u{201D}")
                    .font(.callout)
                    .italic()
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var fightSection: some View {
        Text("2  Fight sequence").font(.headline)
        if fightVideos.isEmpty {
            Text("No fight videos in this project. Set a video's type to Fight in Analyze.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Picker("Fight video", selection: $fightVideoID) {
                ForEach(fightVideos) { video in
                    Text(store.fightResearch[video.id]?.fightLabel.isEmpty == false
                         ? store.fightResearch[video.id]?.fightLabel ?? video.filename : video.filename)
                        .lineLimit(1).tag(Optional(video.id))
                }
            }
            .accessibilityLabel("Fight video")
            if fightPicks.isEmpty {
                Text("No fight picks for this video. In Express, choose it, pick Fight metrics footage and add the actions you want.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(fightPicks.enumerated()), id: \.element.id) { index, pick in
                    Toggle(isOn: Binding(get: { selectedFightIDs.contains(pick.id) },
                                         set: { on in
                                             if on { selectedFightIDs.insert(pick.id) } else { selectedFightIDs.remove(pick.id) }
                                         })) {
                        Text("Pick \(index + 1): \(pick.start.timecode)–\(pick.end.timecode) · \(pick.eventIDs.count) action(s)")
                            .lineLimit(1)
                    }
                }
                Text("Selected picks play in list order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle(isOn: $includeStats) {
                Text("Include strike stats").lineLimit(1).fixedSize()
            }
            .help("Add a strike stat card for the whole fight under the result")
        }
    }

    @ViewBuilder
    private var cardSection: some View {
        Text("3  Outcome card").font(.headline)
        Text("Leave the headline empty to let the model write the card from the outcome and research. If it cannot, the placeholder copy is used.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Grid(alignment: .leading, horizontalSpacing: Theme.spaceS, verticalSpacing: Theme.spaceS) {
            GridRow {
                Text("Kicker").lineLimit(1).fixedSize()
                TextField(fallback.kicker.isEmpty ? "Event" : fallback.kicker, text: $kicker)
            }
            GridRow {
                Text("Headline").lineLimit(1).fixedSize()
                TextField(fallback.headline.isEmpty ? "Result" : fallback.headline, text: $headline)
            }
            GridRow {
                Text("Subline").lineLimit(1).fixedSize()
                TextField(fallback.subline ?? "Optional", text: $subline)
            }
        }
        HStack(spacing: Theme.spaceS) {
            Button {
                kicker = fallback.kicker
                headline = fallback.headline
                subline = fallback.subline ?? ""
            } label: {
                Text("Use Record Copy").lineLimit(1).fixedSize()
            }
            .disabled(fallback.isEmpty)
            .help("Fill the fields with the copy from the outcome and research records")
            MiniModelButton(tasks: [AITask.storyCard.rawValue])
        }
    }

    // MARK: - Loading

    private func loadClaims() async {
        defer { loadingClaims = false }
        guard let database = store.database else { return }
        let fightTypes: Set<VideoType> = [.fight, .recap, .training]
        let videos = Dictionary(store.videos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let picks = ((try? await database.fetchAllTranscriptPicks(projectID: store.activeProjectID)) ?? []).filter { pick in
            guard let video = videos[pick.videoID] else { return false }
            return video.type.map { !fightTypes.contains($0) } ?? true
        }
        var loaded: [Claim] = []
        for videoID in Set(picks.map(\.videoID)).sorted() {
            let rows = ((try? await database.fetchTranscripts(videoID: videoID)) ?? []).filter { !$0.isTranslation }
            let name = videos[videoID]?.filename ?? "Video \(videoID)"
            for pick in picks where pick.videoID == videoID {
                loaded.append(Claim(pick: pick, videoName: name,
                                    text: MiniWizardTranscriptRules.text(for: pick.range, rows: rows)))
            }
        }
        claims = loaded
        if claimID == nil || !loaded.contains(where: { $0.id == claimID }) { claimID = loaded.first?.id }
    }

    private func loadFight() async {
        guard let database = store.database, let fightVideoID else {
            fightPicks = []
            return
        }
        let picks = (try? await database.fetchFightPicks(projectID: store.activeProjectID, videoID: fightVideoID)) ?? []
        let outcome = (try? await database.fetchOutcomes())?.first { $0.videoID == fightVideoID }
        let roster = (try? await database.fetchVideoPeople(videoID: fightVideoID)) ?? []
        guard fightVideoID == self.fightVideoID else { return }
        fightPicks = picks
        selectedFightIDs = Set(picks.map(\.id))
        let research = store.fightResearch[fightVideoID]
        let label = research?.fightLabel.isEmpty == false ? research?.fightLabel ?? "" : ""
        fallback = FightStoryBuilder.fallbackCard(
            outcome: outcome, research: research,
            fightLabel: label.isEmpty ? (fightVideos.first { $0.id == fightVideoID }?.filename ?? "") : label,
            names: Dictionary(roster.map { ($0.key, $0.displayName) }, uniquingKeysWith: { first, _ in first }))
    }
}

/// The fight story job's review: the card copy it used, where the copy
/// came from, and Open in Builder.
struct FightStoryReviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let jobID: UUID
    let review: FightStoryReview

    private var sourceText: String {
        switch review.cardSource {
        case .ai: "Card copy written by the model from the outcome and research records."
        case .user: "Card copy as you wrote it."
        case .records: "Card copy from the outcome and research records (the model was unavailable)."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            HStack(spacing: 8) {
                Text("Fight Story").font(.headline)
                if let provenance = review.provenance {
                    AIInfoButton(provenance: provenance, style: .full, role: "Card by")
                }
            }
            Text("Saved as \u{201C}\(review.timelineName)\u{201D}: \(review.clipCount) clip(s)\(review.hasStat ? " and a strike stat card" : "").")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                if !review.card.kicker.isEmpty {
                    Text(review.card.kicker.uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                Text(review.card.headline).font(.title3.bold())
                if let subline = review.card.subline { Text(subline).font(.callout) }
            }
            .padding(Theme.spaceM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            Text(sourceText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { close() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    let id = review.timelineID
                    close()
                    store.openFightStory(timelineID: id)
                } label: {
                    Text("Open in Builder").lineLimit(1).fixedSize()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help("Open the story timeline in the Builder")
            }
        }
        .padding(Theme.spaceL)
        .frame(minWidth: 440, idealWidth: 480)
        .modalCloseButton { close() }
    }

    private func close() {
        store.jobs.markReviewed(jobID)
        dismiss()
    }
}
