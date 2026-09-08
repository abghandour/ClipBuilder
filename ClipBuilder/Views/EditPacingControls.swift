import SwiftUI

struct EditPacingControls: View {
    @Binding var pacing: EditPacing

    var body: some View {
        Picker("Cut cadence", selection: $pacing.cadence) {
            ForEach(CutCadence.allCases) { cadence in
                Text(cadence.label).tag(cadence)
            }
        }
        .fieldHelp(WizardFieldHelp.cutCadence)
        FieldCaption(WizardFieldHelp.cutCadence)
        Picker("Pace curve", selection: $pacing.curve) {
            ForEach(PaceCurve.allCases) { curve in
                Text(curve.label).tag(curve)
            }
        }
        .disabled(pacing.cadence == .automatic)
        .fieldHelp(WizardFieldHelp.paceCurve)
        FieldCaption(WizardFieldHelp.paceCurve)
    }
}
