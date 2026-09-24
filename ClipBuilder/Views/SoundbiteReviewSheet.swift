import SwiftUI

struct SoundbiteReviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let jobID: UUID
    let video: VideoRecord
    let soundbites: [SoundbiteFinder.Soundbite]
    let provenance: AIProvenance?
    @State private var included: [Double: Bool] = [:]
    @State private var isSaving = false

    var body: some View {
        results(soundbites)
            .frame(minWidth: 520, idealWidth: 580, minHeight: 300, idealHeight: 440)
            .modalCloseButton { dismiss() }
    }

    @ViewBuilder
    private func results(_ soundbites: [SoundbiteFinder.Soundbite]) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text("\(soundbites.count) soundbite\(soundbites.count == 1 ? "" : "s")")
                        .font(.headline)
                    if let provenance {
                        AIInfoButton(provenance: provenance, style: .full, role: "Found by")
                    }
                }
                Text("Checked soundbites save as timestamped video notes — they guide the next analysis and show in the plan sheet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(soundbites) { soundbite in
                        HStack(alignment: .top, spacing: 10) {
                            Toggle("", isOn: Binding(
                                get: { included[soundbite.id] ?? true },
                                set: { included[soundbite.id] = $0 }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text("\(soundbite.start.timecode)–\(soundbite.end.timecode)")
                                        .font(.caption.monospacedDigit().bold())
                                    if !soundbite.reason.isEmpty {
                                        Text(soundbite.reason)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Text("“\(soundbite.quote)”")
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !soundbite.overlayLine.isEmpty {
                                    Text("Overlay: \(soundbite.overlayLine)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.horizontal)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                let count = soundbites.count { included[$0.id] ?? true }
                Button(isSaving ? "Saving…" : "Save as Video Notes") {
                    save(soundbites.filter { included[$0.id] ?? true })
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(count == 0 || isSaving)
            }
            .padding()
        }
    }
    private func save(_ picked: [SoundbiteFinder.Soundbite]) {
        isSaving = true
        Task {
            for soundbite in picked {
                var note = "Soundbite: “\(soundbite.quote)”"
                if !soundbite.overlayLine.isEmpty {
                    note += " — overlay: “\(soundbite.overlayLine)”"
                }
                _ = await store.addVideoNote(videoID: video.id, at: soundbite.start, text: note,
                                             provenance: provenance)
            }
            isSaving = false
            store.jobs.markReviewed(jobID)
            dismiss()
        }
    }
}
