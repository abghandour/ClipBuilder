import Foundation

nonisolated enum MediaSuggestionService {
    static func suggestions(
        document: TimelineDocument, scenes: [SceneRecord],
        people: [PersonRecord], assets: [LibraryAssetMetadata]
    ) -> [MediaSuggestion] {
        let scenesByID = Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0) })
        let peopleByTag = Dictionary(uniqueKeysWithValues: people.map { ($0.tag, $0.displayName) })
        var output: [MediaSuggestion] = []
        for clip in document.videoTrack {
            guard let sceneID = clip.sceneID, let source = scenesByID[sceneID] else { continue }
            let names = Set(source.tags.compactMap { peopleByTag[$0] })
            let sourceTags = Set(source.tags)
            for asset in assets where asset.kind == AssetKind.images.rawValue && output.count < 30 {
                let subjectMatch = !names.isDisjoint(with: Set(asset.subjects))
                let tagMatch = !sourceTags.isDisjoint(with: Set(asset.tags))
                guard subjectMatch || tagMatch else { continue }
                output.append(
                    .init(
                        kind: .photo, path: asset.path, sceneID: nil,
                        atTime: clip.startTime,
                        reason: subjectMatch
                            ? "Owned photo matches \(names.sorted().joined(separator: ", "))"
                            : "Owned photo matches this clip's subject tags"))
            }
            for candidate in scenes where candidate.isBRoll && candidate.id != source.id && output.count < 30 {
                let overlap = Set(candidate.tags).intersection(sourceTags)
                guard !overlap.isEmpty else { continue }
                output.append(
                    .init(
                        kind: .bRoll, path: nil, sceneID: candidate.id,
                        atTime: clip.startTime,
                        reason: "B-roll matches \(overlap.prefix(3).joined(separator: ", "))"))
            }
        }
        var seen = Set<String>()
        return output.filter { seen.insert($0.id).inserted }
    }
}
