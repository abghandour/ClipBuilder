import SwiftUI

struct VoiceCloneConsentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let name: String
    let clone: () -> Void
    @State private var permission = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceM) {
            Text("Clone \(name)'s voice").font(.headline)
            Text("Up to two minutes of clean speech from analyzed footage will be sent to ElevenLabs. You can follow progress or stop from the job status row.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("I have permission from \(name) to clone their voice", isOn: $permission)
                .toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .lineLimit(1).fixedSize()
                Button("Clone") {
                    guard permission else { return }
                    clone()
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(!permission).lineLimit(1).fixedSize()
            }
        }
        .padding(Theme.spaceL).frame(width: 440)
    }
}
