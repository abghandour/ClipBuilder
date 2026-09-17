import SwiftUI

/// Two or more analyze batches of one video side by side: aligned timeline
/// strips, a metrics table, the moments they agree on and the ones only one
/// of them found, blind grading of those unique scenes, and Keep or Merge.
/// Nothing here calls a model; the grades are the user's own signal.
struct CompareBatchesSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let runs: [AnalysisRun]
    let video: VideoRecord

    @State private var previewScene: SceneRecord?
    /// Unique scenes in a fixed shuffled order, so grading is blind and
    /// stable while grades land.
    @State private var gradingOrder: [Int64] = []
    @State private var gradingIndex = 0
    @State private var pendingKeep: AnalysisRun?
    @State private var pendingMerge: AnalysisRun?

    private var comparison: BatchComparison {
        BatchComparison.compare(runIDs: runs.map(\.id), scenes: store.scenes, duration: video.duration)
    }

    private func label(_ run: AnalysisRun) -> String {
        let model = run.model.map(AICatalog.modelDisplayName) ?? ""
        let provider = run.provider.flatMap { AICatalog.provider($0)?.label } ?? run.provider ?? ""
        let who = [provider, model].filter { !$0.isEmpty }.joined(separator: " — ")
        return who.isEmpty ? run.name : "\(run.name) · \(who)"
    }

    var body: some View {
        let comparison = comparison
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Compare Analyze Batches — \(video.filename)")
                        .font(.headline)
                    Text("\(runs.count) batches · \(comparison.shared.count) moment\(comparison.shared.count == 1 ? "" : "s") found by all · \(comparison.allUnique.count) scene\(comparison.allUnique.count == 1 ? "" : "s") found by one batch only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    strips(comparison)
                    metricsTable(comparison)
                    grading(comparison)
                    actions(comparison)
                }
                .padding()
            }
        }
        .frame(width: 900, height: 680)
        .modalCloseButton { dismiss() }
        .sheet(item: $previewScene) { scene in
            PlayerSheet(url: scene.videoURL, transcriptVideoID: scene.videoID,
                        title: "\(scene.videoFilename)  \(scene.startTime.timecode)–\(scene.endTime.timecode)",
                        startTime: scene.startTime, endTime: scene.endTime)
        }
        .confirmationDialog("Keep only \"\(pendingKeep?.name ?? "")\"?",
                            isPresented: Binding(get: { pendingKeep != nil }, set: { if !$0 { pendingKeep = nil } }),
                            titleVisibility: .visible, presenting: pendingKeep) { run in
            Button("Keep This Batch, Delete the Others", role: .destructive) {
                for other in runs where other.id != run.id { store.deleteAnalysisRun(other) }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: { run in
            Text("The other \(runs.count - 1) batch\(runs.count == 2 ? "" : "es") and their scenes, tags and grades are deleted. \"\(run.name)\" stays as it is. The video is not touched.")
        }
        .confirmationDialog("Merge into \"\(pendingMerge?.name ?? "")\"?",
                            isPresented: Binding(get: { pendingMerge != nil }, set: { if !$0 { pendingMerge = nil } }),
                            titleVisibility: .visible, presenting: pendingMerge) { run in
            Button("Merge") {
                merge(into: run, comparison: comparison)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: { run in
            Text("Every batch stays. Where another batch found the same moment as \"\(run.name)\", that other take is hidden; scenes only the other batches found stay visible. Nothing is deleted.")
        }
        .task {
            gradingOrder = comparison.allUnique.map(\.id).shuffled()
        }
    }

    // MARK: - Timeline strips

    private func strips(_ comparison: BatchComparison) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Where each batch cut scenes")
            Text("Same time axis for every batch. Grey: a moment every batch found. Blue: a moment only this batch found. Click a scene to play it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(runs) { run in
                HStack(spacing: 8) {
                    Text(run.name)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(width: 180, alignment: .trailing)
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.quaternary)
                            ForEach(comparison.moments) { moment in
                                ForEach(moment.members.filter { $0.runID == run.id }) { scene in
                                    let unique = moment.runIDs.count == 1
                                    let x = video.duration > 0 ? scene.startTime / video.duration * width : 0
                                    let w = video.duration > 0 ? max(2, scene.duration / video.duration * width) : 0
                                    Rectangle()
                                        .fill(unique ? Color.accentColor : Color.secondary.opacity(0.7))
                                        .frame(width: w, height: 16)
                                        .offset(x: x)
                                        .help("\(scene.startTime.timecode)–\(scene.endTime.timecode)"
                                              + (unique ? " · only this batch" : " · found by \(moment.runIDs.count) batches"))
                                        .onTapGesture { previewScene = scene }
                                }
                            }
                        }
                    }
                    .frame(height: 16)
                }
            }
        }
    }

    // MARK: - Metrics

    private func metricsTable(_ comparison: BatchComparison) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("What each batch found")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("Batch").font(.caption.weight(.semibold))
                    ForEach(["Scenes", "Coverage", "Avg length", "Tags", "People", "Avg score", "Favorites", "Only here", "Shared", "Graded good"], id: \.self) {
                        Text($0).font(.caption.weight(.semibold)).gridColumnAlignment(.trailing)
                    }
                }
                ForEach(runs) { run in
                    let m = comparison.metrics[run.id] ?? BatchComparison.Metrics(runID: run.id)
                    GridRow {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(run.name).lineLimit(1)
                            Text(label(run).replacingOccurrences(of: run.name + " · ", with: ""))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text("\(m.sceneCount)")
                        Text("\(Int((m.coverage * 100).rounded()))%")
                        Text(m.averageLength.timecode)
                        Text("\(m.tagCount)")
                        Text("\(m.peopleCount)")
                        Text(m.averageScore.map { String(format: "%.1f", $0) } ?? "—")
                        Text("\(m.favorites)")
                        Text("\(m.uniqueCount)")
                        Text("\(m.sharedCount)")
                        Text(m.goodShare.map { "\(Int(($0 * 100).rounded()))% of \(m.gradedCount)" } ?? "—")
                    }
                    .font(.callout.monospacedDigit())
                }
            }
            Text("Scenes counts everything the batch produced; Coverage is how much of the video its scenes span; Only here counts moments no other batch found; Graded good is the share of its graded scenes you rated good.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Blind grading

    private func grading(_ comparison: BatchComparison) -> some View {
        let unique = comparison.allUnique
        let byID = Dictionary(uniqueKeysWithValues: unique.map { ($0.id, $0) })
        let order = gradingOrder.filter { byID[$0] != nil }
        let current = gradingIndex < order.count ? byID[order[gradingIndex]] : nil
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Grade the scenes only one batch found")
            Text("Shown in a shuffled order without saying which batch found them, so the grade is about the scene. Good and Bad save at once and feed the Graded good column above.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if unique.isEmpty {
                Text("Every moment was found by every batch — nothing to grade blind.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if let current {
                HStack(alignment: .top, spacing: 16) {
                    // Keyed by scene: a grade moves on to the next scene
                    // and the player must not keep playing the last one.
                    SceneInlinePlayer(scene: current)
                        .id(current.id)
                        .aspectRatio(9 / 16, contentMode: .fit)
                        .frame(height: 260)
                        .overlay(alignment: .bottomTrailing) {
                            DurationBadge(seconds: current.duration).allowsHitTesting(false)
                        }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(gradingIndex + 1) of \(order.count) · \(current.startTime.timecode)–\(current.endTime.timecode)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if let narrative = current.narrative, !narrative.isEmpty {
                            Text(narrative)
                                .font(.callout)
                                .lineLimit(6)
                        }
                        SceneTagLine(tags: current.tags)
                        HStack {
                            Button("Good", systemImage: "hand.thumbsup") { grade(current, score: 5) }
                                .keyboardShortcut("g", modifiers: [])
                            Button("Bad", systemImage: "hand.thumbsdown") { grade(current, score: 1) }
                                .keyboardShortcut("b", modifiers: [])
                            Button("Skip") { gradingIndex += 1 }
                            Button("Play") { previewScene = current }
                        }
                        .controlSize(.small)
                        if current.gradeCount > 0 {
                            Text("Already graded \(current.lastGrade.map { $0 >= Int(BatchComparison.goodGrade) ? "good" : "bad" } ?? "")")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                HStack {
                    Text("All \(order.count) unique scenes graded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Start Over") { gradingIndex = 0 }
                        .controlSize(.small)
                }
            }
        }
    }

    private func grade(_ scene: SceneRecord, score: Int) {
        store.grade(scene, score: score)
        gradingIndex += 1
    }

    // MARK: - Actions

    private func actions(_ comparison: BatchComparison) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Decide")
            ForEach(runs) { run in
                HStack {
                    Text(run.name)
                        .lineLimit(1)
                        .frame(width: 260, alignment: .leading)
                    Button("Keep Only This Batch…", role: .destructive) { pendingKeep = run }
                        .help("Delete the other batches; this one stays untouched")
                    Button("Merge Into This Batch…") { pendingMerge = run }
                        .help("Keep every batch, but hide the other batches' takes of moments this one also found")
                }
                .controlSize(.small)
            }
        }
    }

    /// Hide the other batches' takes of every moment `run` also found;
    /// their unique scenes stay.
    private func merge(into run: AnalysisRun, comparison: BatchComparison) {
        for moment in comparison.moments where moment.runIDs.contains(run.id) {
            for scene in moment.members where scene.runID != run.id && !scene.excluded {
                store.setExcluded(scene, excluded: true)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
    }
}
