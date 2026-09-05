import Foundation

nonisolated struct PublishedEditTraits: Codable, Sendable, Hashable {
    var outputWidth: Int
    var outputHeight: Int
    var cutCadence: Double
    var paceCurve: String
    var hookType: String
    var hookLength: Double
    var peopleKeys: [String]
    var screenSeconds: [String: Double]
    var cutTargets: [String: Int]

    static func derive(
        document: TimelineDocument, scenes: [SceneRecord],
        plan: WizardPlan? = nil
    ) -> PublishedEditTraits {
        let sceneMap = Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0) })
        let duration = max(0.1, document.contentEnd)
        let clips = document.videoTrack
        let people = Set(
            clips.compactMap(\.sceneID).flatMap { id in
                sceneMap[id]?.tags.compactMap { $0.hasPrefix("person:") ? String($0.dropFirst(7)) : nil } ?? []
            }
        ).sorted()
        var targets: [String: Int] = [:]
        targets["fighter"] = clips.count(where: { clip in
            clip.sceneID.flatMap { sceneMap[$0] }?.tags.contains(where: { $0.hasPrefix("person:") }) == true
        })
        targets["b-roll"] = clips.count(where: { clip in
            clip.sceneID.flatMap { sceneMap[$0] }?.isBRoll == true
        })
        targets["photo"] = document.imageOverlays.count
        targets["text"] = document.textOverlays.count
        targets["graphic"] = document.overlayBlocks.count
        var screens: [String: Double] = [:]
        if document.cropBlocks.isEmpty {
            screens["full"] = duration
        } else {
            for block in document.cropBlocks { screens[block.layout.name, default: 0] += block.duration }
        }
        let rationale = ((plan?.rationale ?? "") + " " + (plan?.clips.first?.reason ?? "")).lowercased()
        let hookType: String
        if rationale.contains("reaction") {
            hookType = "reaction-first"
        } else if rationale.contains("finish") || rationale.contains("payoff") {
            hookType = "finish-first"
        } else if rationale.contains("freeze") {
            hookType = "freeze-and-promise"
        } else {
            hookType = "mid-action"
        }
        return PublishedEditTraits(
            outputWidth: document.renderSettings.width,
            outputHeight: document.renderSettings.height,
            cutCadence: Double(clips.count) / duration * 60,
            paceCurve: document.pacing.curve.rawValue,
            hookType: hookType, hookLength: clips.first?.duration ?? 0,
            peopleKeys: people, screenSeconds: screens, cutTargets: targets)
    }
}
