import SwiftUI

/// Requested, eligible and effective are three different things; the card
/// shows all three so a switch that does nothing is never a mystery.
nonisolated struct ReelModelState: Equatable, Sendable {
    var requested: Bool
    var eligibility: ReelModelStore.Eligibility
    var masterSwitch: Bool

    var eligible: Bool { eligibility == .eligible }
    var effective: Bool { requested && eligible && masterSwitch }
    var blockedByMasterSwitch: Bool { requested && eligible && !masterSwitch }

    static func make(_ item: ReelModelItem, store: ReelModelStore?, config: AIConfig) -> ReelModelState {
        .init(requested: config.onDeviceOverrides[item.rawValue] ?? false,
              eligibility: store?.eligibility(item) ?? .notEvaluated,
              masterSwitch: config.preferOnDevice)
    }

    var label: String {
        if effective { return "Active" }
        if blockedByMasterSwitch { return "Requested, inactive" }
        if requested { return "Requested, " + eligibility.label.lowercased() }
        return eligibility.label
    }
}

@MainActor
struct ReelModelsLearnedSection: View {
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settings.selectedTab") private var settingsTab = "profile"
    @Environment(AppStore.self) private var store
    /// Bumped by the owner after a publish or reload so adopted models show up.
    var reloadToken = UUID()
    @State private var reports: [ReelModelEvaluation] = []
    /// Eligibility hashes the model artifact, so it is computed once per reload, off the main thread.
    @State private var eligibility: [ReelModelItem: ReelModelStore.Eligibility] = [:]
    @State private var available: [LearnedModelArtifact] = []
    @State private var busy = false
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trained models").font(.headline)
            Text("Small models trained on this Mac from your own reels and reviews. Each one must pass a local evaluation before it can be enabled.")
                .font(.callout).foregroundStyle(.secondary)
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
            Text("Evaluate a model here, then switch it on. The switch is app-wide; the model and its evaluation belong to this profile. Models only run while Prefer on-device processing is on in Settings › AI.")
                .font(.caption).foregroundStyle(.secondary)
            if !status.isEmpty {
                Text(status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .task(id: "\(store.activeProfile.profileName)|\(reloadToken)") { await reload() }
    }

    private func displayName(_ item: ReelModelItem) -> String { ReelModelInfo.entry(item).title }

    private func modelCard(_ item: ReelModelItem) -> some View {
        let report = reports.first { $0.item == item }
        let state = ReelModelState(requested: store.settings.ai.onDeviceOverrides[item.rawValue] ?? false,
                                   eligibility: eligibility[item] ?? .notEvaluated,
                                   masterSwitch: store.settings.ai.preferOnDevice)
        let tint: Color = state.effective ? .green : state.blockedByMasterSwitch ? .orange
            : state.eligible ? .accentColor : report == nil ? .secondary : .orange
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
                        statusPill(state.label, tint: tint)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(displayName(item)).font(.headline)
                        statusPill(state.label, tint: tint)
                    }
                }
                let info = ReelModelInfo.entry(item)
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.predicts).font(.callout)
                    Text("Trained from: " + info.trainedFrom).font(.caption).foregroundStyle(.secondary)
                    Text("When on: " + info.whenEnabled).font(.caption).foregroundStyle(.secondary)
                }.fixedSize(horizontal: false, vertical: true)
                Text(face)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Evaluate") {
                        busy = true
                        Task {
                            defer { busy = false }
                            do {
                                status = try await store.evaluateReelModel(item).summary
                                await reload()
                            } catch { status = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small).disabled(busy)
                    .help("Evaluate \(displayName(item)) against this profile's examples. Required before it can be switched on.")
                    Toggle("Use", isOn: requestBinding(item, state: state))
                        .toggleStyle(.switch).controlSize(.small)
                        .disabled(!state.requested && !state.eligible)
                        .help(state.eligible || state.requested ? "Ask the app to use this model. It runs only while Prefer on-device processing is on."
                              : "Evaluate the model first; it must pass on this Mac.")
                }
                if state.blockedByMasterSwitch {
                    HStack(spacing: 8) {
                        Text("Requested, inactive while on-device processing is off.")
                            .font(.caption).foregroundStyle(.orange)
                        Button("Open Settings › AI") {
                            settingsTab = "ai"
                            openSettings()
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
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
                            if !state.eligible {
                                Text(state.eligibility.label)
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

    /// Off is always allowed; on only when the model is eligible.
    private func requestBinding(_ item: ReelModelItem, state: ReelModelState) -> Binding<Bool> {
        Binding(
            get: { state.requested },
            set: { value in
                guard !value || state.eligible else { return }
                store.settings.ai.onDeviceOverrides[item.rawValue] = value
                store.saveSettings()
            })
    }

    private func statusPill(_ title: String, tint: Color) -> some View {
        Text(title).font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .fixedSize()
    }

    private func reload() async {
        let modelStore = store.reelModelStore
        let snapshot: [ReelModelItem: ReelModelStore.Eligibility] = await Task.detached {
            guard let modelStore else { return [:] }
            return Dictionary(uniqueKeysWithValues: ReelModelItem.allCases.map { ($0, modelStore.eligibility($0)) })
        }.value
        eligibility = snapshot
        reports = ReelModelItem.allCases.compactMap { modelStore?.report($0) }
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
            defer { busy = false }
            do {
                try model.adopt(from: source, to: destination)
                status = try await store.evaluateReelModel(model.item).summary
            } catch { status = error.localizedDescription }
            await reload()
        }
    }
}
