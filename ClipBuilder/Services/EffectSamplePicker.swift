import Foundation

/// Shared, UI-independent rules for the Looks and Transitions browsers.
nonisolated enum EffectSamplePicker {
    static let lookGroups = ["looks", "film", "adjust", "detail", "stylize"]

    enum Page: String, CaseIterable, Sendable {
        case looks, transitions

        var defaultsKey: String { "\(rawValue).tab" }
        var itemDefaultsKey: String { "\(rawValue).item" }

        var itemLabel: String { self == .looks ? "effect" : "transition" }

        func items(for tab: String) -> [Tab] {
            switch self {
            case .looks:
                return EffectCatalog.presets.filter { $0.group == tab }
                    .map { Tab(id: $0.id, title: $0.name) }
            case .transitions:
                return TransitionCatalog.all.filter { $0.category.rawValue == tab }
                    .map { Tab(id: $0.name, title: $0.title) }
            }
        }

        /// A saved item only applies to its own group. Empty groups have no selection.
        func selectedItem(_ remembered: String, for tab: String) -> String? {
            let members = items(for: tab)
            return members.first { $0.id == remembered }?.id ?? members.first?.id
        }

        func previousItem(_ remembered: String, for tab: String) -> String? {
            adjacentItem(remembered, for: tab, offset: -1)
        }

        func nextItem(_ remembered: String, for tab: String) -> String? {
            adjacentItem(remembered, for: tab, offset: 1)
        }

        private func adjacentItem(_ remembered: String, for tab: String, offset: Int) -> String? {
            let members = items(for: tab)
            guard let selected = selectedItem(remembered, for: tab),
                  let index = members.firstIndex(where: { $0.id == selected }) else { return nil }
            return members[min(max(index + offset, 0), members.count - 1)].id
        }

        var tabs: [Tab] {
            switch self {
            case .looks:
                return EffectSamplePicker.lookGroups.map { Tab(id: $0, title: $0 == "looks" ? "Effects" : $0.capitalized) }
            case .transitions:
                return TransitionEffect.Category.allCases.map { Tab(id: $0.rawValue, title: $0.title) }
            }
        }

        /// Removed or unknown saved tabs fall back to the first section.
        func selectedTab(_ remembered: String) -> String {
            tabs.first { $0.id == remembered }?.id ?? tabs[0].id
        }
    }

    struct Tab: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
    }

    enum Slot: Sendable {
        case look, videoA, videoB
    }

    struct Source: Identifiable, Equatable, Sendable {
        let id: Int64
        let url: URL
        let filename: String
        let duration: Double
    }

    /// Check the actual local path, not synced availability or Drive metadata.
    /// Preserve project order and identity, including duplicate filenames.
    static func sources(from videos: [VideoRecord]) -> [Source] {
        videos.compactMap { video in
            guard let path = video.path, !path.isEmpty else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return nil }
            return Source(id: video.id, url: URL(fileURLWithPath: path),
                          filename: video.filename, duration: video.duration)
        }
    }

    /// Looks owns the same slot as Transitions Video A. Start with the latest
    /// saved set at call sites so changing one slot preserves the other window's pick.
    static func selecting(_ url: URL?, for slot: Slot, in samples: EffectSampleSet) -> EffectSampleSet {
        var updated = samples
        switch slot {
        case .look, .videoA: updated.videoA = url
        case .videoB: updated.videoB = url
        }
        return updated
    }
}
