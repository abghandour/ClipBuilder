import SwiftUI

struct OnDeviceSettingsSection: View {
    @Environment(AppStore.self) private var store
    @State private var comparing = false
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
            ForEach(OnDeviceAgreement.items, id: \.self) { item in
                Toggle(isOn: overrideBinding(item)) {
                    VStack(alignment: .leading) {
                        Text(item.replacingOccurrences(of: "-", with: " ").capitalized)
                        Text(label(item)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
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
                if comparing { ProgressView("Comparing library samples…") }
                if !status.isEmpty { Text(status).font(.caption).textSelection(.enabled) }
            }
        }
    }
    private func overrideBinding(_ item: String) -> Binding<Bool> {
        Binding(get: { store.settings.ai.onDeviceOverrides[item] ?? false },
                set: { store.settings.ai.onDeviceOverrides[item] = $0 })
    }
    private func label(_ item: String) -> String {
        guard let percentage = store.settings.ai.onDeviceAgreement[item] else { return "Model only (not measured)" }
        return percentage >= 90 ? "On-device: passed \(Int(percentage))%" : "Model only (\(Int(percentage))%)"
    }
}
