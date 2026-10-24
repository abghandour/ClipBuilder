import SwiftUI

/// Profile-wide caption choices for the people in this run's footage.
struct CaptionSpeakerStylesEditor: View {
    @Environment(AppStore.self) private var store
    var people: [PersonRecord]?
    var videoIDs: [Int64]?
    let runStyleID: String?
    let profile: BrandProfile
    @Binding var positions: [String: String]?
    var ordinals: [String: Int] = [:]

    @State private var rosterKeys: Set<String>?
    @State private var loadedOrdinals: [String: Int] = [:]

    private var effectiveOrdinals: [String: Int] { ordinals.isEmpty ? loadedOrdinals : ordinals }

    private var listed: [PersonRecord] {
        let candidates = people ?? store.people.filter { rosterKeys?.contains($0.key) == true }
        return candidates.filter { !$0.hidden }.sorted {
            let lhs = effectiveOrdinals[$0.key] ?? Int.max, rhs = effectiveOrdinals[$1.key] ?? Int.max
            return lhs == rhs ? $0.key < $1.key : lhs < rhs
        }
    }

    private var runStyleName: String {
        profile.captionStyles?.first { $0.id.uuidString == runStyleID }?.name ?? "Profile default"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceS) {
            if rosterKeys == nil && people == nil {
                FormCaption("Looking up who appears in the footage…")
            }
            ForEach(listed) { person in
                HStack(spacing: Theme.spaceS) {
                    PersonFaceAvatar(person: person, size: 28)
                    Text(person.displayName)
                        .lineLimit(1).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Theme.spaceS)
                    CaptionPositionPicker(selection: positionSelection(for: person.key), runLabel: "Run position")
                        .pickerStyle(.menu).labelsHidden().lineLimit(1).fixedSize()
                        .disabled(effectiveOrdinals[person.key] == nil)
                        .accessibilityLabel("Caption position for \(person.displayName)")
                    Picker("Caption style", selection: selection(for: person.key)) {
                        Text("Run style").lineLimit(1).fixedSize().tag(nil as String?)
                        ForEach(profile.captionStyles ?? []) { named in
                            Text(named.name).lineLimit(1).fixedSize().tag(Optional(named.id.uuidString))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .lineLimit(1).fixedSize()
                    .accessibilityLabel("Caption style for \(person.displayName)")
                    .help("Run style follows \(runStyleName), selected above.")
                }
            }
            if !listed.isEmpty {
                FormCaption("People without a choice use the Caption position and style above. Positions are saved by speaking order (speaker 1, speaker 2, …) so presets apply to other footage; styles are saved with the profile.")
            }
        }
        .task(id: "\(store.profileGeneration)|\(store.transcriptCountsVersion)|\(videoIDs ?? [])") { await load() }
    }

    private func positionSelection(for key: String) -> Binding<String?> {
        Binding(get: {
            effectiveOrdinals[key].flatMap { positions?[CaptionSpeakerOrder.slot($0)] }
        }, set: { position in
            guard let ordinal = effectiveOrdinals[key] else { return }
            var choices = positions ?? [:]
            choices[CaptionSpeakerOrder.slot(ordinal)] = position
            positions = choices.isEmpty ? nil : choices
        })
    }

    private func selection(for key: String) -> Binding<String?> {
        Binding(get: {
            guard let id = store.activeProfile.personCaptionStyles?[key],
                  let uuid = UUID(uuidString: id),
                  profile.captionStyles?.contains(where: { $0.id == uuid }) == true else { return nil }
            return uuid.uuidString
        }, set: { id in
            var choices = store.activeProfile.personCaptionStyles ?? [:]
            choices[key] = id
            store.activeProfile.personCaptionStyles = choices.isEmpty ? nil : choices
            store.saveActiveProfile()
        })
    }

    private func load() async {
        guard people == nil else { return }
        rosterKeys = nil
        loadedOrdinals = [:]
        guard let database = store.database else { rosterKeys = []; return }
        let evidence = await CaptionSpeakerEvidence.load(database: database, videoIDs: videoIDs ?? [])
        let resolved = await Task.detached {
            CaptionSpeakerOrder.ordinals(turns: evidence.turns, rows: evidence.rows, roster: evidence.rosterKeys)
        }.value
        guard !Task.isCancelled, store.database === database else { return }
        loadedOrdinals = resolved
        rosterKeys = Set(evidence.rosterKeys)
    }
}
