import SwiftUI

@MainActor
struct ReelModelsLearnedSection: View {
    @Environment(AppStore.self) private var store
    /// Bumped by the owner after a publish or reload so adopted models show up.
    var reloadToken = UUID()
    @State private var reports: [ReelModelEvaluation] = []
    @State private var available: [LearnedModelArtifact] = []
    @State private var busy = false
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trained models").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], alignment: .leading, spacing: 16) {
                ForEach(ReelModelItem.allCases, id: \.rawValue) { item in
                    modelCard(item)
                }
            }
            if !available.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Models from contributors").font(.subheadline.weight(.medium))
                    ForEach(available) { model in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(displayName(model.item)) · Version \(model.version)")
                                Text(model.contributor).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Adopt and evaluate") { adopt(model) }
                                .buttonStyle(.bordered).controlSize(.small).disabled(busy)
                                .help("Adopt this contributor's model and evaluate it locally.")
                        }
                    }
                }.padding(.top, 8)
            }
            Text("Models rank and score your footage. Evaluate locally, then enable each model in Settings → AI.")
                .font(.caption).foregroundStyle(.secondary)
            if !status.isEmpty {
                Text(status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .task(id: "\(store.activeProfile.profileName)|\(reloadToken)") { reload() }
    }

    private func displayName(_ item: ReelModelItem) -> String {
        switch item {
        case .outcome: "Outcome model"
        case .ranker: "Clip ranker"
        case .taste: "Taste similarity"
        }
    }

    private func modelCard(_ item: ReelModelItem) -> some View {
        let report = reports.first { $0.item == item }
        let enabled = item.isEnabled(config: store.settings.ai)
        let (state, tint): (String, Color) =
            enabled ? ("Enabled", .green)
            : report == nil ? ("Not evaluated", .secondary)
            : report?.passed == true ? ("Passed", .accentColor) : ("Not passed", .orange)
        let face: String
        if let report {
            let origin = report.origin.map { "adopted from \($0)" } ?? "trained here"
            face = "Evaluated \(report.date.formatted(date: .abbreviated, time: .shortened)) · v\(report.version) · \(origin)"
        } else {
            face = "Not evaluated yet on this Mac."
        }
        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(displayName(item)).font(.headline)
                        Spacer(minLength: 0)
                        statusPill(state, tint: tint)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(displayName(item)).font(.headline)
                        statusPill(state, tint: tint)
                    }
                }
                Text(face)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Evaluate") {
                    busy = true
                    Task {
                        defer { busy = false }
                        do {
                            status = try await store.evaluateReelModel(item).summary
                            reload()
                        } catch { status = error.localizedDescription }
                    }
                }
                .buttonStyle(.bordered).controlSize(.small).disabled(busy)
                .help("Evaluate \(displayName(item)) against local examples before enabling it in Settings → AI.")
                if let report {
                    DisclosureGroup("Evaluation details") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(report.trainingCount) training · \(report.holdoutCount) holdout · baseline \(report.baseline.formatted(.number.precision(.fractionLength(2))))")
                            if !report.metrics.isEmpty {
                                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                                    ForEach(report.metrics.sorted { $0.key < $1.key }, id: \.key) { metric in
                                        GridRow {
                                            Text(metric.key)
                                            Text(metric.value.formatted(.number.precision(.fractionLength(2))))
                                                .monospacedDigit().gridColumnAlignment(.trailing)
                                        }
                                    }
                                }
                            }
                            if report.origin != nil && !report.localEvaluation {
                                Text("Local evaluation required before this model can be enabled.")
                            }
                            if !report.importance.isEmpty {
                                Text("What moves results for this account").fontWeight(.medium).padding(.top, 4)
                                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                                    ForEach(report.importance.sorted { $0.value > $1.value }.prefix(8), id: \.key) { feature in
                                        GridRow {
                                            Text(feature.key)
                                            Text(feature.value.formatted(.number.precision(.fractionLength(3))))
                                                .monospacedDigit().gridColumnAlignment(.trailing)
                                        }
                                    }
                                }
                            }
                        }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    }.font(.caption)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
    }

    private func statusPill(_ title: String, tint: Color) -> some View {
        Text(title).font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .fixedSize()
    }

    private func reload() {
        reports = ReelModelItem.allCases.compactMap { store.reelModelStore?.report($0) }
        let library = LearnedLibrary(profile: store.activeProfile.profileName)
        available = library.documents().filter {
            $0.contributor != LearnedPreferences.contributor(profile: store.activeProfile)
                && !store.activeProfile.learnedSharing.mutedContributors.contains($0.contributor)
        }.flatMap { document in
            ReelModelItem.allCases.compactMap { item -> LearnedModelArtifact? in
                let file = library.directory.appendingPathComponent(document.contributor)
                    .appendingPathComponent("models/" + item.rawValue + ".json")
                guard let data = try? Data(contentsOf: file),
                    let model = try? JSONDecoder().decode(LearnedModelArtifact.self, from: data),
                    (try? model.validate()) != nil
                else { return nil }
                return model
            }
        }
    }
    private func adopt(_ model: LearnedModelArtifact) {
        guard let destination = store.reelModelStore else { return }
        let source = LearnedLibrary().directory.appendingPathComponent(model.contributor)
            .appendingPathComponent("models/\(model.item.filename)-v\(model.version).\(model.item.artifactExtension)")
        busy = true
        Task {
            defer {
                busy = false
                reload()
            }
            do {
                try model.adopt(from: source, to: destination)
                status = try await store.evaluateReelModel(model.item).summary
            } catch { status = error.localizedDescription }
        }
    }
}
