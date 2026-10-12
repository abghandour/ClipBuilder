import SwiftUI

struct StrikeStatsLookControls: View {
    @Binding var enabled: Bool
    @Binding var units: String
    @Binding var speedCallouts: Bool
    @Binding var grapplingCard: Bool
    @Binding var roundCard: Bool

    var body: some View {
        WizardControlRow("Strike stats") { Toggle("Strike stats", isOn: $enabled) }
            .help("Save strike-stat preferences for this run; add count cards from Builder > Add")
        if enabled {
            VStack(alignment: .leading, spacing: 8) {
                WizardControlRow("Units") {
                    Picker("Units", selection: $units) {
                        ForEach(StrikeStatPayload.Unit.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                    }
                }
                .help("Unit preference for future strike estimates")
                WizardControlRow("Speed callouts") { Toggle("Speed callouts", isOn: $speedCallouts).disabled(true) }
                    .help("Needs strike estimates")
                Text("Needs strike estimates").font(.caption).foregroundStyle(.secondary)
                WizardControlRow("Grappling card") { Toggle("Grappling card", isOn: $grapplingCard) }
                    .help("Keep the grappling-card preference with copied runs")
                WizardControlRow("Round card") { Toggle("Round card", isOn: $roundCard) }
                    .help("Keep the round-card preference with copied runs")
                Text("Add count cards in Builder. Automatic placement is not available yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formDependent()
        }
    }
}
