import SwiftUI

struct OnDeviceSettingsSection: View {
    @Environment(AppStore.self) private var store
    @State private var comparing = false
    @State private var confirmingCriticEvaluation = false
    @State private var criticDefault = "Default: without brief until agreement improves"
    @State private var status = ""

    private var comparisonVisible: Bool {
        #if DEBUG
        true
        #else
        UserDefaults.standard.bool(forKey: "showOnDeviceComparison")
        #endif
    }
    var body: some View {
        @Bindable var store = store
        Section("On-device processing") {
            Toggle("Prefer on-device processing", isOn: $store.settings.ai.preferOnDevice)
            Text("Use on-device matching and detection before asking a model.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(OnDeviceAgreement.items + ReelModelItem.allCases.map(\.rawValue), id: \.self) { item in
                Toggle(isOn: overrideBinding(item)) {
                    VStack(alignment: .leading) {
                        Text(item.replacingOccurrences(of: "-", with: " ").capitalized)
                        Text(label(item)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(ReelModelItem.allCases, id: \.rawValue) { item in
                Button("Evaluate " + item.rawValue.replacingOccurrences(of: "-", with: " ")) {
                    store.startModelEvaluation(item)
                }.disabled(comparing || store.jobs.running.contains { $0.kind == .evaluateReelModel })
            }
            Button("Evaluate Critic…") { confirmingCriticEvaluation = true }
                .lineLimit(1).fixedSize()
                .disabled(store.database == nil || store.jobs.running.contains { $0.kind == .evaluateCritic })
                .confirmationDialog("Evaluate Critic?", isPresented: $confirmingCriticEvaluation) {
                    Button("Evaluate Critic") { store.startCriticEvaluation() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Up to 48 critique calls, about 12 frames each, plus reference contact sheets. Compares the same held-out reels without and with the brief.")
                }
            Text(criticDefault).font(.caption).foregroundStyle(.secondary)
                .task(id: "\(store.profileGeneration):\(store.jobs.completionRevision(.evaluateCritic)):\(store.jobs.completionRevision(.criticBrief))") {
                    let generation = store.profileGeneration
                    let profile = store.activeProfile
                    let enabled = (try? await AppJobWork.run {
                        let cache = CriticBriefStore(profile: profile)
                        return cache.load().map { cache.enabledByDefault($0) } ?? false
                    }) ?? false
                    guard !Task.isCancelled, generation == store.profileGeneration else { return }
                    criticDefault = enabled ? "Default: with critic brief (agreement improved)"
                        : "Default: without brief until agreement improves"
                }
            if let job = store.jobs.latest(.evaluateCritic), job.status == .done {
                Text(job.statusLine).font(.caption).textSelection(.enabled)
            }
            if comparing { ProgressView("Evaluating…") }
            if let job = store.jobs.latest(.evaluateReelModel), job.status == .done {
                Text(job.statusLine).font(.caption).textSelection(.enabled)
            }
            if !status.isEmpty { Text(status).font(.caption).textSelection(.enabled) }
            if comparisonVisible {
                Button("Compare on-device with model") {
                    comparing = true
                    Task {
                        let reports = await store.compareOnDeviceWithModel()
                        status = reports.map { report in
                            "\(report.item): \(report.percentage.map { String(format: "%.0f%%", $0) } ?? "no comparable cases")\(report.errors.isEmpty ? "" : " — \(report.errors.count) unavailable cases")"
                        }.joined(separator: "\n")
                        comparing = false
                    }
                }.disabled(comparing)
            }
        }
    }
    private func overrideBinding(_ item: String) -> Binding<Bool> {
        Binding(get: { store.settings.ai.onDeviceOverrides[item] ?? false },
                set: { store.settings.ai.onDeviceOverrides[item] = $0 })
    }
    private func label(_ item: String) -> String {
        if let model = ReelModelItem(rawValue: item) {
            guard let report = store.reelModelStore?.report(model) else { return "Not evaluated for this profile" }
            guard report.localEvaluation else { return "Adopted — local evaluation required" }
            return report.passed ? "Local holdout passed" : "Local holdout did not pass"
        }
        guard let percentage = store.settings.ai.onDeviceAgreement[item] else { return "Model only (not measured)" }
        return percentage >= 90 ? "On-device: passed \(Int(percentage))%" : "Model only (\(Int(percentage))%)"
    }
}
